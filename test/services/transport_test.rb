require "test_helper"

# Drives Gateway::Transport through real ruby_llm with the HTTP layer
# replaced: the stub captures the rendered payload and replays Anthropic
# SSE bytes into ruby_llm's own stream handler, so the raw-chunk hook, stop
# reason, token counting, and param translation are all exercised offline.
class TransportTest < ActiveSupport::TestCase
  module StubbedPost
    class << self
      attr_accessor :sse, :payloads, :urls, :error
    end

    def post(url, payload, **)
      StubbedPost.urls << url
      StubbedPost.payloads << payload
      raise StubbedPost.error if StubbedPost.error

      req = Struct.new(:headers, :options).new({}, Faraday::RequestOptions.new)
      yield req
      env = Faraday::Env.new
      env.status = 200
      env.body = ""
      # An array of streams answers successive requests in order.
      body = StubbedPost.sse.is_a?(Array) ? StubbedPost.sse.shift : StubbedPost.sse
      req.options.on_data.call(body, body.bytesize, env)
      Faraday::Response.new(env)
    end
  end

  setup do
    RubyLLM::Transport::Connection.prepend(StubbedPost) unless RubyLLM::Transport::Connection.ancestors.include?(StubbedPost)
    StubbedPost.payloads = []
    StubbedPost.urls = []
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

  test "an openai_compat provider is spoken to in chat completions, and its own finish_reason comes back" do
    StubbedPost.sse = [
      { id: "c1", model: "gpt-test", choices: [ { index: 0, delta: { role: "assistant", content: "Hi." } } ] },
      { id: "c1", model: "gpt-test", choices: [ { index: 0, delta: {}, finish_reason: "stop" } ] }
    ].map { |e| "data: #{JSON.generate(e)}\n\n" }.join + "data: [DONE]\n\n"
    backup = ModelRole::Resolution.new(provider: Provider.find_by!(slug: "backup"), model: "gpt-test", params: {}, strict: false)

    result = call(resolution: backup, params: {})
    assert_equal "chat/completions", StubbedPost.urls.last, "not OpenAI's Responses API, which a compat server does not have"
    assert_equal "Hi.", result.content
    assert_equal "stop", result.stop_reason
    assert_equal "gpt-test", StubbedPost.payloads.last[:model]
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

# MEMORY.md, "Verifying the tool loop": what hob sends Anthropic for images,
# failed tool results, thinking across a tool round, and cache breakpoints.
class TransportConductorTest < TransportTest
  TOOLS = TransportToolsTest::TOOLS
  PNG = "\x89PNG\r\n\x1A\n#{'x' * 32}".b

  def thinking_tool_stream(signature: "sig-abc")
    sse(
      { type: "message_start", message: { model: "claude-sonnet-5", usage: { input_tokens: 30 } } },
      { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "" } },
      { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "He lingered; look closer." } },
      { type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature: signature } },
      { type: "content_block_stop", index: 0 },
      { type: "content_block_start", index: 1, content_block: { type: "tool_use", id: "toolu_1", name: "lookup", input: {} } },
      { type: "content_block_delta", index: 1, delta: { type: "input_json_delta", partial_json: '{"q":"scene 4"}' } },
      { type: "content_block_stop", index: 1 },
      { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 12 } },
      { type: "message_stop" }
    )
  end

  test "a thinking block streamed before a tool call comes back verbatim, signature and all" do
    StubbedPost.sse = thinking_tool_stream
    result = call(tools: TOOLS)
    assert_equal [ { "type" => "thinking", "thinking" => "He lingered; look closer.", "signature" => "sig-abc" } ],
                 result.reasoning["anthropic"]
    assert_equal "toolu_1", result.tool_calls.first["id"]
  end

  test "a thinking-enabled tool round survives the resume: the blocks lead the replayed assistant turn" do
    Gateway.transport = Gateway::Transport.new
    StubbedPost.sse = [ thinking_tool_stream, @default_sse = StubbedPost.sse ]
    StubbedPost.sse[1] = sse(
      { type: "message_start", message: { model: "claude-sonnet-5", usage: { input_tokens: 40 } } },
      { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Scene four, then." } },
      { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 5 } },
      { type: "message_stop" }
    )
    convo = conversation
    preset = Preset.create!(key: "thinking", name: "Thinking", stages: Assembly::Pipeline::STAGE_DEFAULTS,
                            params: { "thinking" => { "type" => "adaptive" } })
    first = ChatTurn.new(conversation: convo, branch: convo.branch, content: "what now?", tools: TOOLS,
                         role: "interviewer", preset: preset).call
    assert_equal "tool_calls", first.status
    assert first.tool_call_nodes.first.meta["reasoning"], "the call node keeps the thinking blocks"

    ChatTurn.new(conversation: convo, branch: convo.branch, tools: TOOLS, role: "interviewer", preset: preset,
                 tool_results: [ { "id" => "toolu_1", "content" => "scene 4: 3 replays" } ]).call
    replayed = StubbedPost.payloads.last[:messages]
    assert_equal %w[user assistant user], replayed.map { |m| m[:role] }
    blocks = replayed[1][:content]
    assert_equal({ "type" => "thinking", "thinking" => "He lingered; look closer.", "signature" => "sig-abc" }, blocks.first)
    assert_equal "tool_use", blocks.last[:type]
    assert_equal({ type: "adaptive" }, StubbedPost.payloads.last[:thinking])
  end

  test "images ride in user turns and tool results as base64 image blocks" do
    blob = Blob.store!(bytes: PNG, media_type: "image/png", realm: "personal")
    image = [ { "type" => "image", "media_type" => "image/png", "digest" => blob.digest } ]
    messages = [ { "role" => "user", "content" => "what is this?", "attachments" => image },
                 { "role" => "assistant", "content" => "", "tool_calls" => [ { "id" => "toolu_1", "name" => "lookup", "arguments" => {} } ] },
                 { "role" => "tool", "tool_call_id" => "toolu_1", "content" => "the frame", "attachments" => image } ]
    call(messages: messages, tools: TOOLS)
    rendered = StubbedPost.payloads.last[:messages]
    user_image = rendered[0][:content].find { |b| b[:type] == "image" }
    assert_equal({ type: "base64", media_type: "image/png", data: Base64.strict_encode64(PNG) }, user_image[:source])
    tool_result = rendered[2][:content].first
    assert_equal "tool_result", tool_result[:type]
    assert_equal %w[text image], tool_result[:content].map { |b| b[:type] }
  end

  test "a failed tool result reaches Anthropic with is_error" do
    messages = [ user_message("go"),
                 { "role" => "assistant", "content" => "", "tool_calls" => [ { "id" => "toolu_1", "name" => "lookup", "arguments" => {} } ] },
                 { "role" => "tool", "tool_call_id" => "toolu_1", "content" => "no such scene", "error" => true } ]
    call(messages: messages, tools: TOOLS)
    block = StubbedPost.payloads.last[:messages].last[:content].first
    assert_equal true, block[:is_error]
    assert_equal "toolu_1", block[:tool_use_id]
  end

  test "an openai_compat tool result that failed says so in words" do
    @resolution = ModelRole.find_role!("extractor").candidates.last
    StubbedPost.sse = "data: #{JSON.generate(choices: [ { delta: { content: "ok" }, finish_reason: 'stop' } ])}\n\ndata: [DONE]\n\n"
    messages = [ user_message("go"),
                 { "role" => "assistant", "content" => "", "tool_calls" => [ { "id" => "c1", "name" => "lookup", "arguments" => {} } ] },
                 { "role" => "tool", "tool_call_id" => "c1", "content" => "no such scene", "error" => true } ]
    call(messages: messages, tools: TOOLS)
    assert_equal "[tool error] no such scene", StubbedPost.payloads.last[:messages].last[:content]
  end

  test "the cache breakpoint sits where the caller marked the stable prefix's end" do
    messages = [ user_message("one"), { "role" => "assistant", "content" => "two" },
                 user_message("three").merge("cache" => true), user_message("[Situation: now]") ]
    call(messages: messages)
    rendered = StubbedPost.payloads.last[:messages]
    marked = rendered.flat_map { |m| m[:content] }.select { |b| b[:cache_control] }
    assert_equal [ "three" ], marked.map { |b| b[:text] }
    assert_equal({ type: "ephemeral" }, marked.first[:cache_control])
  end
  test "embed reads vectors and token usage off ruby_llm's Embedding" do
    fake = Module.new do
      def embed(texts, **)
        RubyLLM::Embedding.new(vectors: texts.map { [ 0.1, 0.2 ] }, model: "text-embedding-test", input_tokens: 9)
      end
    end
    RubyLLM::Context.prepend(fake)
    backup = ModelRole::Resolution.new(provider: Provider.find_by!(slug: "backup"), model: "text-embedding-test", params: {}, strict: false)

    result = Gateway::Transport.new.embed(resolution: backup, texts: %w[one two])
    assert_equal [ [ 0.1, 0.2 ], [ 0.1, 0.2 ] ], result[:vectors]
    assert_equal 9, result[:input_tokens]
  ensure
    fake&.send(:remove_method, :embed)
  end
end

# A gemini provider speaks Google's generateContent: its own finishReason,
# a block as a refusal, and each function call's thought signature kept for
# the replay Gemini 3 insists on.
class TransportGeminiTest < ActiveSupport::TestCase
  TOOLS = TransportToolsTest::TOOLS
  StubbedPost = TransportTest::StubbedPost

  setup do
    RubyLLM::Transport::Connection.prepend(StubbedPost) unless RubyLLM::Transport::Connection.ancestors.include?(StubbedPost)
    StubbedPost.payloads = []
    StubbedPost.urls = []
    StubbedPost.error = nil
    ENV["HOB_TEST_GEMINI_KEY"] = "g-test"
    provider = Provider.find_or_create_by!(slug: "gemini") do |p|
      p.kind = "gemini"
      p.config = { "api_key_env" => "HOB_TEST_GEMINI_KEY", "base_url" => "http://vertex.test/v1/publishers/google" }
    end
    @resolution = ModelRole::Resolution.new(provider: provider, model: "gemini-3.5-flash", params: {}, strict: false)
    StubbedPost.sse = gemini_sse(
      { candidates: [ { content: { role: "model", parts: [ { text: "Hello, " } ] } } ], modelVersion: "gemini-3.5-flash" },
      { candidates: [ { content: { role: "model", parts: [ { text: "world." } ] }, finishReason: "STOP" } ],
        usageMetadata: { promptTokenCount: 30, cachedContentTokenCount: 10, candidatesTokenCount: 4, thoughtsTokenCount: 6 },
        modelVersion: "gemini-3.5-flash" }
    )
  end

  def call(**opts, &on_delta)
    Gateway::Transport.new.call(**{ resolution: @resolution, system: "Be kind.", schema: nil,
                                    messages: [ user_message("hi") ], params: {} }.merge(opts), &on_delta)
  end

  def gemini_sse(*events)
    events.map { |e| "data: #{JSON.generate(e)}\n\n" }.join
  end

  def tool_call_stream
    gemini_sse(
      { candidates: [ { content: { role: "model", parts: [
        { functionCall: { name: "lookup", args: { q: "bees" } }, thoughtSignature: "sig-g1" },
        { functionCall: { name: "lookup", args: { q: "wasps" } } }
      ] }, finishReason: "STOP" } ], usageMetadata: { promptTokenCount: 20, candidatesTokenCount: 8 }, modelVersion: "gemini-3.5-flash" }
    )
  end

  test "streams text, keeps Gemini's own finishReason, counts tokens, and turns max_tokens into maxOutputTokens" do
    deltas = []
    result = call(params: { "max_tokens" => 2048, "generationConfig" => { "thinkingConfig" => { "thinkingLevel" => "low" } } }) { |d| deltas << d }

    assert_equal "Hello, world.", result.content
    assert_equal [ "Hello, ", "world." ], deltas
    assert_equal "STOP", result.stop_reason
    assert_equal [ 20, 10, 10 ], [ result.input_tokens, result.output_tokens, result.cache_read_tokens ]
    assert_equal "gemini-3.5-flash", result.model

    assert_equal "models/gemini-3.5-flash:streamGenerateContent?alt=sse", StubbedPost.urls.last
    payload = StubbedPost.payloads.last
    assert_equal({ maxOutputTokens: 2048, thinkingConfig: { thinkingLevel: "low" } }, payload[:generationConfig])
    assert_nil payload[:max_tokens]
    assert_equal({ parts: [ { text: "Be kind." } ] }, payload[:systemInstruction])
  end

  test "a blocked reply is a refusal, in Gemini's word" do
    StubbedPost.sse = gemini_sse({ candidates: [ { finishReason: "SAFETY" } ], usageMetadata: { promptTokenCount: 9 } })
    result = call
    assert_equal "SAFETY", result.stop_reason
    response = Gateway::Response.from_transport(result, resolution: @resolution, started: 0)
    assert response.refused?
    refute response.empty?
  end

  test "a function call comes back unexecuted, its thought signature kept by call id" do
    StubbedPost.sse = tool_call_stream
    result = call(tools: TOOLS)
    assert_equal [ { "q" => "bees" }, { "q" => "wasps" } ], result.tool_calls.map { |tc| tc["arguments"] }
    first, second = result.tool_calls.map { |tc| tc["id"] }
    assert_equal({ "gemini" => { first => "sig-g1" } }, result.reasoning)
    refute_includes result.reasoning["gemini"].keys, second
  end

  test "a resumed tool round replays each call with the signature Gemini gave it" do
    StubbedPost.sse = [ tool_call_stream, StubbedPost.sse ]
    first = call(tools: TOOLS)
    ids = first.tool_calls.map { |tc| tc["id"] }
    messages = [ user_message("bees?"),
                 { "role" => "assistant", "content" => "", "tool_calls" => first.tool_calls, "reasoning" => first.reasoning },
                 { "role" => "tool", "tool_call_id" => ids[1], "content" => "wasps: ok" },
                 { "role" => "tool", "tool_call_id" => ids[0], "content" => "bees: no", "error" => true } ]
    call(messages: messages, tools: TOOLS)

    contents = StubbedPost.payloads.last[:contents]
    assert_equal %w[user model user], contents.map { |c| c[:role] }
    calls = contents[1][:parts]
    assert_equal "sig-g1", calls[0][:thoughtSignature]
    assert_nil calls[1][:thoughtSignature]
    responses = contents[2][:parts].map { |p| p[:functionResponse] }
    assert_equal %w[lookup lookup], responses.map { |r| r[:name] }
    assert_equal [ "[tool error] bees: no", "wasps: ok" ], responses.map { |r| r.dig(:response, :content).first[:text] },
                 "results go back in call order, a failure said in words"
  end

  test "a tool round another provider made reaches Gemini with the documented stand-in signature" do
    messages = [ user_message("bees?"),
                 { "role" => "assistant", "content" => "", "tool_calls" => [ { "id" => "toolu_1", "name" => "lookup", "arguments" => { "q" => "bees" } } ],
                   "reasoning" => { "anthropic" => [ { "type" => "thinking", "thinking" => "hm", "signature" => "sig-a" } ] } },
                 { "role" => "tool", "tool_call_id" => "toolu_1", "content" => "bees: ok" } ]
    call(messages: messages, tools: TOOLS)
    call_part = StubbedPost.payloads.last[:contents][1][:parts].first
    assert_equal "skip_thought_signature_validator", call_part[:thoughtSignature]
    refute StubbedPost.payloads.last[:contents][1][:parts].any? { |p| p[:thought] }, "Anthropic's thinking stays with Anthropic"
  end

  test "Gemini has no embeddings here" do
    assert_raises(Gateway::Invalid) { Gateway::Transport.new.embed(resolution: @resolution, texts: %w[one]) }
  end
end
