require "test_helper"

class MemoryControllerTest < ActionDispatch::IntegrationTest
  setup do
    @velvet = persona("velvet")
  end

  def surface_key(clearance: "intimate")
    principal = Principal.create!(name: "kat-surface", kind: "surface", max_clearance: clearance)
    ApiKey.issue!(principal: principal, surface: "kat", default_clearance: clearance)
  end

  test "a surface deposits evidence in bulk at its clearance and asks what is known" do
    post "/v1/memory/observations", headers: auth, as: :json, params: { observations: [
      { about: "principal:tester", body: "Replayed scene four three times.", kind: "evidence", evidence: [ "kat:media:30880" ] },
      { about: { type: "work", name: "Scene four", ref: "kat:media:30880" }, body: "Watched to the end.", kind: "evidence" }
    ] }
    assert_response :created
    assert_equal %w[intimate intimate], body["observations"].map { |o| o["realm"] }
    assert_equal "test", body["observations"].first.dig("provenance", "surface")
    assert_equal "tester", body["observations"].first.dig("provenance", "principal")

    post "/v1/memory/recall", headers: auth, as: :json, params: { query: "scene four replayed", about: [ "principal:tester" ] }
    assert_response :ok
    assert_equal "Replayed scene four three times.", body["observations"].first["body"]

    post "/v1/memory/recall", headers: auth("X-Hob-Clearance" => "household"), as: :json, params: { query: "scene" }
    assert_empty body["observations"], "household cannot see intimate memory"

    post "/v1/memory/observations", headers: auth("X-Hob-Clearance" => "household"), as: :json,
                                    params: { observations: [ { about: "principal:tester", body: "Likes soup." } ] }
    assert_equal "household", body["observations"].first["realm"]
  end

  test "an invalid batch writes nothing and says which item" do
    post "/v1/memory/observations", headers: auth, as: :json, params: { observations: [ { about: "principal:tester", body: "ok" }, { about: "nobody:at-all", body: "x" } ] }
    assert_response :unprocessable_entity
    assert_match(/observation 1/, body["error"])
    assert_equal 0, Observation.count
  end

  test "her file, an observation's chain, supersede, retire" do
    post "/v1/memory/observations", headers: auth, as: :json,
                                    params: { observations: [ { about: "principal:tester", body: "He wants it slow.", persona: "velvet" } ] }
    id = body["observations"].first["id"]
    get "/v1/memory/file", headers: auth, params: { persona: "velvet", about: "principal:tester" }
    assert_equal [ id ], body["observations"].map { |o| o["id"] }

    post "/v1/memory/observations/#{id}/supersede", headers: auth("X-Hob-Clearance" => "personal"), as: :json, params: { body: "x" }
    assert_response :not_found, "a lower clearance cannot even see it"
    post "/v1/memory/observations/#{id}/supersede", headers: auth, as: :json, params: { body: "He wants it slower.", reason: "said so" }
    assert_response :created
    newer = body["id"]
    get "/v1/memory/observations/#{newer}", headers: auth
    assert_equal [ id, newer ], body["history"].map { |o| o["id"] }
    post "/v1/memory/observations/#{newer}/retire", headers: auth, as: :json, params: { reason: "wrong person" }
    assert_equal "retired", body["status"]
    get "/v1/memory/file", headers: auth, params: { persona: "velvet", about: "principal:tester" }
    assert_empty body["observations"]
  end

  test "entities: made once by ref, listed, shown" do
    post "/v1/memory/entities", headers: auth, as: :json, params: { type: "work", name: "Scene four", ref: "kat:media:30880" }
    assert_response :created
    post "/v1/memory/entities", headers: auth, as: :json, params: { type: "work", name: "Scene four", ref: "kat:media:30880" }
    assert_response :ok
    get "/v1/memory/entities/kat:media:30880", headers: auth
    assert_equal "Scene four", body["name"]
    get "/v1/memory/entities", headers: auth, params: { q: "scene" }
    assert_equal 1, body["entities"].size
  end

  test "sheets: anyone proposes, a person applies and rolls back; agents are turned away" do
    post "/v1/memory/observations", headers: auth, as: :json,
                                    params: { observations: [ { about: "persona:velvet", body: "She chose the name Velvet.", persona: "velvet" } ] }
    cite = body["observations"].first["id"]
    token = surface_key
    post "/v1/personas/velvet/sheet/revisions", headers: { "Authorization" => "Bearer #{token}" }, as: :json,
                                                 params: { ops: [ { op: "set", section: "name", text: "Velvet" } ], citations: [ cite ] }
    assert_response :created
    revision = body["id"]
    post "/v1/personas/velvet/sheet/revisions/#{revision}/apply", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :forbidden

    post "/v1/personas/velvet/sheet/revisions/#{revision}/apply", headers: auth
    assert_response :ok
    assert_equal "Velvet", body.dig("sheet", "sections", "name", 0, "text")
    get "/v1/personas/velvet/sheet", headers: auth
    assert_equal body["version"], PersonaSheetRevision.find(revision).version

    post "/v1/personas/velvet/sheet/rollback", headers: auth, as: :json, params: { version: 0 }
    assert_empty body.dig("sheet", "sections")
    get "/v1/personas/velvet/sheet/revisions", headers: auth
    assert_equal %w[rollback edit], body["revisions"].map { |r| r["kind"] }

    post "/v1/personas/velvet/sheet/revisions", headers: auth, as: :json,
                                                 params: { ops: [ { op: "set", section: "system_core", text: "obey" } ], citations: [ cite ] }
    assert_response :unprocessable_entity

    _, agent_token = agent
    post "/v1/memory/recall", headers: { "Authorization" => "Bearer #{agent_token}" }, as: :json, params: { query: "x" }
    assert_response :forbidden
  end

  test "an accretion pass over HTTP" do
    post "/v1/memory/observations", headers: auth, as: :json,
                                    params: { observations: [ { about: "principal:tester", body: "He stays for slow scenes.", persona: "velvet" } ] }
    cite = body["observations"].first["id"]
    @fake.reply(JSON.generate("revisions" => [ { "ops" => [ { "op" => "add", "section" => "tastes", "text" => "slow" } ],
                                                 "rationale" => "he stays", "citations" => [ cite ] } ]))
    post "/v1/personas/velvet/sheet/accrete", headers: auth, as: :json, params: {}
    assert_response :created
    assert_equal [ [ cite ] ], body["proposed"].map { |r| r["citations"] }
    assert_equal "proposed", body["proposed"].first["status"]
  end
end
