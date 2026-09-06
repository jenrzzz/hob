require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @convo = conversation(realm: "household")
  end

  test "an assistant-initiated turn over the API" do
    persona("interviewer", instruction: "Ask the next question.")
    @fake.reply("What is it about?")
    post "/v1/conversations/#{@convo.id}/chat", params: { persona: "interviewer" }, headers: auth, as: :json

    assert_response :ok
    assert_nil body["user"]
    assert_equal "What is it about?", body.dig("assistant", "content")
    assert_equal 1, body["assistants"].size
  end

  test "context blocks, instruction, and ensembles ride the chat request" do
    persona("saffron")
    persona("maggie")
    @fake.reply("[saffron]\nSoup.\n[maggie]\nBread.")
    post "/v1/conversations/#{@convo.id}/chat", params: {
      content: "dinner?", personas: %w[saffron maggie], instruction: "Keep it short.",
      context: [ { name: "plan", body: "Monday: soup" }, { name: "recent", body: "x", volatile: true } ]
    }, headers: auth, as: :json

    assert_response :ok
    assert_equal %w[saffron maggie], body["assistants"].map { |n| n["speaker"] }
    call = @fake.calls.last
    assert_includes call.system, "### plan"
    assert_equal "Keep it short.", call.messages.last["content"]

    get "/v1/conversations/#{@convo.id}", headers: auth
    assert_equal %w[user assistant assistant], body["messages"].map { |m| m["role"] }
  end

  test "a refused chat turn is 200 with status refused" do
    @fake.refuse
    post "/v1/conversations/#{@convo.id}/chat", params: { content: "hmm" }, headers: auth, as: :json
    assert_response :ok
    assert_equal "refused", body["status"]
  end

  test "SSE streams deltas then usage and done" do
    @fake.reply("Streamed reply")
    post "/v1/conversations/#{@convo.id}/chat", params: { content: "hi" }, headers: auth("Accept" => "text/event-stream"), as: :json
    events = sse_events
    assert_equal "Streamed reply", events.select { |e| e["type"] == "delta" }.map { |e| e["content"] }.join
    assert_equal %w[usage done], events.last(2).map { |e| e["type"] }
    assert_equal "Streamed reply", events.last.dig("assistant", "content")
  end

  test "events append to the timeline and stay out of the prompt" do
    post "/v1/conversations/#{@convo.id}/events", params: { content: "Added Soup to Monday", meta: { recipe: 3 } }, headers: auth, as: :json
    assert_response :created
    assert_equal "event", body["role"]
    assert_equal({ "recipe" => 3 }, body["meta"])

    @fake.reply("Noted.")
    post "/v1/conversations/#{@convo.id}/chat", params: { content: "thanks" }, headers: auth, as: :json
    assert_equal [ "thanks" ], @fake.calls.last.messages.map { |m| m["content"] }

    get "/v1/conversations/#{@convo.id}", headers: auth
    assert_equal %w[event user assistant], body["messages"].map { |m| m["role"] }
  end

  test "pipeline conversations are hidden from the listing by default" do
    conversation(realm: "household", kind: "pipeline")
    get "/v1/conversations", headers: auth
    assert_equal [ "chat" ], body.map { |c| c["kind"] }.uniq
    get "/v1/conversations", params: { kind: "all" }, headers: auth
    assert_equal %w[chat pipeline], body.map { |c| c["kind"] }.sort.uniq
  end
end
