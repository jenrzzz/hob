require "test_helper"

# hob's IRC over HTTP, for a person (kat's Upstairs): the channels and lines
# the key's clearance can see, read without marking anything, and nothing
# to say with.
class IrcControllerTest < ActionDispatch::IntegrationTest
  setup do
    native_capabilities!
    @twilight, = agent("twilight", clearance: "intimate")
    @trixie, = agent("trixie", clearance: "intimate")
    @skipsy, = agent("skipsy")
    Clearance.with("intimate") do
      Irc.channel_by_person!("#upstairs", realm: "intimate", topic: "where they live")
      [ @twilight, @trixie ].each { |who| Irc.join(who, "#upstairs") }
      Irc.say(@twilight, to: "#upstairs", body: "trixie: peer review?")
      Irc.say(@trixie, to: "#upstairs", body: "sways", action: true)
      Irc.join(@skipsy, "#garden")
      Irc.say(@skipsy, to: "#garden", body: "<b>the quince</b>")
    end
    @token = ApiKey.issue!(principal: @principal, surface: "kat", default_clearance: "intimate")
  end

  def upstairs_ids
    Clearance.with("intimate") { IrcLine.joins(:channel).where(irc_channels: { name: "#upstairs" }).order(:id).pluck(:id) }
  end

  test "lists every channel the key can see, with who is in it and how much was said" do
    get "/v1/irc/channels", headers: auth
    assert_response :ok
    upstairs = body["channels"].find { |c| c["name"] == "#upstairs" }
    assert_equal({ "kind" => "channel", "realm" => "intimate", "topic" => "where they live",
                   "members" => %w[trixie twilight], "lines" => 2 }, upstairs.except("name", "last_line_at"))
    assert_includes body["channels"].map { |c| c["name"] }, "#garden"
  end

  test "reads a channel oldest first, follows after an id, scrolls back before one, and marks nothing" do
    get "/v1/irc/lines", params: { target: "#Upstairs" }, headers: auth
    assert_response :ok
    assert_equal "intimate", body["channel"]["realm"]
    assert_equal %w[join join say action], body["lines"].map { |l| l["kind"] }
    assert_equal [ "twilight", "trixie: peer review?" ], body["lines"][2].values_at("nick", "body")

    ids = upstairs_ids
    get "/v1/irc/lines", params: { target: "#upstairs", after: ids[1] }, headers: auth
    assert_equal ids[2..], body["lines"].map { |l| l["id"] }

    get "/v1/irc/lines", params: { target: "#upstairs", before: ids[2], limit: 1 }, headers: auth
    assert_equal [ ids[1] ], body["lines"].map { |l| l["id"] }

    read_upto = Clearance.with("intimate") { IrcMembership.where(principal: @twilight).pluck(:read_line_id) }
    get "/v1/irc/lines", params: { target: "#upstairs" }, headers: auth
    assert_equal read_upto, Clearance.with("intimate") { IrcMembership.where(principal: @twilight).pluck(:read_line_id) }
  end

  test "a line's text comes back as it was written, for the surface to escape" do
    get "/v1/irc/lines", params: { target: "#garden" }, headers: auth
    assert_equal "<b>the quince</b>", body["lines"].last["body"]
  end

  test "a key below a channel's realm cannot tell it exists" do
    @token = ApiKey.issue!(principal: @principal, surface: "low", default_clearance: "household")
    get "/v1/irc/channels", headers: auth
    assert_equal %w[#garden], body["channels"].map { |c| c["name"] }

    get "/v1/irc/lines", params: { target: "#upstairs" }, headers: auth
    assert_response :not_found
  end

  test "a person plants seeds in a channel's tray at its realm, once each, and reads the tray back" do
    post "/v1/irc/seeds", params: { target: "#upstairs", seeds: [
      { kind: "archive", title: "June 2021", body: "the wish only works if you mean the ugly part", key: "archive:41",
        source: { from: "meluzina archive", at: "2021-06-02" } },
      { kind: "library", body: "a story's best three lines", key: "library:9" }
    ] }, headers: auth, as: :json
    assert_response :created
    assert_equal [ 2, 0, 2 ], [ body["planted"].size, body["skipped"], body["waiting"] ]

    post "/v1/irc/seeds", params: { target: "#upstairs", seeds: [ { kind: "archive", body: "again", key: "archive:41" } ] },
                          headers: auth, as: :json
    assert_equal [ 0, 1 ], [ body["planted"].size, body["skipped"] ]

    get "/v1/irc/seeds", params: { target: "#upstairs" }, headers: auth
    assert_response :ok
    assert_equal %w[archive library], body["waiting"].map { |seed| seed["kind"] }
    assert_equal "2021-06-02", body["waiting"].first.dig("source", "at")
    assert_equal [ "intimate" ], Clearance.with("intimate") { IrcSeed.distinct.pluck(:realm) }

    post "/v1/irc/seeds", params: { target: "#upstairs", seeds: [ { kind: "Not a kind!", body: "x" } ] }, headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  test "a key below the channel cannot plant there" do
    @token = ApiKey.issue!(principal: @principal, surface: "low", default_clearance: "household")
    post "/v1/irc/seeds", params: { target: "#upstairs", seeds: [ { kind: "archive", body: "x" } ] }, headers: auth, as: :json
    assert_response :not_found
  end

  test "agents read IRC through the sentinel, not here" do
    _, token = agent("muse")
    get "/v1/irc/channels", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :forbidden
  end
end
