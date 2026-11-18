require_relative "test_helper"

class MemoryClientTest < Minitest::Test
  def setup
    @http = FakeHTTP.new
    @hob = Hob::Client.new(http: @http)
  end

  def test_deposit_posts_observations_and_wraps_them
    @http.respond("observations" => [ { "id" => "o1", "about" => "e1", "body" => "replayed scene 4", "status" => "current", "realm" => "intimate" } ])
    rows = @hob.memory.deposit([ { about: "principal:jenner", body: "replayed scene 4", kind: "evidence" } ])
    assert_equal "/v1/memory/observations", @http.requests.last.path
    assert_equal "evidence", @http.requests.last.body[:observations].first[:kind]
    assert_equal "o1", rows.first.id
    assert rows.first.current?
  end

  def test_recall_and_file
    @http.respond("observations" => [ { "id" => "o1", "body" => "x", "score" => 0.8, "reasons" => [ "words" ] } ])
    hits = @hob.memory.recall(query: "what does he linger on", about: [ "principal:jenner" ], persona: "velvet")
    assert_equal({ query: "what does he linger on", about: [ "principal:jenner" ], persona: "velvet" }, @http.requests.last.body)
    assert_in_delta 0.8, hits.first.score

    @http.respond("observations" => [])
    @hob.memory.file(persona: "velvet", about: "principal:jenner")
    assert_equal "/v1/memory/file", @http.requests.last.path
    assert_equal "velvet", @http.requests.last.query[:persona]
  end

  def test_sheet_propose_apply_rollback
    @http.respond("id" => "r1", "version" => 7, "status" => "proposed")
    rev = @hob.sheets.propose("velvet", ops: [ { op: "add", section: "tastes", text: "slow builds" } ], citations: [ "o1" ])
    assert_equal "/v1/personas/velvet/sheet/revisions", @http.requests.last.path
    assert_equal 7, rev.version

    @http.respond("revision" => { "id" => "r1", "status" => "applied" }, "sheet" => {})
    assert_equal "applied", @hob.sheets.apply("velvet", "r1").status

    @http.respond("revision" => { "id" => "r2", "kind" => "rollback", "rollback_to" => 6 }, "sheet" => {})
    assert_equal 6, @hob.sheets.rollback("velvet", version: 6).rollback_to
  end

  def test_chat_carries_memory_and_image_results
    @http.respond("status" => "success", "assistant" => { "content" => "Mm." }, "native" => [ { "name" => "recall" } ], "tool_calls" => [])
    call = Hob::ToolCall.new("id" => "c1", "name" => "look")
    blocks = [ { type: "text", text: "the frame" }, Hob.image("\x89PNG".b, "image/png") ]
    turn = @hob.chat(conversation: "conv", persona: "velvet", memory: true, tool_results: [ call.result(blocks) ])
    body = @http.requests.last.body
    assert_equal true, body[:memory]
    assert_equal "image", body[:tool_results].first[:content].last[:type]
    assert_equal "iVBORw==", body[:tool_results].first[:content].last[:data]
    assert_equal "recall", turn.native.first["name"]
  end
end

class MemoryFakeTest < Minitest::Test
  def test_fake_memory_round_trip
    fake = Hob::Fake.new
    o = fake.memory.remember(about: "principal:jenner", body: "lingers on scene four", persona: "velvet")
    assert_equal [ "lingers on scene four" ], fake.memory.recall(query: "scene").map(&:body)
    assert_equal 1, fake.memory.file(persona: "velvet", about: "principal:jenner").size
    newer = fake.memory.supersede(o.id, body: "lingers on scene five")
    refute fake.memory.observation(o.id).current?
    assert_equal o.id, newer.supersedes

    rev = fake.sheets.propose("velvet", ops: [ { op: "add", section: "tastes", text: "slow" } ], citations: [ newer.id ])
    fake.sheets.apply("velvet", rev.id)
    assert_equal "slow", fake.sheets.show("velvet").sections["tastes"].first["text"]
    fake.sheets.rollback("velvet", version: 0)
    assert_empty fake.sheets.show("velvet").sections
    assert_raises(Hob::Invalid) { fake.sheets.propose("velvet", ops: [ { op: "set", section: "system_core", text: "x" } ], citations: [ "o" ]) }
  end

  def test_fake_native_steps_stream_and_land_on_the_turn
    fake = Hob::Fake.new
    convo = fake.conversations.create
    fake.native(:recall, { query: "scene" }, content: { observations: [] }).reply("Mm.")
    events = []
    turn = fake.chat(conversation: convo, content: "hi", memory: true) { |e| events << e.type }
    assert_equal %w[native_call native_result], events.first(2)
    assert_equal "recall", turn.native.first["name"]
  end
end
