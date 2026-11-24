require "test_helper"

# Casts over HTTP: a person makes a show, a surface hands it editions, and a
# podcast app reads the feed with nothing but the token in the address.
class CastsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup { @voice = voice! }

  # A surface with a principal of its own; one provisioned as a person
  # (hob:provision) holds that person's standing instead.
  def surface_key(clearance = "personal")
    principal = Principal.find_or_create_by!(name: "feedcurator") { |p| p.kind = "surface"; p.max_clearance = "personal" }
    ApiKey.issue!(principal: principal, surface: "feedcurator", default_clearance: clearance)
  end

  def ready_episode(cast, edition: "2026-11-24", bytes: "ID3" + "0123456789" * 10)
    clip = AudioClip.store!(realm: cast.realm, key: AudioClip.key_for("episode", edition), kind: "episode", bytes: bytes)
    cast.episodes.create!(edition: edition, title: "Rates & rovers", summary: "The Fed <holds>.", realm: cast.realm, status: "ready",
                          audio_key: clip.key, audio_size: clip.size, duration_ms: 483_000, published_at: Time.utc(2026, 11, 24, 14),
                          source: { "stories" => [ { "title" => "Fed holds", "sources" => [ { "url" => "https://wsj.com/x?a=1&b=2", "source" => "WSJ" } ] } ] })
  end

  test "a person makes a cast, changes it, and rotates its address" do
    post "/v1/casts", params: { slug: "briefing", title: "The Morning Hob", realm: "personal", config: { minutes: 6 } }, headers: auth, as: :json
    assert_response :created
    assert_equal 6, body["config"]["minutes"]
    assert_equal "dialogue", body["config"]["voicing"], "what a cast doesn't say is the default"
    assert_equal %w[Marlowe Pip], body["config"]["hosts"].map { |h| h["name"] }
    assert_equal true, body["voice"]
    feed = body["feed_url"]
    assert_match %r{\Ahttp://www.example.com/casts/[\w-]{20,}/feed\.xml\z}, feed

    post "/v1/casts", params: { slug: "briefing", title: "Hobcast", config: { voicing: "lines", minutes: nil } }, headers: auth, as: :json
    assert_response :ok
    assert_equal [ "Hobcast", "lines", 8, feed ], [ body["title"], body["config"]["voicing"], body["config"]["minutes"], body["feed_url"] ]

    patch "/v1/casts/briefing", params: { config: { voicing: "sung" } }, headers: auth, as: :json
    assert_response :unprocessable_entity

    patch "/v1/casts/briefing", params: { rotate_token: true }, headers: auth, as: :json
    assert_not_equal feed, body["feed_url"]
    get URI(feed).path
    assert_response :not_found

    post "/v1/casts", params: { slug: "secret", title: "S", realm: "intimate" }, headers: auth("X-Hob-Clearance" => "personal"), as: :json
    assert_response :unprocessable_entity, "a realm above the key's clearance"
  end

  test "a surface hands over an edition and polls it; it cannot make a cast or see the feed's address" do
    skip "ffmpeg is not installed" unless Casts::Mixer.available?
    cast!
    key = { "Authorization" => "Bearer #{surface_key}" }

    post "/v1/casts", params: { slug: "mine", title: "Mine" }, headers: key, as: :json
    assert_response :forbidden
    get "/v1/casts/briefing", headers: key
    assert_nil body["feed_url"]

    post "/v1/casts/briefing/episodes", params: { edition: "2026-11-24" }, headers: key, as: :json
    assert_response :unprocessable_entity
    assert_match(/briefing/, body["error"])

    @fake.reply(FakeVoice::SCRIPT.to_json)
    post "/v1/casts/briefing/episodes", headers: key, as: :json,
         params: { edition: "2026-11-24", title: "Morning briefing", briefing: "The Fed held.", stories: [ { title: "Fed holds", summary: "Held." } ] }
    assert_response :accepted
    assert_equal "queued", body["status"]
    id = body["id"]

    post "/v1/casts/briefing/episodes", params: { edition: "2026-11-24", briefing: "The Fed held." }, headers: key, as: :json
    assert_response :ok, "the same edition again is left alone"
    assert_equal id, body["id"]

    perform_enqueued_jobs
    get "/v1/casts/briefing/episodes/#{id}?script=1", headers: key
    assert_equal "ready", body["status"]
    assert_equal "Rates", body["script"]["segments"][0]["headline"]
    assert_equal "feedcurator", UsageEvent.find_by(operation: "voice.dialogue").surface

    get "/v1/casts/briefing/episodes", headers: key
    assert_equal [ id ], body.map { |e| e["id"] }
    assert_nil body[0]["script"]

    post "/v1/casts/briefing/episodes/#{id}/retry", headers: key
    assert_response :forbidden
    post "/v1/casts/missing/episodes", params: { edition: "x", briefing: "y" }, headers: key, as: :json
    assert_response :not_found
  end

  test "a cast above a key's clearance is not there, and agents are turned away" do
    cast!("pillow", realm: "intimate")
    post "/v1/casts/pillow/episodes", params: { edition: "x", briefing: "y" }, headers: { "Authorization" => "Bearer #{surface_key}" }, as: :json
    assert_response :not_found

    _, token = agent
    get "/v1/casts", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :forbidden
  end

  test "the feed lists finished episodes with their audio and show notes" do
    cast = cast!
    episode = ready_episode(cast)
    cast.episodes.create!(edition: "2026-11-25", title: "Unfinished", realm: cast.realm, status: "voicing")

    get "/casts/#{cast.token}/feed.xml"
    assert_response :ok
    assert_match "xml", response.media_type
    feed = Nokogiri::XML(response.body) { |config| config.strict }
    assert_equal "The Morning Hob", feed.at_xpath("/rss/channel/title").text
    assert_equal "Yes", feed.at_xpath("/rss/channel/itunes:block").text
    item = feed.xpath("/rss/channel/item").sole
    assert_equal "Rates & rovers", item.at_xpath("title").text
    assert_equal episode.id, item.at_xpath("guid").text
    assert_equal "483", item.at_xpath("itunes:duration").text
    enclosure = item.at_xpath("enclosure")
    assert_equal "http://www.example.com/casts/#{cast.token}/episodes/#{episode.id}.mp3", enclosure["url"]
    assert_equal [ episode.audio_size.to_s, "audio/mpeg" ], [ enclosure["length"], enclosure["type"] ]
    notes = item.at_xpath("content:encoded").text
    assert_includes notes, "<p>The Fed &lt;holds&gt;.</p>"
    assert_includes notes, %(<strong>Fed holds</strong> (<a href="https://wsj.com/x?a=1&amp;b=2">WSJ</a>))
  end

  test "an episode's audio is served whole, in ranges, and not again when unchanged" do
    cast = cast!
    episode = ready_episode(cast)
    path = "/casts/#{cast.token}/episodes/#{episode.id}.mp3"
    bytes = episode.audio.bytes

    get path
    assert_response :ok
    assert_equal "audio/mpeg", response.media_type
    assert_equal bytes, response.body.b
    assert_equal "bytes", response.headers["Accept-Ranges"]
    etag = response.headers["ETag"]

    get path, headers: { "Range" => "bytes=3-12" }
    assert_response :partial_content
    assert_equal "0123456789", response.body
    assert_equal "bytes 3-12/#{bytes.bytesize}", response.headers["Content-Range"]

    get path, headers: { "Range" => "bytes=100-" }
    assert_equal bytes.byteslice(100..), response.body.b
    get path, headers: { "Range" => "bytes=-5" }
    assert_equal "bytes #{bytes.bytesize - 5}-#{bytes.bytesize - 1}/#{bytes.bytesize}", response.headers["Content-Range"]
    get path, headers: { "Range" => "bytes=5000-" }
    assert_response :range_not_satisfiable

    get path, headers: { "If-None-Match" => etag }
    assert_response :not_modified
  end

  test "the token opens one cast and nothing else" do
    cast = cast!
    other = cast!("evening")
    episode = ready_episode(other)

    get "/casts/nope/feed.xml"
    assert_response :not_found
    get "/casts/#{'x' * 32}/feed.xml"
    assert_response :not_found
    get "/casts/#{cast.token}/episodes/#{episode.id}.mp3"
    assert_response :not_found, "another cast's episode"
    get "/casts/#{cast.token}/episodes/missing.mp3"
    assert_response :not_found
  end

  test "an intimate cast's feed is served by its token alone" do
    cast = cast!("pillow", realm: "intimate")
    ready_episode(cast)
    get "/casts/#{cast.token}/feed.xml"
    assert_response :ok
    assert_equal 1, Nokogiri::XML(response.body).xpath("//item").size
  end
end
