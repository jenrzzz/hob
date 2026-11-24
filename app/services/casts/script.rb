module Casts
  # What the hosts say. One model call (role `cast-writer`) turns the
  # surface's briefing into a conversation; the rest is tidying: nothing
  # unsayable, nobody speaking who isn't a host, no more characters than the
  # show will pay for, and the lines cut into takes a voice model can do.
  #
  # The script, as kept on the episode:
  #   { "title", "summary",
  #     "cold_open" => [line], "segments" => [{ "headline", "lines" => [line] }], "sign_off" => [line] }
  #   line: { "speaker" => a host's key, "text" => what they say, "beat" => true when a silence follows }
  module Script
    WORDS_PER_MINUTE = 150
    # Room under Voice::DIALOGUE_MAX_CHARACTERS, where takes stay reliable.
    TAKE_CHARACTERS = 1_800
    PARTS = %w[cold_open segments sign_off].freeze

    module_function

    def schema(cast)
      line = { "type" => "object", "additionalProperties" => false, "required" => %w[speaker text],
               "properties" => {
                 "speaker" => { "type" => "string", "enum" => cast.hosts.map { |h| h["key"] } },
                 "text" => { "type" => "string", "description" => "What they say, as speech. Audio tags in square brackets are performed, not read." },
                 "beat" => { "type" => "boolean", "description" => "True when a real silence follows this line. Rare." }
               } }
      lines = { "type" => "array", "items" => line }
      { "type" => "object", "additionalProperties" => false, "required" => %w[title summary cold_open segments sign_off],
        "properties" => {
          "title" => { "type" => "string", "description" => "This episode's title: the top story or two, under 70 characters, no date." },
          "summary" => { "type" => "string", "description" => "Two sentences for the podcast app: what is in this episode." },
          "cold_open" => lines,
          "segments" => { "type" => "array", "items" => {
            "type" => "object", "additionalProperties" => false, "required" => %w[headline lines],
            "properties" => { "headline" => { "type" => "string" }, "lines" => lines }
          } },
          "sign_off" => lines
        } }
    end

    # Write the episode's script. -> the tidied script (a Hash).
    def write(episode)
      cast = episode.cast
      response = Gateway.complete(
        role: "cast-writer", system: system_prompt(cast), schema: schema(cast),
        messages: [ { "role" => "user", "content" => brief(episode) } ],
        operation: "cast.script", ref: "cast_episode/#{episode.id}", realm: episode.realm,
        metadata: { "cast" => cast.slug, "edition" => episode.edition }
      )
      raise Gateway::Refused, "the writer declined to write this episode" if response.refused?

      tidy(response.parsed, cast)
    end

    def system_prompt(cast)
      hosts = cast.hosts
      words = cast.setting(:minutes).to_i * WORDS_PER_MINUTE
      <<~PROMPT
        You write "#{cast.title}", a short daily audio show. #{cast.description}

        It is #{hosts.size == 1 ? 'one person' : "#{%w[zero one two three four][hosts.size]} people"} at a microphone, talking through the day's news for one listener#{cast.setting(:audience).present? ? " (#{cast.setting(:audience)})" : ''}. You are given a written briefing and the stories behind it. Rewrite it as what the hosts SAY. Nobody will read this; it will only ever be heard.

        THE HOSTS
        #{hosts.map { |h| "- #{h['key']}: #{h['name']}. #{h['character']}" }.join("\n")}

        SHAPE
        - cold_open: two to four quick lines before the theme music. No greeting, no show name: drop straight into the most arresting thing in today's news, mid-thought, and leave it hanging.
        - segments: one per story or cluster of related stories, most important first, four to seven in all. The FIRST segment opens with a short welcome that names the show and the day, then gets on with it. A sound plays between segments, so never write "moving on" or "next up": just start the next one, ideally with a hook.
        - sign_off: two to four lines. Quick, warm, a callback to something from earlier if there is a good one. Music comes up under it.
        - About #{words} words of speech in total. Cut stories before you cut the life out of the ones you keep.

        HOW THEY TALK
        - This is a conversation, not two people taking turns reading. They react to each other, interrupt, finish each other's thought, disagree and stay disagreed, get distracted by a good detail, make a joke and move on. One of them knows a thing and the other asks what the listener is wondering.
        - Vary the rhythm hard. Most lines are one or two sentences. Some are two words ("Wait, what?"). Now and then one of them runs for four or five sentences because they are onto something. Never alternate at an even length.
        - Have opinions. They may find something absurd, alarming, overhyped or quietly wonderful, in character. Keep takes clearly theirs and keep the facts straight.
        - No radio filler: no "great question", "absolutely", "that's fascinating", "let's dive in", "it remains to be seen", "only time will tell". No recapping what was just said.
        - Mark a `beat` only where a silence earns its place: after a punchline that should land, or before a hard turn into something grave. Twice an episode at most.

        WRITING FOR A VOICE
        - The voices perform audio tags in square brackets. Use them the way a director would, a few per segment: [laughs], [chuckles], [sighs], [exhales], [excited], [deadpan], [skeptical], [whispers], [groans], [gasps], [thoughtful]. Put the tag where the sound happens. A reaction can be a line by itself with a word or two ("[laughs] No.").
        - Ellipses for a trailing or hesitating thought, a dash for an interruption, CAPITALS on the one word that carries a sentence (sparingly).
        - Say numbers the way a person would: "about two and a half billion dollars", "a third", "nineteen eighty-four". Spell out symbols and abbreviations a voice would trip on. No URLs, no markdown, no lists, no parentheses, no "quote, unquote".
        - Name where something comes from in passing when it matters ("the Times has this"), never as a citation.

        WHAT IS TRUE
        - Every fact comes from the briefing and stories you are given. Do not add figures, names, dates, quotes or background they do not contain. If the material says a story has been running for weeks, treat it as known, not as news.
        - If today is thin, make a shorter show.
      PROMPT
    end

    def brief(episode)
      zone = ActiveSupport::TimeZone[ENV["HOB_TIME_ZONE"].to_s] || ActiveSupport::TimeZone["UTC"]
      stories = episode.stories.map { |s| s.slice("title", "category", "summary").merge("from" => Array(s["sources"]).filter_map { |x| x["source"] }.uniq.presence).compact }
      <<~BRIEF
        Today is #{zone.now.strftime('%A, %B %-d, %Y')}. This edition: #{episode.title}.

        THE BRIEFING, as it was written to be read:

        #{unlink(episode.source['briefing'].to_s)}

        THE STORIES behind it, best first:

        #{JSON.pretty_generate(stories)}
      BRIEF
    end

    # A model's script, made safe to voice: hosts only, speech only, and
    # within the show's budget (later segments go first; they matter least).
    def tidy(raw, cast)
      raw = raw.to_h
      keys = cast.hosts.map { |h| h["key"] }
      lines = ->(list) { Array(list).filter_map { |l| line(l, keys) } }
      script = {
        "title" => sayable(raw["title"]).truncate(120).presence,
        "summary" => sayable(raw["summary"]).truncate(600).presence,
        "cold_open" => lines.(raw["cold_open"]),
        "segments" => Array(raw["segments"]).filter_map do |segment|
          said = lines.(segment.to_h["lines"])
          { "headline" => sayable(segment.to_h["headline"]).truncate(200), "lines" => said } if said.any?
        end,
        "sign_off" => lines.(raw["sign_off"])
      }.compact
      raise Gateway::Refused, "the writer wrote an episode with nothing in it" if script["segments"].empty?

      budget = cast.setting(:max_characters).to_i
      dropped = 0
      while characters(script) > budget && script["segments"].size > 1
        script["segments"].pop
        dropped += 1
      end
      script["dropped_segments"] = dropped if dropped.positive?
      script
    end

    def line(raw, keys)
      raw = raw.to_h
      text = sayable(raw["text"])
      return nil if text.blank?

      { "speaker" => keys.include?(raw["speaker"]) ? raw["speaker"] : keys.first, "text" => text,
        "beat" => (true if raw["beat"] == true) }.compact
    end

    # Text a voice can say: links become their words, markup and addresses go.
    # Square-bracket tags stay; they are directions to the voice.
    def sayable(text)
      unlink(text.to_s).gsub(%r{https?://\S+}, "").gsub(/[*_`#]+/, "").gsub(/\s+/, " ").strip
    end

    def unlink(text)
      text.gsub(/\[([^\]]+)\]\((?:[^()]|\([^)]*\))*\)/, '\1')
    end

    def all_lines(script)
      Array(script["cold_open"]) + Array(script["segments"]).flat_map { |s| Array(s["lines"]) } + Array(script["sign_off"])
    end

    def characters(script)
      all_lines(script).sum { |l| l["text"].length }
    end

    # The parts of the show in order, each with its lines:
    # [{ "kind" => cold_open|segment|sign_off, "headline"?, "lines" }]
    def parts(script)
      [
        ({ "kind" => "cold_open", "lines" => script["cold_open"] } if script["cold_open"].present?),
        *Array(script["segments"]).map { |s| { "kind" => "segment", "headline" => s["headline"], "lines" => s["lines"] } },
        ({ "kind" => "sign_off", "lines" => script["sign_off"] } if script["sign_off"].present?)
      ].compact
    end

    # Lines cut into takes: stretches voiced in one request. A take ends
    # where the next line would overfill it, and after a beat (so the
    # silence is hob's to hold). With `voicing: lines` every line is a take.
    # -> [{ "lines" => [{ voice_id, text }], "first" => speaker, "last" => speaker, "beat" => bool }]
    def takes(lines, cast)
      alone = cast.setting(:voicing) == "lines"
      takes = []
      current = nil
      lines.flat_map { |l| split(l) }.each do |l|
        size = l["text"].length
        if current.nil? || alone || current["characters"] + size > TAKE_CHARACTERS
          current = { "lines" => [], "characters" => 0, "first" => l["speaker"] }
          takes << current
        end
        current["lines"] << { "voice_id" => cast.host(l["speaker"])["voice_id"], "text" => l["text"] }
        current["characters"] += size
        current["last"] = l["speaker"]
        if l["beat"]
          current["beat"] = true
          current = nil
        end
      end
      takes.each { |t| t.delete("characters") }
    end

    # A line too long for one take, as several at its sentence ends.
    def split(line)
      return [ line ] if line["text"].length <= TAKE_CHARACTERS

      pieces = [ +"" ]
      line["text"].split(/(?<=[.!?…])\s+/).flat_map { |s| s.scan(/.{1,#{TAKE_CHARACTERS}}(?:\s|\z)|.{1,#{TAKE_CHARACTERS}}/m) }.each do |sentence|
        pieces << +"" if pieces.last.length + sentence.length + 1 > TAKE_CHARACTERS && pieces.last.present?
        pieces.last << " " if pieces.last.present?
        pieces.last << sentence.strip
      end
      pieces.each_with_index.map do |text, i|
        line.merge("text" => text).tap { |l| l.delete("beat") unless i == pieces.size - 1 }
      end
    end
  end
end
