module Hob
  # The outcome of POST /v1/conversations/:id/chat: the nodes the turn
  # appended and, when the model stopped to ask for a tool, the calls.
  class Turn < Record
    attribute :status, :user, :assistant, :assistants, :snapshot

    # The assistant's text (the last speaker's, in an ensemble).
    def content
      assistant && assistant["content"]
    end

    def tool_calls
      @tool_calls ||= Array(@data["tool_calls"]).map { |tc| ToolCall.new(tc) }
    end

    def tool_calls?
      status == "tool_calls" || tool_calls.any?
    end
  end
end
