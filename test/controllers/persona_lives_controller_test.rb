require "test_helper"

# A persona's life over HTTP (PersonaLife): kat reads it, moves the chew in
# conversation, and imports the life it kept before hob did.
class PersonaLivesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @mel = persona("mel")
    @mel.update!(life: { "instruction" => "beats", "realm" => "personal" })
  end

  test "import fills an empty life once, and show reads it back" do
    post "/v1/personas/mel/life/import", params: {
      diary: [ { entry: "made soup", at: "2026-11-18T08:00:00Z", lane: "kitchen" },
               { entry: "misha ate a sock", at: "2026-11-19T08:00:00Z" } ],
      mood: { disposition: "rar", obsession: "soup", manifestation: 0.4, at: "2026-11-19T08:00:00Z" },
      chew: { subject: "the strike", from: "paper", take: "it's bad",
              notes: [ { note: "read it", at: "2026-11-15T08:00:00Z" }, { note: "worse", at: "2026-11-17T08:00:00Z" } ],
              picked_up_at: "2026-11-15T08:00:00Z", moved_at: "2026-11-17T08:00:00Z" }
    }, headers: auth, as: :json
    assert_response :created
    assert_equal [ "made soup", "misha ate a sock" ], body["diary"].map { |d| d["entry"] }
    assert_equal "kitchen", body["diary"].first["lane"]
    assert_equal "soup", body["mood"]["obsession"]
    assert_equal 0.4, body["mood"]["manifestation"]
    assert_equal [ "read it", "worse" ], body["chew"]["notes"].map { |n| n["note"] }
    assert_equal "2026-11-17T08:00:00Z", body["chew"]["moved_at"]

    post "/v1/personas/mel/life/import", params: { diary: [ { entry: "again" } ] }, headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/already has a diary/, body["error"])

    get "/v1/personas/mel/life", headers: auth
    assert_response :ok
    assert_equal 2, body["diary"].size
  end

  test "a chew moves from a conversation" do
    post "/v1/personas/mel/life/chew", params: { move: "pick_up", subject: "kerbal docking", note: "it wobbles" },
                                       headers: auth, as: :json
    assert_response :ok
    assert_equal "kerbal docking", body["chew"]["subject"]

    post "/v1/personas/mel/life/chew", params: { move: "spit_out" }, headers: auth, as: :json
    assert_nil body["chew"]
    post "/v1/personas/mel/life/chew", params: { move: "chew", note: "x" }, headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  test "a key below the life's realm reads none of it and writes none of it" do
    Clearance.with("personal") { PersonaLife.new(@mel).write_diary!("private beat") }
    token = ApiKey.issue!(principal: @principal, surface: "low", default_clearance: "household")
    get "/v1/personas/mel/life", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :ok
    assert_empty body["diary"]
    post "/v1/personas/mel/life/chew", params: { move: "pick_up", subject: "x" },
                                       headers: { "Authorization" => "Bearer #{token}" }, as: :json
    assert_response :unprocessable_entity
  end

  test "a persona push carries the life but keeps her home" do
    @mel.update!(life: @mel.life.merge("home" => "conv-1"))
    patch "/v1/personas/mel", params: { life: { instruction: "new beats", dial: "daily", home: "elsewhere",
                                                beats: { kitchen: [ "cook" ] }, odds: { "0-5": 0.3 } } },
                              headers: auth, as: :json
    assert_response :ok
    life = @mel.reload.life
    assert_equal "new beats", life["instruction"]
    assert_equal "daily", life["dial"]
    assert_equal "conv-1", life["home"]
    assert_equal({ "kitchen" => [ "cook" ] }, life["beats"])
    assert_equal({ "0-5" => 0.3 }, life["odds"])
  end
end
