require "test_helper"

# Drives Gateway::Transport through real ruby_llm with the HTTP layer
# replaced: the stub captures the rendered payload and replays Anthropic
# SSE bytes into ruby_llm's own stream handler, so the raw-chunk hook, stop
# reason, token counting, and param translation are all exercised offline.
class TransportTest < ActiveSupport::TestCase
  module StubbedPost
    class << self
      attr_accessor :sse, :payloads, :error
    end

    def post(_url, payload)
      StubbedPost.payloads << payload
      raise StubbedPost.error if StubbedPost.error

      req = Struct.new(:headers, :options).new({}, Faraday::RequestOptions.new)
      yield req
      env = Faraday::Env.new
      env.status = 200
      env.body = ""
      req.options.on_data.call(StubbedPost.sse, StubbedPost.sse.bytesize, env)
      Faraday::Response.new(env)
    end
  end

  setup do
    RubyLLM::Connection.prepend(StubbedPost) unless RubyLLM::Connection.ancestors.include?(StubbedPost)
    StubbedPost.payloads = []
    StubbedPost.error = nil
    StubbedPost.sse = sse(
      { type: "message_start", message: { model: "claude-sonnet-5", usage: { input_tokens: 25, cache_read_input_tokens: 5 } } },
      { type: "content_block_delta", delta: { type: "text_delta", text: "Hello, " } },
      { type: "content_block_delta", delta: { type: "text_delta", text: "world." } },
      { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 7 } },
      { type: "message_stop" }
    )
    @resolution = ModelRole.find_role!("interviewer").resolve
  end

  def sse(*events)
    events.map { |e| "event: #{e[:type]}\ndata: #{JSON.generate(e)}\n\n" }.join
  end

  def call(**opts, &on_delta)
    Gateway::Transport.new.call(**{ resolution: @resolution, system: "Be kind.", schema: nil,
                                    messages: [ user_message("hi") ], params: @resolution.params }.merge(opts), &on_delta)
  end

  test "streams text, reads the stop reason off message_delta, counts tokens, translates params" do
    deltas = []
    result = call(params: { "max_tokens" => 8192, "thinking" => { "type" => "adaptive" }, "output_config" => { "effort" => "high" } }) { |d| deltas << d }

    assert_equal "Hello, world.", result.content
    assert_equal [ "Hello, ", "world." ], deltas
    assert_equal "end_turn", result.stop_reason
    assert_equal [ 25, 7, 5 ], [ result.input_tokens, result.output_tokens, result.cache_read_tokens ]
    assert_equal "claude-sonnet-5", result.model

    payload = StubbedPost.payloads.last
    assert_equal "claude-opus-4-7", payload[:model]
    assert_equal true, payload[:stream]
    assert_equal 8192, payload[:max_tokens]
    assert_equal({ type: "adaptive" }, payload[:thinking])
    assert_equal({ effort: "high" }, payload[:output_config])
    assert_equal [ { type: "text", text: "Be kind." } ], payload[:system]
    assert_equal "hi", payload[:messages].last[:content].first[:text]
  end

  test "a schema becomes native json_schema output alongside thinking config" do
    schema = { "type" => "object", "properties" => { "name" => { "type" => "string" } } }
    call(schema: schema, params: { "output_config" => { "effort" => "medium" } })
    output_config = StubbedPost.payloads.last[:output_config]
    assert_equal "medium", output_config[:effort]
    assert_equal "json_schema", output_config.dig(:format, :type)
    assert_equal({ type: "string" }, output_config.dig(:format, :schema, :properties, :name))
  end

  test "a refusal surfaces as its stop reason with empty content" do
    StubbedPost.sse = sse(
      { type: "message_start", message: { model: "claude-sonnet-5", usage: { input_tokens: 9 } } },
      { type: "message_delta", delta: { stop_reason: "refusal" }, usage: { output_tokens: 0 } },
      { type: "message_stop" }
    )
    result = call
    assert_equal "refusal", result.stop_reason
    assert_nil result.content
  end

  test "ruby_llm errors map onto the gateway hierarchy" do
    StubbedPost.error = RubyLLM::RateLimitError.new("429")
    assert_raises(Gateway::RateLimited) { call }
    StubbedPost.error = RubyLLM::OverloadedError.new("529")
    assert_raises(Gateway::Unavailable) { call }
    StubbedPost.error = RubyLLM::UnauthorizedError.new("401")
    assert_raises(Gateway::Unauthorized) { call }
    StubbedPost.error = RubyLLM::BadRequestError.new("400")
    assert_raises(Gateway::Invalid) { call }
  end
end

class TransportToolsTest < TransportTest
  TOOLS = Gateway::ToolDef.normalize([ { "name" => "lookup", "description" => "Look up", "input_schema" => { "type" => "object", "properties" => { "q" => { "type" => "string" } } } } ])

  test "a tool_use stream yields the call unexecuted, with the text before it and stop reason tool_use" do
    StubbedPost.sse = sse(
      { type: "message_start", message: { model: "claude-sonnet-5", usage: { input_tokens: 30 } } },
      { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
      { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Checking." } },
      { type: "content_block_start", index: 1, content_block: { type: "tool_use", id: "toolu_1", name: "lookup", input: {} } },
      { type: "content_block_delta", index: 1, delta: { type: "input_json_delta", partial_json: '{"q": "be' } },
      { type: "content_block_delta", index: 1, delta: { type: "input_json_delta", partial_json: 'es"}' } },
      { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 12 } },
      { type: "message_stop" }
    )
    result = call(tools: TOOLS, tool_choice: "required")
    assert_equal "Checking.", result.content
    assert_equal "tool_use", result.stop_reason
    assert_equal [ { "id" => "toolu_1", "name" => "lookup", "arguments" => { "q" => "bees" } } ], result.tool_calls
    assert_equal 12, result.output_tokens

    payload = StubbedPost.payloads.last
    assert_equal [ { name: "lookup", description: "Look up", input_schema: { "type" => "object", "properties" => { "q" => { "type" => "string" } } } } ], payload[:tools]
    assert_equal({ type: :any }, payload[:tool_choice])
  end

  test "calls and results in the transcript render as tool_use and tool_result blocks" do
    messages = [ user_message("bees?"),
                 { "role" => "assistant", "content" => "", "tool_calls" => [ { "id" => "toolu_1", "name" => "lookup", "arguments" => { "q" => "bees" } } ] },
                 { "role" => "tool", "tool_call_id" => "toolu_1", "content" => "bees: ok" } ]
    call(messages: messages, tools: TOOLS, tool_choice: "none")
    rendered = StubbedPost.payloads.last[:messages]
    assert_equal %w[user assistant user], rendered.map { |m| m[:role] }
    assert_equal({ type: "tool_use", id: "toolu_1", name: "lookup", input: { "q" => "bees" } }, rendered[1][:content].first)
    assert_equal "tool_result", rendered[2][:content].first[:type]
    assert_equal "toolu_1", rendered[2][:content].first[:tool_use_id]
    assert_equal({ type: :none }, StubbedPost.payloads.last[:tool_choice])
  end
end
