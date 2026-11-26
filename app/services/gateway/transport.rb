module Gateway
  # The thin wrapper over ruby_llm (A2): builds a per-provider context, turns
  # chain-link params into provider options, always streams (A3), reads the
  # provider's own stop reason off the raw chunks (ruby_llm normalizes it, and
  # hob's callers are promised the provider's word), and maps ruby_llm's
  # errors onto Gateway's.
  #
  # One completion is Chat#generate, not Chat#complete: that loop executes
  # tools in-process; hob's venue is the client session (C), so a tool call
  # ends the request instead.
  class Transport
    Result = Struct.new(:content, :stop_reason, :input_tokens, :output_tokens, :cache_read_tokens,
                        :cache_creation_tokens, :model, :tool_calls, :reasoning, keyword_init: true)

    # A tool result that failed. ruby_llm renders tool results without
    # Anthropic's `is_error`, so this message carries the flag and
    # ErrorFlag (below) adds it to the block.
    class ToolResultMessage < RubyLLM::Message
      attr_reader :hob_error

      def initialize(options = {})
        @hob_error = options.delete(:hob_error)
        super
      end
    end

    # Prepended onto ruby_llm's Anthropic tool renderer: `is_error: true` on
    # a failed result's block, so the model reads it as a failure, not output.
    module ErrorFlag
      def format_tool_result_block(msg)
        block = super
        msg.respond_to?(:hob_error) && msg.hob_error ? block.merge(is_error: true) : block
      end
    end
    RubyLLM::Protocols::Anthropic::Tools.singleton_class.prepend(ErrorFlag)

    # Gemini 3 refuses a replayed function call without the thought signature
    # it came with. A call that never had one (a turn another provider made,
    # before a fallback reached Gemini) carries the value Google documents
    # for histories it did not produce.
    FOREIGN_THOUGHT_SIGNATURE = "skip_thought_signature_validator".freeze

    def call(resolution:, system:, messages:, schema:, params:, tools: [], tool_choice: nil, &on_delta)
      kind = resolution.provider.kind
      anthropic = kind == "anthropic"
      chat = build_chat(resolution, params)
      chat = chat.with_instructions(system) if system.present?
      chat = chat.with_schema(schema) if schema
      messages.each { |m| chat.add_message(message_for(m, kind: kind)) }
      # One explicit breakpoint where the caller marked the stable prefix
      # ends (the last history message), else at the last message, so each
      # round of a tool loop reads the previous round's prefix from cache.
      mark_cache_boundary(chat, messages) if anthropic

      text = +""
      stop_reason = nil
      message = generate(chat, tools, tool_choice) do |chunk|
        stop_reason ||= stop_reason_from(chunk.raw) if chunk.raw.is_a?(Hash)
        next if chunk.content.blank?

        text << chunk.content.to_s
        on_delta&.call(chunk.content.to_s)
      end

      Result.new(
        content: text.presence || (message.content.is_a?(String) ? message.content : nil),
        stop_reason: stop_reason || stop_reason_from(message.raw.respond_to?(:body) ? message.raw.body : nil),
        input_tokens: message.tokens&.input, output_tokens: message.tokens&.output,
        cache_read_tokens: message.tokens&.cache_read, cache_creation_tokens: message.tokens&.cache_write,
        model: message.model,
        tool_calls: (message.tool_calls || {}).values.map { |tc| { "id" => tc.id, "name" => tc.name, "arguments" => tc.arguments } },
        reasoning: reasoning_from(message, kind)
      )
    rescue RubyLLM::RateLimitError => e
      raise RateLimited.new(e.message, retry_after: retry_after_from(e))
    rescue RubyLLM::OverloadedError, RubyLLM::ServiceUnavailableError, RubyLLM::ServerError,
           Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise Unavailable, e.message
    rescue RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError, RubyLLM::PaymentRequiredError => e
      raise Unauthorized, e.message
    rescue RubyLLM::BadRequestError, RubyLLM::ContextLengthExceededError, RubyLLM::Error => e
      raise Invalid, e.message
    end

    # -> { vectors:, model:, input_tokens: }
    def embed(resolution:, texts:)
      provider = resolution.provider
      # Gemini through Vertex embeds by :predict, which ruby_llm's Gemini
      # protocol does not speak; only openai_compat embeds here.
      raise Invalid, "#{provider.slug} (#{provider.kind}) has no embeddings" unless provider.kind == "openai_compat"

      context = RubyLLM.context { |config| configure(config, provider) }
      result = context.embed(texts, model: resolution.model, provider: :openai, assume_model_exists: true)
      vectors = result.vectors
      vectors = [ vectors ] unless vectors.first.is_a?(Array)
      { vectors: vectors, model: result.model, input_tokens: result.tokens&.input }
    rescue RubyLLM::RateLimitError => e
      raise RateLimited.new(e.message, retry_after: retry_after_from(e))
    rescue RubyLLM::OverloadedError, RubyLLM::ServiceUnavailableError, RubyLLM::ServerError,
           Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise Unavailable, e.message
    rescue RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError, RubyLLM::PaymentRequiredError => e
      raise Unauthorized, e.message
    rescue RubyLLM::Error => e
      raise Invalid, e.message
    end

    private

    # What a provider needs back to resume a tool-use turn, keyed by kind so
    # a fallback to another provider ignores it. Anthropic: its thinking
    # blocks, verbatim with their signatures, replayed first in the assistant
    # turn (MEMORY.md, "Thinking and tools"). Gemini: each function call's
    # thought signature, by call id, replayed on the call.
    def reasoning_from(message, kind)
      case kind
      when "anthropic"
        raw = message.raw_reasoning
        raw.is_a?(Hash) && raw["anthropic"].present? ? { "anthropic" => raw["anthropic"] } : nil
      when "gemini"
        signatures = (message.tool_calls || {}).values.select(&:thought_signature).to_h { |tc| [ tc.id, tc.thought_signature ] }
        signatures.present? ? { "gemini" => signatures } : nil
      end
    end

    def configure(config, provider)
      case provider.kind
      when "anthropic"
        config.anthropic_api_key = provider.api_key
      when "openai_compat"
        config.openai_api_key = provider.api_key
        config.openai_api_base = provider.config["base_url"]
      when "gemini"
        config.gemini_api_key = provider.api_key
        config.gemini_api_base = provider.config["base_url"] if provider.config["base_url"].present?
      end
    end

    def mark_cache_boundary(chat, messages)
      index = messages.rindex { |m| m["cache"] } || (messages.size - 1)
      chat.messages.reject { |m| m.role == :system }[index]&.cache_until_here
    end

    def build_chat(resolution, params)
      provider = resolution.provider
      context = RubyLLM.context { |config| configure(config, provider) }

      # assume_model_exists: a new model release is a config row, never a code
      # change. The cost is that ruby_llm's registry can't gate features, so
      # thinking and max_tokens ride in as raw params (see EXTRACTION.md A2).
      # An openai_compat server speaks chat completions; left to itself
      # ruby_llm would send OpenAI's Responses API at it. Gemini is spoken to
      # natively (generateContent), for its thought signatures and finish
      # reasons.
      chat = case provider.kind
      when "anthropic" then context.chat(model: resolution.model, provider: :anthropic, assume_model_exists: true)
      when "gemini" then context.chat(model: resolution.model, provider: :gemini, assume_model_exists: true)
      else context.chat(model: resolution.model, provider: :openai, protocol: :chat_completions, assume_model_exists: true)
      end
      params = gemini_params(params) if provider.kind == "gemini"
      params.present? ? chat.with_provider_options(params.deep_symbolize_keys) : chat
    end

    # Raw params are the provider's own vocabulary, so a Gemini link says
    # generationConfig.thinkingConfig itself. The one exception is
    # max_tokens, which nearly every chain link and preset carries: it is
    # Gemini's maxOutputTokens.
    def gemini_params(params)
      return params unless params.key?("max_tokens")

      params.except("max_tokens").deep_merge("generationConfig" => { "maxOutputTokens" => params["max_tokens"] })
    end

    # Chat#generate asks once and returns the message with its tool calls
    # unexecuted; the tools only need the shape ToolDef gives them.
    def generate(chat, tools, tool_choice, &block)
      chat.with_tools(*tools) if tools.any?
      chat.with_tool_options(choice: tool_choice.to_sym) if tool_choice
      chat.generate(&block)
    end

    # user / assistant text, an assistant message carrying tool calls (and
    # the thinking that preceded them), or a tool result (role "tool", which
    # each provider renders its own way). Images ride as attachments, their
    # bytes read from Blob by digest at the last moment.
    def message_for(m, kind:)
      anthropic = kind == "anthropic"
      attachments = attachments_for(m)
      case m["role"]
      when "tool"
        content = m["content"].to_s
        # Only Anthropic has an error flag on the block; elsewhere the model
        # is told in words.
        content = "[tool error] #{content}" if m["error"] && !anthropic
        ToolResultMessage.new(role: :tool, content: content, tool_call_id: m["tool_call_id"],
                              attachments: attachments, hob_error: m["error"] && anthropic)
      when "assistant"
        signatures = kind == "gemini" ? gemini_signatures(m) : {}
        calls = Array(m["tool_calls"]).to_h do |tc|
          [ tc["id"], RubyLLM::ToolCall.new(id: tc["id"], name: tc["name"], arguments: tc["arguments"] || {},
                                            thought_signature: signatures[tc["id"]]) ]
        end
        reasoning = anthropic ? m["reasoning"] : nil
        content = calls.empty? ? m["content"] : m["content"].presence
        RubyLLM::Message.new(role: :assistant, content: content, tool_calls: calls.presence, raw_reasoning: reasoning)
      else
        RubyLLM::Message.new(role: :user, content: m["content"], attachments: attachments)
      end
    end

    # The signatures Gemini gave this turn's calls; for a turn it did not
    # make, the documented stand-in on the first call (only the first of a
    # parallel set carries one).
    def gemini_signatures(m)
      stored = m.dig("reasoning", "gemini")
      return stored if stored.is_a?(Hash) && stored.present?

      first = Array(m["tool_calls"]).first
      first ? { first["id"] => FOREIGN_THOUGHT_SIGNATURE } : {}
    end

    EXTENSIONS = { "image/png" => "png", "image/jpeg" => "jpg", "image/gif" => "gif", "image/webp" => "webp" }.freeze

    def attachments_for(m)
      Array(m["attachments"]).map do |a|
        blob = Blob.fetch!(a["digest"])
        RubyLLM::Attachment.new(StringIO.new(blob.bytes),
                                filename: "#{blob.digest.delete_prefix('sha256:')[0, 16]}.#{EXTENSIONS.fetch(blob.media_type)}")
      end
    end

    # Anthropic: message_delta.delta.stop_reason (stream) / stop_reason (sync).
    # OpenAI-compatible: choices[0].finish_reason on both paths.
    # Gemini: candidates[0].finishReason, or promptFeedback.blockReason when
    # the prompt itself was blocked and no candidate came back.
    def stop_reason_from(data)
      return nil unless data.is_a?(Hash)

      data.dig("delta", "stop_reason") || data["stop_reason"] || data.dig("choices", 0, "finish_reason") ||
        data.dig("candidates", 0, "finishReason") || data.dig("promptFeedback", "blockReason")
    end

    def retry_after_from(error)
      value = error.response&.headers&.[]("retry-after") if error.respond_to?(:response)
      value&.to_i
    end
  end
end
