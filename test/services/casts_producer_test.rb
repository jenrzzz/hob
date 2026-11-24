require "test_helper"

# One episode, start to finish, against a scripted writer and a fake voice.
class CastsProducerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  SCRIPT = FakeVoice::SCRIPT

  setup do
    skip "ffmpeg is not installed" unless Casts::Mixer.available?
    @voice = voice!
    @cast = cast!
  end

  def submit(**more)
    Casts.submit!(@cast, edition: "2026-11-24", title: "Morning briefing", briefing: "The Fed held rates. A rover slept.",
                         stories: [ { "title" => "Fed holds", "summary" => "Held.", "junk" => 1,
                                      "sources" => [ { "title" => "Fed holds", "url" => "https://wsj.com/x", "source" => "WSJ" },
                                                     { "title" => "bad", "url" => "javascript:alert(1)" } ] } ], **more)
  end

  test "a briefing becomes a written, voiced, dressed and mixed episode" do
    @fake.reply(SCRIPT.to_json)
    episode, started = submit
    assert started
    assert_equal "queued", episode.status
    assert_equal [ { "title" => "Fed holds", "url" => "https://wsj.com/x", "source" => "WSJ" } ], episode.stories.sole["sources"]

    perform_enqueued_jobs
    episode.reload
    assert_equal "ready", episode.status, episode.error
    assert_equal "The Fed holds, and a moon rover naps", episode.title
    assert_equal "Rates stay put. A rover goes quiet on purpose.", episode.summary
    assert_equal "According to the Journal, nobody blinked.", episode.script["segments"][0]["lines"][2]["text"]

    # Cold open, two takes for the first segment (it has a beat), the second segment, the sign-off.
    dialogue = @voice.calls.select { |c| c.path == "/v1/text-to-dialogue" }
    assert_equal 5, dialogue.size
    assert_equal %w[JBFqnCBsd6RMkjVDRZzb EXAVITQu4vr4xnSDxMaL], dialogue.first.json["inputs"].map { |i| i["voice_id"] }
    assert_equal "[deadpan] They parked a rover and told it to sleep.", dialogue.first.json["inputs"][0]["text"]
    assert_equal 1, @voice.paths.count("/v1/music")
    assert_equal 3, @voice.paths.count("/v1/sound-generation")

    clip = episode.audio
    assert_equal "episode", clip.kind
    assert_equal episode.audio_size, clip.size
    assert_operator episode.duration_ms, :>, 15_000, "voices plus a theme in and out"
    assert_equal 5, episode.production["takes"]
    assert_equal Casts::Script.characters(episode.script), episode.production["characters"]
    assert episode.published_at

    writer = @fake.calls.sole
    assert_match(/Marlowe/, writer.system)
    assert_match(/The Fed held rates/, writer.messages.last["content"])
    assert_equal "cast.script", UsageEvent.find_by(role: "cast-writer").operation
    assert_equal [ "cast_episode/#{episode.id}" ], UsageEvent.where("operation LIKE 'voice.%'").distinct.pluck(:ref)
  end

  test "the same edition is not made twice, unless forced" do
    @fake.reply(SCRIPT.to_json)
    episode, = submit
    again, started = submit
    assert_not started, "one being made is left alone"
    perform_enqueued_jobs
    calls = @voice.calls.size

    again, started = submit
    assert_not started
    assert_equal episode.id, again.id
    assert_no_enqueued_jobs

    @fake.reply(SCRIPT.to_json)
    _, started = submit(force: true)
    assert started
    perform_enqueued_jobs
    assert_equal "ready", episode.reload.status
    assert_equal calls, @voice.calls.size, "the same script costs nothing to voice again"
    assert_equal 1, AudioClip.where(kind: "episode").count
  end

  test "a failure is left on the episode, and a retry pays only for what is missing" do
    @fake.reply(SCRIPT.to_json)
    3.times { @voice.respond(500, "") }
    episode, = submit
    perform_enqueued_jobs
    assert_equal "failed", episode.reload.status
    assert_match(/ElevenLabs answered 500/, episode.error)
    assert episode.script["segments"].present?, "the script is kept"

    Casts.retry!(episode)
    perform_enqueued_jobs
    assert_equal "ready", episode.reload.status
    assert_nil episode.error
    assert_equal 1, @fake.calls.size, "and is not written again"
  end

  test "the show goes out without dressing that cannot be made" do
    ModelRole.find_by(role: "voice-music").update!(chain: [ { "provider" => "offline", "model" => "music_v1" } ])
    @cast.update!(config: { "stingers" => [] })
    @fake.reply(SCRIPT.to_json)
    episode, = submit
    perform_enqueued_jobs
    assert_equal "ready", episode.reload.status
    assert_match(/no theme/, episode.production["notes"].sole)
  end

  test "a writer's refusal fails the episode" do
    @fake.refuse
    episode, = submit
    perform_enqueued_jobs
    assert_equal "failed", episode.reload.status
    assert_empty @voice.calls
  end

  test "episodes past the show's keep are pruned with their audio" do
    @cast.update!(config: { "keep" => 1 })
    %w[2026-11-23 2026-11-24].each do |edition|
      @fake.reply(SCRIPT.to_json)
      Casts.submit!(@cast, edition: edition, title: edition, briefing: "News.")
      perform_enqueued_jobs
    end
    assert_equal %w[2026-11-24], @cast.episodes.pluck(:edition)
    assert_equal 1, AudioClip.where(kind: "episode").count
  end
end
