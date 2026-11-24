require "test_helper"

# The voice plane: audio by role, kept by what was asked, and metered.
class VoiceTest < ActiveSupport::TestCase
  setup { @voice = voice! }

  LINES = [ { "voice_id" => "v-a", "text" => "[laughs] No." }, { "voice_id" => "v-b", "text" => "Yes, actually." } ].freeze

  test "a take is asked for once, kept, and written to the ledger" do
    ModelPrice.create!(model: "eleven_v4", input: 100, output: 0, cache_read: 0, cache_write: 0)

    clip = Voice.dialogue(LINES, realm: "personal", ref: "cast_episode/1")
    assert_equal "dialogue", clip.kind
    assert_equal clip.bytes.bytesize, clip.size
    assert_equal clip.key, Voice.dialogue(LINES, realm: "personal").key
    assert_equal [ "/v1/text-to-dialogue" ], @voice.paths, "the second ask is the kept clip"

    call = @voice.calls.sole
    assert_equal "xi-test", call.headers["xi-api-key"]
    assert_equal "eleven_v4", call.json["model_id"]
    assert_equal [ { "text" => "[laughs] No.", "voice_id" => "v-a" }, { "text" => "Yes, actually.", "voice_id" => "v-b" } ], call.json["inputs"]
    assert_includes call.url, "output_format=mp3_44100_128"

    event = UsageEvent.where(operation: "voice.dialogue").sole
    assert_equal "success", event.status
    assert_equal "voice-dialogue", event.role
    assert_equal "elevenlabs", event.provider
    assert_equal 26, event.units["characters"]
    assert_in_delta 0.0026, event.cost.to_f, 1e-9, "a voice model's input price is per million characters"
    assert_equal "cast_episode/1", event.ref
    assert_equal "personal", event.realm
  end

  test "different words, voices, or realms are different clips" do
    first = Voice.dialogue(LINES, realm: "personal")
    other_voice = Voice.dialogue([ LINES[0].merge("voice_id" => "v-c"), LINES[1] ], realm: "personal")
    other_realm = Voice.dialogue(LINES, realm: "intimate")

    assert_not_equal first.key, other_voice.key
    assert_equal first.key, other_realm.key
    assert_equal 3, @voice.calls.size
    assert_equal 3, AudioClip.count
  end

  test "an unpriced voice model costs null, not nothing" do
    Voice.sound("a marimba flourish", seconds: 2.5, realm: "personal")
    event = UsageEvent.where(operation: "voice.sound").sole
    assert_nil event.cost
    assert_equal({ "characters" => 18, "seconds" => 2.5 }, event.units)
    assert_equal 2.5, @voice.calls.sole.json["duration_seconds"]
  end

  test "music is asked for in milliseconds, instrumental" do
    Voice.music("a jazzy theme", seconds: 40, realm: "personal")
    body = @voice.calls.sole.json
    assert_equal 40_000, body["music_length_ms"]
    assert_equal true, body["force_instrumental"]
    assert_equal "music_v1", body["model_id"]
  end

  test "a busy provider is tried again, and a refusal is metered and raised" do
    @voice.respond(429, "").respond(503, "")
    assert Voice.dialogue(LINES, realm: "personal")
    assert_equal 3, @voice.calls.size

    @voice.respond(422, JSON.generate(detail: { status: "voice_not_found", message: "A voice with that id was not found." }))
    error = assert_raises(Voice::Error) { Voice.dialogue([ { "voice_id" => "gone", "text" => "Hello." } ], realm: "personal") }
    assert_match(/422: A voice with that id was not found/, error.message)
    failed = UsageEvent.where(operation: "voice.dialogue", status: "error").sole
    assert_match(/not found/, failed.error)
    assert_equal 1, AudioClip.count, "nothing is kept for a call that failed"
  end

  test "what cannot be voiced is refused before anything is spent" do
    assert_raises(Voice::Invalid) { Voice.dialogue([], realm: "personal") }
    assert_raises(Voice::Invalid) { Voice.dialogue([ { "voice_id" => "", "text" => "Hello." } ], realm: "personal") }
    assert_raises(Voice::Invalid) { Voice.dialogue([ { "voice_id" => "v", "text" => "x" * 2_001 } ], realm: "personal") }
    assert_empty @voice.calls
  end

  test "without the provider's key there is no voice" do
    ENV.delete("HOB_TEST_ELEVENLABS_KEY")
    assert_not Voice.available?
    error = assert_raises(Voice::NotConfigured) { Voice.dialogue(LINES, realm: "personal") }
    assert_match(/ELEVENLABS_API_KEY/, error.message)
  end

  test "a clip is seen only at its realm's clearance" do
    Voice.dialogue(LINES, realm: "intimate")
    clearance!("personal")
    assert_equal 0, AudioClip.count
  end
end
