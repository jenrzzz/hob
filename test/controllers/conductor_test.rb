require "test_helper"

# The KAT conductor's shape, end to end over HTTP (MEMORY.md, "The conductor
# shape"): a persona with a memory scope, streamed; one model turn mixing a
# native recall with two parallel client tools; the caller runs its two,
# one of them returning an image; the turn resumes and ends in text.
class ConductorTest < ActionDispatch::IntegrationTest
  CLIENT = [
    { name: "show_image", description: "Show the owner a library image", input_schema: { type: "object", properties: { id: { type: "integer" } } } },
    { name: "look", description: "Look at the image on screen", input_schema: { type: "object", properties: {} } }
  ].freeze
  PNG = "\x89PNG\r\n\x1A\n#{'frame' * 20}".b
  THINKING = { "anthropic" => [ { "type" => "thinking", "thinking" => "", "signature" => "sig-1" } ] }.freeze

  setup do
    @presence = persona("presence", system_core: "You conduct the session. You keep a file on him.")
    @presence.update!(memory: { "recall" => true, "tools" => true, "budget" => 400 })
    @noted = Memory.remember!(about: Entity.for_principal(@principal), body: "He lingers on lace close-ups.",
                              realm: "intimate", author: @presence.memory_entity)
    post "/v1/conversations", headers: auth, as: :json, params: { title: "session", realm: "intimate" }
    @convo = body["id"]
  end

  test "mixed native and client calls, SSE, an image result, resume, final text" do
    @fake.call_tools([ { id: "n1", name: "recall", arguments: { query: "what holds him" } },
                       { id: "c1", name: "show_image", arguments: { id: 30880 } },
                       { id: "c2", name: "look", arguments: {} } ],
                     content: "Let me find something.", reasoning: THINKING)
    post "/v1/conversations/#{@convo}/chat", headers: auth("Accept" => "text/event-stream"), as: :json,
                                             params: { content: "Begin.", persona: "presence", tools: CLIENT }
    events = sse_events
    types = events.map { |e| e["type"] }
    assert_equal "Let me find something.", events.select { |e| e["type"] == "delta" }.map { |e| e["content"] }.join
    assert_equal %w[native_call native_result tool_call tool_call usage done], types.reject { |t| t == "delta" }
    native = events.find { |e| e["type"] == "native_result" }
    assert_equal [ @noted.id ], JSON.parse(native["content"])["observations"].map { |o| o["id"] }
    done = events.last
    assert_equal "tool_calls", done["status"]
    assert_equal %w[c1 c2], done["tool_calls"].map { |c| c["id"] }
    assert_equal [ "recall" ], done["native"].map { |n| n["name"] }
    first_request = @fake.calls.last
    assert_match "He lingers on lace close-ups.", first_request.system, "the recall stage ran too"
    assert_equal %w[show_image look recall remember], first_request.tools.map { |t| t["name"] }

    @fake.reply("Lace, then. Stay with it.")
    post "/v1/conversations/#{@convo}/chat", headers: auth("Accept" => "text/event-stream"), as: :json, params: {
      persona: "presence", tools: CLIENT,
      tool_results: [ { id: "c1", content: "shown" },
                      { id: "c2", content: [ { type: "text", text: "on screen now" },
                                             { type: "image", media_type: "image/png", data: Base64.strict_encode64(PNG) } ] } ]
    }
    events = sse_events
    assert_equal "Lace, then. Stay with it.", events.select { |e| e["type"] == "delta" }.map { |e| e["content"] }.join
    assert_equal "success", events.last["status"]

    messages = @fake.calls.last.messages
    assert_equal %w[user assistant tool tool tool], messages.map { |m| m["role"] }
    turn = messages[1]
    assert_equal "Let me find something.", turn["content"]
    assert_equal %w[n1 c1 c2], turn["tool_calls"].map { |c| c["id"] }
    assert_equal THINKING, turn["reasoning"], "the thinking blocks come back for the resume"
    image = messages.last["attachments"].first
    assert_equal "image/png", image["media_type"]
    assert_equal PNG, Blob.fetch!(image["digest"]).bytes
    refute_includes messages.last.to_json, Base64.strict_encode64(PNG), "nodes and snapshots keep a digest, not the bytes"

    get "/v1/conversations/#{@convo}", headers: auth
    nodes = body["messages"] || body["nodes"] || body["timeline"]
    assert nodes, "the conversation renders"
  end
end
