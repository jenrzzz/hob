require "test_helper"

# ffmpeg, for real: takes trimmed to their voices, and a timeline made one mp3.
class CastsMixerTest < ActiveSupport::TestCase
  setup do
    skip "ffmpeg is not installed" unless Casts::Mixer.available?
    @dir = Dir.mktmpdir("mixer-test")
  end

  teardown { FileUtils.rm_rf(@dir) if @dir }

  def file(name, bytes) = File.join(@dir, name).tap { |path| File.binwrite(path, bytes) }

  # Mean volume in dB over a stretch of a file.
  def level(path, from, to)
    _out, err, = Open3.capture3("ffmpeg", "-v", "info", "-ss", from.to_s, "-to", to.to_s, "-i", path, "-af", "volumedetect", "-f", "null", "-")
    err[/mean_volume: (-?[\d.]+|-inf) dB/, 1].then { |v| v == "-inf" ? -120.0 : v.to_f }
  end

  test "a take is trimmed to where its voice starts and stops" do
    raw = file("take.mp3", FakeVoice.tone(2.0, quiet: 0.5))
    assert_in_delta 3.0, Casts::Mixer.probe(raw), 0.1

    trimmed = Casts::Mixer.voice!(raw, File.join(@dir, "take.wav"))
    assert_in_delta 2.0 + 0.03 + 0.09, Casts::Mixer.probe(trimmed), 0.08
  end

  test "a take of nothing but quiet is kept whole" do
    quiet, = Open3.capture3("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:d=1", "-f", "mp3", "-", binmode: true)
    trimmed = Casts::Mixer.voice!(file("quiet.mp3", quiet), File.join(@dir, "quiet.wav"))
    assert_in_delta 1.0, Casts::Mixer.probe(trimmed), 0.1
  end

  test "an envelope is straight lines between its points, the last gain held" do
    expression = Casts::Mixer.gain([ [ 0, 0.8 ], [ 2, 0.8 ], [ 4, 0.2 ], [ 3, 0.0 ] ])
    assert_equal "if(lt(t,2.0000),0.8000+0.0000*(t-0.0000)/2.0000,if(lt(t,4.0000),0.8000+-0.6000*(t-2.0000)/2.0000," \
                 "if(lt(t,4.0000),0.0000,0.0000)))", expression
    assert_equal "1.0000", Casts::Mixer.gain([ [ 0, 1.0 ] ])
  end

  test "a timeline is rendered to one mp3: voices where they belong, the bed ducked under them" do
    voice = Casts::Mixer.voice!(file("v.mp3", FakeVoice.tone(3.0)), File.join(@dir, "v.wav"))
    theme = file("theme.mp3", FakeVoice.tone(12.0, quiet: 0.0, hz: 220))
    placements = [
      { path: theme, bus: :bed, at: 0.0, offset: 0.0, length: 10.0,
        envelope: [ [ 0.0, 0.8 ], [ 3.0, 0.8 ], [ 4.0, 0.1 ], [ 8.0, 0.1 ], [ 10.0, 0.0 ] ] },
      { path: voice, bus: :voice, at: 12.0, offset: 0.0, length: Casts::Mixer.probe(voice), envelope: [ [ 0.0, 1.0 ] ] }
    ]
    out = Casts::Mixer.render!(placements, File.join(@dir, "out.mp3"), duration: 16.0, tags: { title: "A test", album: "The Show" })

    assert_in_delta 16.0, Casts::Mixer.probe(out), 0.15
    assert File.binread(out, 3).in?([ "ID3", "\xFF\xFB".b, "\xFF\xF3".b ]), "an mp3"
    full, ducked, silent, spoken = level(out, 0.5, 2.5), level(out, 5, 7), level(out, 10.5, 11.5), level(out, 12.5, 14.5)
    assert_operator full - ducked, :>, 10, "the theme drops under where speech would be (#{full} → #{ducked})"
    assert_operator silent, :<, -60, "and is gone after its fade (#{silent})"
    assert_operator spoken, :>, -30, "the voice is there at its moment (#{spoken})"
    tags, = Open3.capture3("ffprobe", "-v", "error", "-show_entries", "format_tags=title,album", "-of", "csv=p=0", out)
    assert_equal "A test,The Show", tags.strip.split(",").sort.join(",")
  end

  test "ffmpeg's complaint is the error" do
    error = assert_raises(Casts::Mixer::Failed) { Casts::Mixer.probe(File.join(@dir, "missing.mp3")) }
    assert_match(/ffprobe failed/, error.message)
  end
end
