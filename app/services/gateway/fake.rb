module Gateway
  # Scripted transport for tests and offline development. Queue replies with
  # #reply / #refuse / #call_tool / #fail; each call consumes one and is
  # recorded in #calls.
  class Fake
    Call = Struct.new(:resolution, :system, :messages, :schema, :params, :tools, :tool_choice, keyword_init: true)

    attr_reader :calls

    def initialize
      @queue = []
      @calls = []
    end

    def reply(content, stop_reason: "end_turn", input_tokens: 10, output_tokens: 5, cache_read_tokens: 0, model: nil,
              tool_calls: [])
      @queue << Transport::Result.new(content: content, stop_reason: stop_reason, input_tokens: input_tokens,
                                      output_tokens: output_tokens, cache_read_tokens: cache_read_tokens,
                                      cache_creation_tokens: 0, model: model, tool_calls: tool_calls)
      self
    end

    def refuse
      reply("", stop_reason: "refusal", output_tokens: 0)
    end

    # The model asks the caller to run a tool; `content` is any text it said first.
    def call_tool(name, arguments = {}, id: nil, content: "", **more)
      id ||= "toolu_#{SecureRandom.hex(4)}"
      calls = [ { "id" => id, "name" => name, "arguments" => arguments.deep_stringify_keys } ]
      more.each { |extra_name, extra_args| calls << { "id" => "toolu_#{SecureRandom.hex(4)}", "name" => extra_name.to_s, "arguments" => extra_args.deep_stringify_keys } }
      reply(content, stop_reason: "tool_use", tool_calls: calls)
    end

    def fail(error)
      @queue << error
      self
    end

    def call(resolution:, system:, messages:, schema:, params:, tools: [], tool_choice: nil, &on_delta)
      @calls << Call.new(resolution: resolution, system: system, messages: messages, schema: schema, params: params,
                         tools: tools.map(&:to_h), tool_choice: tool_choice)
      raise Gateway::Error, "Gateway::Fake: no scripted reply left" if @queue.empty?

      next_item = @queue.shift
      raise next_item if next_item.is_a?(Exception)

      # Stream in small pieces so the delta path is exercised.
      next_item.content.to_s.scan(/.{1,7}/m).each { |piece| on_delta&.call(piece) } if on_delta
      next_item.dup.tap { |r| r.model ||= resolution.model }
    end
  end
end
