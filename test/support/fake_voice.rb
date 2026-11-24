require "open3"

# ElevenLabs as far as hob uses it: what Voice::ElevenLabs.transport is
# pointed at in tests. Every call is kept; each answers with real audio (a
# tone with quiet either side, made once by ffmpeg, as long as the request
# suggests) so the mixer downstream has something true to work on. Without
# ffmpeg it answers with bytes that only look like an mp3. A response
# pushed with `respond` is served first.
class FakeVoice
  Call = Struct.new(:verb, :url, :body, :headers) do
    def path = URI(url).path
    def json = JSON.parse(body)
  end

  # An episode as the writer would hand it back: a cold open, two segments
  # (the first with a beat, so it is two takes), a sign-off.
  SCRIPT = {
    "title" => "The Fed holds, and a moon rover naps",
    "summary" => "Rates stay put. A rover goes quiet on purpose.",
    "cold_open" => [ { "speaker" => "a", "text" => "[deadpan] They parked a rover and told it to sleep." },
                     { "speaker" => "b", "text" => "On PURPOSE?" } ],
    "segments" => [
      { "headline" => "Rates", "lines" => [ { "speaker" => "b", "text" => "Welcome to the Morning Hob. It's Tuesday." },
                                            { "speaker" => "a", "text" => "The Fed held, [sighs] again.", "beat" => true },
                                            { "speaker" => "b", "text" => "According to [the Journal](https://wsj.com/x), nobody blinked." } ] },
      { "headline" => "Rover", "lines" => [ { "speaker" => "a", "text" => "So. The rover." },
                                            { "speaker" => "b", "text" => "[laughs] The NAP." } ] }
    ],
    "sign_off" => [ { "speaker" => "a", "text" => "That's the show." }, { "speaker" => "b", "text" => "Sleep well, rover." } ]
  }.freeze

  attr_reader :calls

  def self.ffmpeg?
    @ffmpeg = system("ffmpeg", "-version", out: File::NULL, err: File::NULL) if @ffmpeg.nil?
    @ffmpeg
  end

  # A tone of `seconds` with `quiet` seconds of silence before and after.
  def self.tone(seconds, quiet: 0.4, hz: 330)
    @tones ||= {}
    @tones[[ seconds, quiet, hz ]] ||= begin
      return "ID3fake-mp3-#{seconds}".b unless ffmpeg?

      filter = "sine=frequency=#{hz}:duration=#{seconds},volume=0.5,adelay=#{(quiet * 1000).round}:all=1,apad=pad_dur=#{quiet}"
      out, _err, status = Open3.capture3("ffmpeg", "-v", "error", "-f", "lavfi", "-i", filter, "-ac", "2", "-ar", "44100",
                                         "-f", "mp3", "-", binmode: true)
      raise "ffmpeg could not make a test tone" unless status.success?

      out
    end
  end

  def initialize
    @calls = []
    @queued = []
  end

  def respond(status, body = "")
    @queued << [ status, body ]
    self
  end

  def to_proc
    method(:call).to_proc
  end

  def call(verb, url, body, headers)
    call = Call.new(verb, url, body, headers)
    @calls << call
    return @queued.shift if @queued.any?

    json = call.json
    case call.path
    when "/v1/text-to-dialogue" then [ 200, self.class.tone([ json["inputs"].sum { |i| i["text"].length } / 200.0, 0.6 ].max.round(1)) ]
    when "/v1/sound-generation" then [ 200, self.class.tone(json["duration_seconds"] || 2.0, quiet: 0.0, hz: 880) ]
    when "/v1/music" then [ 200, self.class.tone(json["music_length_ms"] / 1000.0, quiet: 0.0, hz: 220) ]
    else [ 404, JSON.generate(detail: "no such endpoint") ]
    end
  end

  def paths
    calls.map(&:path)
  end
end
