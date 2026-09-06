module Gateway
  # The thin wrapper over ruby_llm (A2): builds a per-provider context, turns
  # chain-link params into `with_params`, always streams (A3), reads the stop
  # reason off the raw chunks (ruby_llm never does), and maps ruby_llm's
  # errors onto Gateway's.
  #
  # Tools go to the provider directly rather than through Chat#complete,
  # because Chat's loop executes tools in-process; hob's venue is the
  # client session (C), so a tool call ends the request instead.
  class Transport
    Result = Struct.new(:content, :stop_reason, :input_tokens, :output_tokens, :cache_read_tokens,
                        :cache_creation_tokens, :model, :tool_calls, keyword_init: true)

    def call(resolution:, system:, messages:, schema:, params:, tools: [], tool_choice: nil, &on_delta)
      chat = build_chat(resolution, params)
      chat = chat.with_instructions(system) if system.present?
      chat = chat.with_schema(schema) if schema
      messages.each { |m| chat.add_message(**message_attributes(m)) }

      text = +""
      stop_reason = nil
      message = provider_complete(chat, tools, tool_choice) do |chunk|
        stop_reason ||= stop_reason_from(chunk.raw) if chunk.raw.is_a?(Hash)
        next if chunk.content.blank?

        text << chunk.content.to_s
        on_delta&.call(chunk.content.to_s)
      end

      Result.new(
        content: text.presence || (message.content.is_a?(String) ? message.content : nil),
        stop_reason: stop_reason || stop_reason_from(message.raw.respond_to?(:body) ? message.raw.body : nil),
        input_tokens: message.input_tokens, output_tokens: message.output_tokens,
        cache_read_tokens: message.cached_tokens, cache_creation_tokens: message.cache_creation_tokens,
        model: message.model_id,
        tool_calls: (message.tool_calls || {}).values.map { |tc| { "id" => tc.id, "name" => tc.name, "arguments" => tc.arguments } }
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

    private

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
      chat = context.chat(
        model: resolution.model,
        provider: provider.kind == "anthropic" ? :anthropic : :openai,
        assume_model_exists: true
      )
      params.present? ? chat.with_params(**params.deep_symbolize_keys) : chat
    end

    # Chat#complete would run the tool loop itself; the provider call alone
    # returns the message with its tool calls unexecuted.
    def provider_complete(chat, tools, tool_choice, &block)
      provider = chat.instance_variable_get(:@provider)
      tool_map = tools.to_h { |t| [ t.name.to_sym, t ] }
      choice = tool_choice && (ToolDef::CHOICES.include?(tool_choice) ? tool_choice.to_sym : tool_choice.to_s.to_sym)
      provider.complete(
        chat.messages, tools: tool_map, tool_prefs: { choice: choice, calls: nil }, temperature: nil,
        model: chat.model, params: chat.params, headers: chat.headers, schema: chat.schema, thinking: nil, &block
      )
    end

    # user / assistant text, an assistant message carrying tool calls, or a
    # tool result (role "tool", which each provider renders its own way).
    def message_attributes(m)
      case m["role"]
      when "tool"
        { role: :tool, content: m["content"].to_s, tool_call_id: m["tool_call_id"] }
      when "assistant"
        calls = Array(m["tool_calls"]).to_h do |tc|
          [ tc["id"], RubyLLM::ToolCall.new(id: tc["id"], name: tc["name"], arguments: tc["arguments"] || {}) ]
        end
        calls.empty? ? { role: :assistant, content: m["content"] } : { role: :assistant, content: m["content"].presence, tool_calls: calls }
      else
        { role: :user, content: m["content"] }
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
