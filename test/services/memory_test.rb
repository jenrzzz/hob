require "test_helper"

class MemoryTest < ActiveSupport::TestCase
  setup do
    @velvet = persona("velvet")
    @jenner = Entity.for_principal(@principal)
  end

  def embeddings!
    ModelRole.create!(role: "embedding", chain: [ { "provider" => "backup", "model" => "embed-test" } ])
  end

  test "entities resolve by id, ref, name, and principal/persona refs made on first use" do
    media = Memory.entity({ "type" => "work", "name" => "Scene four", "ref" => "kat:media:30880" }, create: true)
    assert_equal media, Memory.entity("kat:media:30880")
    assert_equal media, Memory.entity(media.id)
    assert_equal media, Memory.entity("scene four")
    assert_equal @jenner, Memory.entity("principal:tester")
    velvet = Memory.entity("persona:velvet")
    assert_equal velvet, @velvet.reload.entity
    assert_equal "persona", @velvet.entity.kind
    assert_raises(Memory::NotFound) { Memory.entity("kat:media:nope") }
  end

  test "an observation carries its realm and provenance from the request, and is never rewritten" do
    Current.surface = "kat"
    o = Memory.remember!(about: "principal:tester", body: "Replayed scene four twice.", kind: "evidence",
                         realm: "intimate", evidence: [ "kat:media:30880" ])
    assert_equal [ @principal, "kat", "intimate" ], [ o.principal, o.surface, o.realm ]
    assert_raises(ActiveRecord::ReadOnlyRecord) { o.update!(body: "something else") }
    assert_raises(Gateway::Invalid) { as(@principal, realm: "household") { Memory.remember!(about: @jenner, body: "x", realm: "personal") } }
  end

  test "RLS: a lower clearance cannot see a higher realm's observations, by any read" do
    secret = Memory.remember!(about: @jenner, body: "He likes it slow.", realm: "intimate")
    plain = Memory.remember!(about: @jenner, body: "He likes soup.", realm: "household")
    as(@principal, realm: "household") do
      assert_nil Observation.find_by(id: secret.id)
      ids = Memory.recall(query: "he likes", about: [ @jenner.id ]).map { |h| h.observation.id }
      assert_equal [ plain.id ], ids
    end
    ids = Memory.recall(query: "he likes", about: [ @jenner.id ]).map { |h| h.observation.id }
    assert_equal [ secret.id, plain.id ].sort, ids.sort
  end

  test "supersede keeps the chain; a correction happens only at the old one's realm" do
    old = Memory.remember!(about: @jenner, body: "Prefers mornings.", realm: "personal")
    assert_raises(Gateway::Invalid) { Memory.supersede!(old, body: "Prefers nights.", realm: "intimate") }

    newer = Memory.supersede!(old, body: "Prefers nights.", realm: "personal", reason: "he said so")
    assert_equal "superseded", old.reload.status
    assert_equal old.id, newer.supersedes_id
    assert_equal [ old, newer ], Memory.history(newer)
    assert_raises(Gateway::Invalid) { Memory.supersede!(old, body: "again", realm: "personal") }
    assert_raises(Gateway::Invalid) { Memory.retire!(newer, reason: "", realm: "personal") }
    Memory.retire!(newer, reason: "wrong", realm: "personal")
    assert_empty Memory.recall(query: "prefers")
  end

  test "her file on him is what she authored about him" do
    Memory.remember!(about: @jenner, body: "He asked for the slow version.", realm: "intimate", author: @velvet.memory_entity)
    Memory.remember!(about: @jenner, body: "kat saw a replay.", realm: "intimate")
    Memory.remember!(about: @velvet.memory_entity, body: "I prefer to wait.", realm: "intimate", author: @velvet.memory_entity)
    file = Memory.file(persona: @velvet, about: "principal:tester")
    assert_equal [ "He asked for the slow version." ], file.map(&:body)
  end

  test "deposit is all or nothing and names the bad item" do
    error = assert_raises(Gateway::Invalid) do
      Memory.deposit!([ { "about" => "principal:tester", "body" => "fine" }, { "about" => "principal:tester", "body" => "" } ], realm: "intimate")
    end
    assert_match(/observation 1/, error.message)
    assert_equal 0, Observation.count
    rows = Memory.deposit!([ { "about" => { "type" => "work", "name" => "Clip 9", "ref" => "kat:media:9" }, "body" => "watched to the end" } ], realm: "intimate")
    assert_equal "kat:media:9", rows.first.entity.ref
  end

  test "recall is hybrid: entity, words, vectors, and recency; cut to a budget" do
    embeddings!
    a = Memory.remember!(about: @jenner, body: "Lingered on the lace close-up for a long time.", realm: "intimate")
    b = Memory.remember!(about: @jenner, body: "Skipped the loud scenes quickly.", realm: "intimate", observed_at: 90.days.ago)
    other = Memory.remember!(about: { "type" => "place", "name" => "Kitchen" }, body: "The kettle is broken.", realm: "household")
    assert a.reload.embedding_model, "embedded through the embedding role"
    assert_equal 3, @fake.embeds.flatten.size

    hits = Memory.recall(query: "lace close-up", about: [ @jenner.id ])
    assert_equal a.id, hits.first.observation.id
    assert_includes hits.first.reasons, "similar"
    assert_includes hits.first.reasons, "words"
    refute_includes hits.map { |h| h.observation.id }, other.id
    assert_equal [ a.id ], Memory.recall(query: "lace", about: [ @jenner.id ], budget: 10).map { |h| h.observation.id }
    assert_equal %w[memory.embed memory.recall], UsageEvent.where(role: "embedding").order(:id).pluck(:operation).uniq
    assert b
  end

  test "without an embedding role, recall still works on words and entities" do
    o = Memory.remember!(about: @jenner, body: "Lingered on the lace.", realm: "intimate")
    assert_nil o.reload.embedding
    assert_equal [ o.id ], Memory.recall(query: "lace").map { |h| h.observation.id }
  end
end
