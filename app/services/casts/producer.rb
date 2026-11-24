module Casts
  # One episode, start to finish: write it, voice it, dress it, mix it,
  # keep it. Every step that costs money is cached by what it asked for
  # (the script on the episode, each take and sound in AudioClip), so a run
  # that died halfway picks up where the money stopped.
  #
  # Runs at the episode's realm (CastEpisodeJob sets it). Dressing is
  # optional by construction: a theme or a sting that can't be made is
  # noted on the episode and the show goes out without it.
  class Producer
    def self.call(episode)
      new(episode).call
    end

    def initialize(episode)
      @episode = episode
      @cast = episode.cast
      @notes = []
    end

    def call
      script = write
      takes = voice(script)
      theme, stingers = dress
      mix(script, takes, theme, stingers)
      Casts.prune!(@cast)
      @episode
    rescue StandardError => e
      @episode.update!(status: "failed", error: "#{e.class.name.demodulize}: #{e.message}".truncate(1_000),
                       production: @episode.production.merge("notes" => @notes))
      raise
    end

    private

    def ref
      "cast_episode/#{@episode.id}"
    end

    def write
      return @episode.script if @episode.script["segments"].present?

      @episode.update!(status: "writing")
      script = Script.write(@episode)
      @episode.update!(script: script, title: script["title"] || @episode.title, summary: script["summary"])
      script
    end

    # -> [{ "kind", "takes" => [{ clip: AudioClip, first:, last:, beat: }] }]
    def voice(script)
      @episode.update!(status: "voicing")
      Script.parts(script).map do |part|
        takes = Script.takes(part["lines"], @cast).map do |take|
          clip = Voice.dialogue(take["lines"], realm: @episode.realm, ref: ref, language: @cast.setting(:language))
          { clip: clip, first: take["first"], last: take["last"], beat: take["beat"] == true }
        end
        { "kind" => part["kind"], "takes" => takes }
      end
    end

    # The theme and the stingers: made once for the show, found again by
    # their descriptions ever after.
    def dress
      theme = dressing("theme") do
        @cast.setting(:theme).presence &&
          Voice.music(@cast.setting(:theme), seconds: @cast.setting(:theme_seconds), realm: @episode.realm, ref: ref)
      end
      stingers = Array(@cast.setting(:stingers)).each_with_index.filter_map do |prompt, i|
        dressing("stinger #{i + 1}") do
          Voice.sound(prompt, seconds: @cast.setting(:stinger_seconds), realm: @episode.realm, ref: ref)
        end
      end
      [ theme, stingers ]
    end

    def dressing(what)
      yield
    rescue Voice::Error, Gateway::Error => e
      @notes << "no #{what}: #{e.message.truncate(200)}"
      nil
    end

    def mix(script, parts, theme, stingers)
      @episode.update!(status: "mixing")
      Dir.mktmpdir("cast-#{@episode.id}") do |dir|
        parts.each_with_index do |part, p|
          part["takes"].each_with_index do |take, t|
            raw = write_clip(dir, "take-#{p}-#{t}.mp3", take[:clip])
            take[:path] = Mixer.voice!(raw, File.join(dir, "take-#{p}-#{t}.wav"))
            take[:duration] = Mixer.probe(take[:path])
            take[:clip] = take[:path]
          end
        end
        theme = theme && sized(write_clip(dir, "theme.mp3", theme))
        stingers = stingers.each_with_index.map { |s, i| sized(write_clip(dir, "sting-#{i}.mp3", s)) }

        timeline = Timeline.new(parts: parts, theme: theme, stingers: stingers, pacer: Pacer.new(@episode.id)).call
        placements = timeline[:placements].map { |placement| placement.merge(path: placement[:clip]) }
        out = File.join(dir, "episode.mp3")
        Mixer.render!(placements, out, duration: timeline[:duration],
                                       tags: { title: @episode.title, artist: @cast.setting(:author), album: @cast.title,
                                               genre: "Podcast", comment: @episode.summary })
        keep!(File.binread(out), Mixer.probe(out), script, placements)
      end
    end

    def write_clip(dir, name, clip)
      File.join(dir, name).tap { |path| File.binwrite(path, clip.bytes) }
    end

    def sized(path)
      { clip: path, duration: Mixer.probe(path) }
    end

    def keep!(bytes, seconds, script, placements)
      previous = @episode.audio_key
      key = AudioClip.key_for("episode", @episode.id, Digest::SHA256.hexdigest(bytes))
      AudioClip.store!(realm: @episode.realm, key: key, kind: "episode", bytes: bytes,
                       meta: { "cast" => @cast.slug, "edition" => @episode.edition })
      @episode.update!(
        status: "ready", error: nil, audio_key: key, audio_size: bytes.bytesize, duration_ms: (seconds * 1000).round,
        published_at: @episode.published_at || Time.current,
        production: { "characters" => Script.characters(script), "takes" => placements.count { |p| p[:bus] == :voice },
                      "voicing" => @cast.setting(:voicing), "notes" => @notes.presence,
                      "dropped_segments" => script["dropped_segments"] }.compact
      )
      AudioClip.where(realm: @episode.realm, key: previous).delete_all if previous && previous != key
    end
  end
end
