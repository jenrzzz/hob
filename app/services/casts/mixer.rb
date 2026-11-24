require "open3"

module Casts
  # ffmpeg, making one mp3 of a timeline. Three jobs:
  #
  #   voice!   a take trimmed to where the voices start and stop. Every
  #            generated clip carries dead air at both ends; left in, the
  #            pacer's fifth of a second becomes most of a second. (kat's
  #            VoiceClip.voicedSpan, done once on the server.)
  #   probe    how long a file runs
  #   render!  every placement delayed to its moment at its gain, voices
  #            lightly compressed on a bus of their own, the whole levelled
  #            to podcast loudness
  module Mixer
    class Failed < Casts::Error; end

    RATE = 44_100
    BITRATE = "128k"
    # Below this a sample is room tone, not voice; and the slivers kept
    # either side so consonants and breaths aren't clipped.
    SILENCE = "-46dB"
    LEAD_PAD = 0.03
    TAIL_PAD = 0.09
    # Integrated loudness and true peak: what podcast apps expect.
    LOUDNESS = "loudnorm=I=-16:TP=-1.5:LRA=11"
    VOICE_BUS = "acompressor=threshold=-21dB:ratio=2.5:attack=8:release=160:makeup=1.5"
    TIMEOUT = 600

    module_function

    def available?
      @available = system("ffmpeg", "-version", out: File::NULL, err: File::NULL) if @available.nil?
      @available
    end

    def probe(path)
      out = run("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path.to_s)
      Float(out.strip)
    rescue ArgumentError
      raise Failed, "ffprobe could not read #{File.basename(path)}"
    end

    # -> out, a WAV of the take from its first voice to its last.
    def voice!(input, out)
      edge = "silenceremove=start_periods=1:start_threshold=#{SILENCE}:start_silence=%s:detection=peak"
      trim = [ format(edge, LEAD_PAD), "areverse", format(edge, TAIL_PAD), "areverse" ].join(",")
      run("ffmpeg", "-v", "error", "-y", "-i", input.to_s, "-af", "#{trim},aresample=#{RATE}", "-ac", "2", out.to_s)
      # A take that is nothing but quiet trims to nothing; keep it whole.
      voiced = begin
        probe(out)
      rescue Failed
        0.0
      end
      run("ffmpeg", "-v", "error", "-y", "-i", input.to_s, "-ar", RATE.to_s, "-ac", "2", out.to_s) if voiced < 0.05
      out
    end

    # placements: Timeline's, each with a :path. -> out
    def render!(placements, out, duration:, tags: {})
      raise Failed, "nothing to mix" if placements.empty?

      inputs = placements.flat_map { |p| [ "-i", p[:path].to_s ] }
      chains = placements.each_with_index.map do |p, i|
        "[#{i}:a]aformat=sample_fmts=fltp:sample_rates=#{RATE}:channel_layouts=stereo," \
          "atrim=start=#{f(p[:offset])}:end=#{f(p[:offset] + p[:length])},asetpts=PTS-STARTPTS," \
          "volume=volume='#{gain(p[:envelope])}':eval=frame," \
          "adelay=#{(p[:at] * 1000).round}:all=1[p#{i}]"
      end
      buses = %i[voice bed].filter_map do |bus|
        labels = placements.each_index.select { |i| placements[i][:bus] == bus }.map { |i| "[p#{i}]" }
        next if labels.empty?

        mixed = labels.size == 1 ? "#{labels.first}anull" : "#{labels.join}amix=inputs=#{labels.size}:normalize=0:dropout_transition=0"
        chains << "#{mixed}#{",#{VOICE_BUS}" if bus == :voice}[#{bus}]"
        "[#{bus}]"
      end
      master = buses.size == 1 ? "#{buses.first}anull" : "#{buses.join}amix=inputs=#{buses.size}:normalize=0:dropout_transition=0"
      chains << "#{master},apad,atrim=end=#{f(duration)},#{LOUDNESS}[out]"

      metadata = tags.compact.flat_map { |k, v| [ "-metadata", "#{k}=#{v.to_s.tr("\n", ' ')}" ] }
      run("ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", chains.join(";"), "-map", "[out]",
          "-ar", RATE.to_s, "-ac", "2", "-c:a", "libmp3lame", "-b:a", BITRATE, *metadata, out.to_s)
      out
    end

    # An envelope as an ffmpeg expression of t: straight lines between its
    # points, the last gain held. Points out of order are pulled into it.
    def gain(envelope)
      points = []
      envelope.each { |t, g| points << [ [ t.to_f, points.last&.first || 0.0 ].max, g.to_f.clamp(0.0, 4.0) ] }
      expression = f(points.last.last)
      points.each_cons(2).reverse_each do |(t0, g0), (t1, g1)|
        ramp = t1 > t0 ? "#{f(g0)}+#{f(g1 - g0)}*(t-#{f(t0)})/#{f(t1 - t0)}" : f(g1)
        expression = "if(lt(t,#{f(t1)}),#{ramp},#{expression})"
      end
      expression
    end

    def f(number)
      format("%.4f", number)
    end

    def run(*command)
      out, err, status = Timeout.timeout(TIMEOUT) { Open3.capture3(*command) }
      raise Failed, "#{command.first} failed: #{err.to_s.strip.lines.last(3).join(' ').truncate(400)}" unless status.success?

      out
    rescue Errno::ENOENT
      raise Failed, "#{command.first} is not installed"
    rescue Timeout::Error
      raise Failed, "#{command.first} took longer than #{TIMEOUT} seconds"
    end
  end
end
