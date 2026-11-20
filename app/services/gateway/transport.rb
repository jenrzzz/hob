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

    def call(resolution:, system:, messages:, schema:, params:, tools: [], tool_choice: nil, &on_delta)
      anthropic = resolution.provider.kind == "anthropic"
      chat = build_chat(resolution, params)
      chat = chat.with_instructions(system) if system.present?
      chat = chat.with_schema(schema) if schema
      messages.each { |m| chat.add_message(message_for(m, anthropic: anthropic)) }
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
        reasoning: reasoning_from(message)
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
      raise Invalid, "#{provider.slug} (#{provider.kind}) has no embeddings" if provider.kind == "anthropic"

      context = RubyLLM.context do |config|
        config.openai_api_key = provider.api_key
        config.openai_api_base = provider.config["base_url"]
      end
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

    # Anthropic's thinking blocks, verbatim with their signatures, as the
    # provider returned them. A tool-use turn produced with thinking must be
    # replayed with these blocks first in the assistant turn, so hob keeps
    # them on the node (MEMORY.md, "Thinking and tools").
    def reasoning_from(message)
      raw = message.raw_reasoning
      raw.is_a?(Hash) && raw["anthropic"].present? ? { "anthropic" => raw["anthropic"] } : nil
    end

    def mark_cache_boundary(chat, messages)
      index = messages.rindex { |m| m["cache"] } || (messages.size - 1)
      chat.messages.reject { |m| m.role == :system }[index]&.cache_until_here
    end

    def build_chat(resolution, params)
      provider = resolution.provider
      context = RubyLLM.context do |config|
        case provider.kind
        when "anthropic"
          config.anthropic_api_key = provider.api_key
        when "openai_compat"
          config.openai_api_key = provider.api_key
          config.openai_api_base = provider.config["base_url"]
        end
      end

      # assume_model_exists: a new model release is a config row, never a code
      # change. The cost is that ruby_llm's registry can't gate features, so
      # thinking and max_tokens ride in as raw params (see EXTRACTION.md A2).
      # An openai_compat server speaks chat completions; left to itself
      # ruby_llm would send OpenAI's Responses API at it.
      chat = context.chat(
        model: resolution.model,
        provider: provider.kind == "anthropic" ? :anthropic : :openai,
        protocol: provider.kind == "anthropic" ? nil : :chat_completions,
        assume_model_exists: true
      )
      params.present? ? chat.with_provider_options(params.deep_symbolize_keys) : chat
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
    def message_for(m, anthropic:)
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
        calls = Array(m["tool_calls"]).to_h do |tc|
          [ tc["id"], RubyLLM::ToolCall.new(id: tc["id"], name: tc["name"], arguments: tc["arguments"] || {}) ]
        end
        reasoning = anthropic ? m["reasoning"] : nil
        content = calls.empty? ? m["content"] : m["content"].presence
        RubyLLM::Message.new(role: :assistant, content: content, tool_calls: calls.presence, raw_reasoning: reasoning)
      else
        RubyLLM::Message.new(role: :user, content: m["content"], attachments: attachments)
      end
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
    def stop_reason_from(data)
      return nil unless data.is_a?(Hash)

      data.dig("delta", "stop_reason") || data["stop_reason"] || data.dig("choices", 0, "finish_reason")
    end

    def retry_after_from(error)
      value = error.response&.headers&.[]("retry-after") if error.respond_to?(:response)
      value&.to_i
    end
  end
end
