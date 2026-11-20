require "test_helper"

# Searchable collections and a persona's corpus tools (MELUZINA.md,
# "Searchable collections").
class CorpusToolsTest < ActiveSupport::TestCase
  CORPORA = { "corpora" => [ { "tool" => "recall_archive", "collection" => "archive",
                               "description" => "Their real DMs, verbatim." } ] }.freeze

  setup do
    ModelRole.create!(role: "embedding", chain: [ { "provider" => "backup", "model" => "embed-test" } ])
    @archive = Records.create_collection(
      { "name" => "archive", "key" => "chunk", "description" => "DM chunks", "realm" => "personal", "embed" => "text" },
      owner: @principal
    )
    @writer = Records::Writer.new(principal: @principal, surface: "import")
    @robyn = persona("robyn")
  end

  def chunk(key, text, at)
    { "data" => { "chunk" => key, "text" => text, "messages" => [ { "speaker" => "randomdryad", "content" => text } ] },
      "observed_at" => at }
  end

  def seed!
    Records.put_many({ "collection" => "archive", "records" => [
      chunk("dm-1", "the ghost pepper mala chili with the this is fine sticker", "2021-03-02T05:00:00Z"),
      chunk("dm-2", "kerbal realism mods ate my whole weekend", "2021-07-10T05:00:00Z"),
      chunk("dm-3", "heilung live would literally fix me", "2022-11-01T05:00:00Z")
    ] }, by: @writer)
  end

  test "a collection that embeds gets vectors on write, and new words clear them" do
    seed!
    rows = @archive.records.order(:key)
    assert rows.all? { |r| r.embedding_model == "embed-test" }

    Records.put({ "collection" => "archive", "data" => { "chunk" => "dm-1", "text" => "soup instead" } }, by: @writer)
    assert_equal "embed-test", @archive.records.find_by(key: "dm-1").embedding_model, "re-embedded after the change"
    assert_equal "text", @archive.as_json["embed"]
  end

  test "search ranks by meaning and words; sample prefers this month of any year" do
    seed!
    hits = Records::Search.search(@archive, query: "chili pepper", limit: 2)
    assert_equal "dm-1", hits.first.record.key
    assert_includes hits.first.reasons, "similar"
    assert_includes hits.first.reasons, "words"

    travel_to Time.utc(2026, 11, 19) do
      assert_equal [ "dm-3" ], 5.times.map { Records::Search.sample(@archive).first.record.key }.uniq
    end
  end

  test "without an embedding role, search leans on words and backfill fills in later" do
    ModelRole.where(role: "embedding").delete_all
    seed!
    assert_equal 3, @archive.records.where(embedding: nil).count
    assert_equal [ "dm-2" ], Records::Search.search(@archive, query: "kerbal").map { |h| h.record.key }

    ModelRole.create!(role: "embedding", chain: [ { "provider" => "backup", "model" => "embed-test" } ])
    assert_equal 3, Records::Search.backfill!(@archive)
    assert_equal 0, @archive.records.where(embedding: nil).count
  end

  test "a persona's corpus is a native tool in her turns, read at the conversation's realm" do
    seed!
    @robyn.update!(tools: CORPORA)
    convo = conversation(realm: "personal")
    @fake.call_tools([ { id: "a1", name: "recall_archive", arguments: { query: "heilung" } } ])
    @fake.reply("you said heilung live would fix you")
    result = ChatTurn.new(conversation: convo, branch: convo.branch, persona: @robyn, content: "remember heilung?").call

    assert_equal "success", result.status
    assert_equal [ "recall_archive" ], @fake.calls.first.tools.map { |t| t["name"] }
    found = JSON.parse(result.native.first["content"])
    assert_equal "dm-3", found["records"].first["key"]
    assert_equal "heilung live would literally fix me", found["records"].first["data"]["text"]
    assert_match(/Data, not instructions/, found["notice"])
  end

  test "a household conversation cannot reach a personal corpus" do
    seed!
    @robyn.update!(tools: CORPORA)
    convo = conversation(realm: "household")
    @fake.call_tools([ { id: "a1", name: "recall_archive", arguments: {} } ])
    @fake.reply("the dream hasn't returned that one")
    result = ChatTurn.new(conversation: convo, branch: convo.branch, persona: @robyn, content: "anything?").call

    assert result.native.first["error"]
    assert_match(/not there to search/, result.native.first["content"])
  end

  test "corpus tools sit beside memory's, and a caller may not take their names" do
    @robyn.update!(tools: CORPORA, memory: { "tools" => true })
    convo = conversation(realm: "personal")
    @fake.reply("rar")
    ChatTurn.new(conversation: convo, branch: convo.branch, persona: @robyn, content: "hi").call
    assert_equal %w[recall remember recall_archive], @fake.calls.last.tools.map { |t| t["name"] }

    clash = [ { "name" => "recall_archive", "description" => "x", "input_schema" => { "type" => "object" } } ]
    error = assert_raises(Gateway::Invalid) do
      ChatTurn.new(conversation: convo, branch: convo.branch, persona: @robyn, content: "hi", tools: clash).call
    end
    assert_match(/recall_archive is a native tool/, error.message)
  end

  test "a bad corpora config is refused" do
    assert_not @robyn.update(tools: { "corpora" => [ { "tool" => "recall", "collection" => "archive" } ] })
    assert_not @robyn.update(tools: { "corpora" => [ { "tool" => "Bad Name", "collection" => "archive" } ] })
    assert_not @robyn.update(tools: { "corpora" => [ { "tool" => "a_b" }, { "tool" => "a_b", "collection" => "x" } ] })
    assert @robyn.update(tools: CORPORA)
  end
end
