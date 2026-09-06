module Hob
  # One of the model's requests to run a tool (C). `result(content)` builds
  # the entry the caller sends back in `tool_results`.
  class ToolCall < Record
    attribute :id, :name, :arguments, :node

    def result(content, error: nil)
      content = JSON.generate(content) unless content.is_a?(String)
      { id: id, content: content, error: error }.compact
    end
  end

  # Token counts and cost for one call (cost is nil when the model is unpriced).
  class Usage < Record
    attribute :input_tokens, :output_tokens, :cache_read_tokens, :cache_creation_tokens, :cost
  end

  # The outcome of POST /v1/completions or GET /v1/completions/:id.
  class Completion < Record
    attribute :id, :status, :content, :parsed, :model, :provider, :stop_reason, :snapshot, :node, :operation

    def usage
      @usage ||= Usage.new(@data["usage"])
    end

    def tool_calls
      @tool_calls ||= Array(@data["tool_calls"]).map { |tc| ToolCall.new(tc) }
    end

    def tool_calls?
      status == "tool_calls" || tool_calls.any?
    end

    def refused?
      status == "refused"
    end

    def success?
      status == "success"
    end
  end
end
