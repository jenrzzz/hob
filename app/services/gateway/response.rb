module Gateway
  # The normalized outcome of one provider call (A1).
  class Response
    REFUSAL_STOP_REASONS = %w[refusal content_filter].freeze

    attr_accessor :content, :parsed, :stop_reason, :input_tokens, :output_tokens, :cache_read_tokens,
                  :cache_creation_tokens, :model, :provider, :duration_ms, :tool_calls

    def self.from_transport(result, resolution:, started:)
      new.tap do |r|
        r.content = result.content.to_s
        r.stop_reason = result.stop_reason
        r.tool_calls = Array(result.tool_calls).map { |tc| tc.to_h.stringify_keys.slice("id", "name", "arguments") }
        r.input_tokens = result.input_tokens.to_i
        r.output_tokens = result.output_tokens.to_i
        r.cache_read_tokens = result.cache_read_tokens.to_i
        r.cache_creation_tokens = result.cache_creation_tokens.to_i
        r.model = result.model.presence || resolution.model
        r.provider = resolution.provider.slug
        r.duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      end
    end

    # The model stopped to ask the caller to run a tool (C): a distinct,
    # successful outcome. Text before the call, if any, is in `content`.
    def tool_calls?
      tool_calls.present?
    end

    # A refusal is a distinct outcome: an explicit stop reason, or nothing at
    # all came back (ruby_llm surfaces refusals as empty content).
    def refused?
      return false if tool_calls?

      REFUSAL_STOP_REASONS.include?(stop_reason.to_s) || content.blank?
    end

    def status
      if refused? then "refused"
      elsif tool_calls? then "tool_calls"
      else "success"
      end
    end

    def units
      { "input_tokens" => input_tokens, "output_tokens" => output_tokens,
        "cache_read_tokens" => cache_read_tokens, "cache_creation_tokens" => cache_creation_tokens }
    end

    def cost
      ModelPrice.cost_for(model: model, units: units)
    end

    # What lands in an assistant node's meta.
    def meta
      units.merge("model" => model, "provider" => provider, "stop_reason" => stop_reason,
                  "duration_ms" => duration_ms).compact
    end
  end
end
