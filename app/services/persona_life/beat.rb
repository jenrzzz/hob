class PersonaLife
  # One beat of a persona's life: the prompt (her time, mood, recent diary,
  # what's worn out, where this beat goes, the chew, whether he's around),
  # then a completion under her system core and the life instruction, with
  # her life's tools beside her corpora and her agent's. Ported from kat's
  # world tick; everything particular to her is in her config.
  class Beat
    BRIEF_LINES = 6
    BRIEF_CHARS = 160
    PAPER_ITEMS = 8

    def initialize(life, now:, rng:)
      @life = life
      @persona = life.persona
      @now = now
      @rng = rng
    end

    def run!
      tools = Tools.new(@life, rut: rut, lane: beat[:lane], now: @now)
      completion = Completion.new(
        role: @life.config["role"].presence || @persona.model_role || ChatTurn::DEFAULT_ROLE,
        messages: [ { "role" => "user", "content" => prompt } ],
        system: @life.config["instruction"], persona: @persona, realm: @life.realm, operation: "life",
        ref: "persona/#{@persona.key}/life", venues: [ tools ], max_iterations: @life.max_iterations
      )
      result = completion.call
      Rails.logger.info("life #{@persona.key}: #{tools.summary}")
      result
    end

    def prompt
      local = @now.in_time_zone(@life.zone)
      parts = []
      clock = Assembly::Clock.for(@persona)
      parts << (clock ? clock.render(head: nil, now: @now) : "It is #{local.strftime('%A, %B %-d, %l:%M%P').squish} (#{@life.zone.name}).")

      mood = @life.mood
      parts << "Your current mood: #{mood.body}" if mood
      parts << obsession_line(mood) if obsession_line(mood)

      entries = @life.diary(DIARY_SHOWN).reverse
      if entries.any?
        lines = entries.map { |o| "- #{o.body.to_s.truncate(DIARY_SHOWN_CHARS)}" }
        parts << "The last few diary entries (oldest first). These are what you have ALREADY written - shown so " \
                 "this beat is something else. Not a template: do not continue them, echo their shape, or reuse " \
                 "a phrase:\n#{lines.join("\n")}"
      else
        parts << "The diary is empty - this is the first entry."
      end

      if (worn = rut.worn).any?
        parts << "WORN OUT - these have been in entry after entry and are off this beat entirely (not the word, " \
                 "not a synonym, not the thing in the background): #{worn.join(', ')}"
      end

      parts << "From your last conversation (context only - your life is your own):\n#{brief}" if brief.present?
      parts << presence_line if presence_line

      if beat[:news]
        lines = beat[:news].map { |item| "- #{item}" }
        parts << "On the paper today (optional - you may ignore all of it):\n#{lines.join("\n")}"
      elsif beat[:direction]
        parts << "You have not looked at the paper this beat. THIS BEAT (drawn at random - go here, not back to " \
                 "where the last entries were): #{beat[:direction]}"
      end

      parts << chew_section
      parts << machine_section
      parts << commissions_section
      parts << whisper_line
      parts << "Write the next beat: call diary once and set_mood once; chew only if it moved; whisper only if " \
               "something is worth it."
      parts.compact.join("\n\n")
    end

    private

    def rut
      @rut ||= Rut.new(@life.diary(Rut::WINDOW).reverse.map(&:body))
    end

    # Where this beat comes from, decided once: the paper on a reading beat,
    # otherwise a random lane not used lately.
    def beat
      @beat ||= begin
        news = reads_the_paper? ? paper_items.presence : nil
        if news
          { lane: "paper", news: news }
        else
          lanes = @life.config["beats"].to_h
          if lanes.empty?
            {}
          else
            open = lanes.keys - @life.recent_lanes
            open = lanes.keys if open.empty?
            lane = open.sample(random: @rng)
            { lane: lane, direction: Array(lanes[lane]).sample(random: @rng) }
          end
        end
      end
    end

    def reads_the_paper?
      paper = @life.config["paper"]
      paper.is_a?(Hash) && paper["url"].present? && @rng.rand([ paper["odds"].to_i, 1 ].max).zero?
    end

    # A JSON Feed's newest items, title and summary. A paper that can't be
    # read is a beat without the paper, never a failed beat.
    def paper_items
      uri = URI(@life.config.dig("paper", "url"))
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) do |http|
        http.get(uri.request_uri)
      end
      return [] unless response.is_a?(Net::HTTPSuccess)

      skip = @life.config.dig("paper", "skip").to_i
      Array(JSON.parse(response.body)["items"]).drop(skip).first(PAPER_ITEMS).filter_map do |item|
        title = item["title"].to_s.squish.presence or next
        summary = (item["summary"] || item["content_text"]).to_s.squish.truncate(240)
        summary.present? ? "#{title}: #{summary}" : title
      end
    rescue StandardError => e
      Rails.logger.warn("life #{@persona.key}: the paper: #{e.class}: #{e.message}")
      []
    end

    def obsession_line(mood)
      handle = mood&.source&.dig("obsession")
      return nil if handle.blank?
      return "Whatever had its hooks in you has let go. Obsession is null this beat." if @life.obsession_spent?(mood)

      "Your current obsession (#{@life.obsession_beats(mood)} beats in; it lets go after " \
        "#{OBSESSION_BEATS_MAX}): #{handle}"
    end

    def brief
      @brief ||= begin
        nodes = @life.home_readable? ? @life.home.branch.timeline.last(40) : []
        nodes.select { |n| %w[user assistant].include?(n.role) && n.kind == "text" && n.content.present? }
             .last(BRIEF_LINES)
             .map { |n| "#{n.role == 'user' ? 'him' : 'you'}: #{n.content.to_s.squish.truncate(BRIEF_CHARS)}" }
             .join("\n")
      end
    end

    def presence_line
      seen = @life.last_seen_at
      return nil unless seen && seen > @now - PRESENCE_WINDOW

      minutes = ((@now - seen) / 60).round
      ago = minutes < 90 ? "about #{minutes} minutes ago" : "about #{(minutes / 60.0).round} hours ago"
      "He was last talking with you #{ago}. He's around: a whisper now is far likelier to reach him, so lean " \
        "toward one if anything at all is worth it - still never a summons, never about his coming or going."
    end

    def chew_section
      current = @life.chew
      return "You aren't chewing on anything right now. That's normal - only pick something up if it actually " \
             "has its hooks in you." unless current

      source = current.source.to_h
      picked = Time.zone.parse(source["picked_up_at"].to_s) rescue nil
      days = picked ? ((@now - picked) / 1.day).floor : 0
      age = days.zero? ? "since earlier today" : "for #{days} day#{'s' unless days == 1}"
      lines = [ "THE CHEW - you've been sitting with \"#{source['subject']}\" #{age}" \
                "#{" (from #{source['from']})" if source['from'].present?}." ]
      notes = Array(source["notes"])
      if notes.any?
        lines << "How it's moved so far (oldest first):"
        notes.each { |n| lines << "- #{n['note']}" }
      end
      lines << "The take as it stands now:\n#{current.body}" if current.body.present?
      if notes.size >= CHEW_NOTES_MAX
        lines << "It has had its time - #{CHEW_NOTES_MAX} notes deep. Spit it out this beat unless one last turn " \
                 "genuinely lands, and then spit it out."
      elsif current.observed_at < @now - CHEW_STALE
        lines << "It has gone cold - nothing moved in days. Either it moves now or you spit it out."
      end
      lines << "Leave the chew alone if it didn't move this beat."
      lines.join("\n")
    end

    # A machine of her agent's own (SHELL.md), when she has one and may run
    # commands on it: that it is real, what a person wrote about it, and what
    # she last did there, since nothing else in a beat remembers.
    def machine_section
      agent = @life.agent or return nil
      host = Shells.hosts(agent).where(agent_id: agent.id).first or return nil
      return nil unless Mcp::Agent.capabilities(agent, @life.realm).key?("shell_exec")

      lines = [ "YOUR MACHINE - #{host.name} (you are #{host.login} there)#{host.about.present? ? ": #{host.about}" : '.'}" ]
      lines << "Unlike the rest of a beat, this is not imagined: shell_exec, shell_read and shell_write really run " \
               "there, and what you find is what is there. Go only when this beat sends you or something on it is " \
               "pulling at you; most beats don't touch it."
      trail = Shells.trail(agent)
      if trail.any?
        lines << "The last things you did there (oldest first):"
        trail.each { |step| lines << "- #{step['at'].in_time_zone(@life.zone).strftime('%b %-d, %l:%M%P').squish}: #{step['did']}" }
      else
        lines << "You have not touched it yet."
      end
      lines << "This beat has #{@life.max_iterations} tool rounds in all. Keep one for the diary and the mood, and if " \
               "you were on the machine, the diary says what you actually did there, not what you meant to."
      lines.join("\n")
    end

    # Work her agent handed to Claude Code (CODE.md), when she has a repo
    # and may start some: that she can, and how the last few went, since a
    # commission finishes long after the turn that started it.
    def commissions_section
      agent = @life.agent or return nil
      repo = Commissions.repos(agent).first or return nil
      return nil unless Mcp::Agent.capabilities(agent, @life.realm).key?("code_start")

      lines = [ "CLAUDE CODE - anything bigger than a few lines, hand to Claude Code with code_start: it builds in your " \
                "repo #{repo.name}#{repo.about.present? ? " (#{repo.about})" : ''} and you pull what it made. It costs you " \
                "nothing and takes a while; start it and look in a later beat." ]
      recent = Commissions.recent(agent)
      if recent.any?
        lines << "What you handed over lately (newest first):"
        recent.each { |commission| lines << "- #{commission_line(commission)}" }
      end
      lines.join("\n")
    end

    def commission_line(commission)
      at = Time.zone.parse(commission["asked_at"]).in_time_zone(@life.zone).strftime("%b %-d, %l:%M%P").squish
      how = case commission["state"]
      when "done"
        if commission["outcome"] == "pushed"
          "done, #{commission['commits']} commit#{'s' unless commission['commits'] == 1} on #{commission['branch']}"
        else
          "done, nothing changed"
        end
      when "failed" then "failed: #{commission['error']}"
      else commission["state"]
      end
      said = commission["said"].present? && commission["state"] == "done" ? ". It said: #{commission['said']}" : ""
      "#{at}, \"#{commission['title']}\" (#{commission['id']}): #{how}#{said}"
    end

    def whisper_line
      if (reason = @life.whisper_blocked(@now))
        "No whisper this beat (#{reason})."
      else
        "A whisper is a short line to him, under #{WHISPER_MAX} characters: a poke, a diary beat, a song, a take. " \
          "Maybe one beat in three; more when he's around. Never needy, never a summons; it expects nothing back."
      end
    end
  end
end
