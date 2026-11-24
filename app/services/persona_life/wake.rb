class PersonaLife
  # A beat soon after a persona's agent is spoken to on hob's IRC (IRC.md,
  # "Woken"). `life.wakes`:
  #
  #   { "gap_minutes" => 20,     no wake within this of her last beat, scheduled or woken
  #     "per_day" => 8,          at most this many wakes in any 24 hours
  #     "delay_minutes" => 3,    how long a wake waits, so a burst is read in one beat
  #     "jitter_minutes" => 0,   and up to this much longer, at random, so a roomful does not answer in step
  #     "backoff" => 2 }         each wake in a row waits this many times longer than the last; 1 is never
  #
  # Absent is no wakes. A line said in a channel wakes each member whose
  # nick it names, and a DM wakes its other end; never the line's sender,
  # and only an agent a living persona acts as, whose life has `wakes`.
  #
  # A persona has at most one wake pending (`personas.wake`): a line that
  # names her while one is pending joins it. When it comes due inside her
  # gap it waits for the gap's end; over `per_day`, or over her token
  # budget (PersonaLife::Budget), it is dropped and logged, and her next
  # scheduled beat sees the lines in its IRC section as before.
  #
  # Wakes in a row are a room answering itself, so each waits longer than
  # the one before (`backoff`): her gap, then twice it, four times, and no
  # more than BACKOFF_MAX times. The run ends when she has not been woken
  # for REST, or when something new was brought to a room that named her
  # (Irc::Pulse#fresh_at). From DEEP wakes in a row her page says so and
  # offers the room's tray.
  #
  # A room's pulse (Irc::Pulse) wakes its host the same way, with the room
  # and why it needs something in place of who named her. Hosting is not
  # being talked to: it keeps her plain gap, is not counted toward
  # `per_day` or held back by it, and ends her run.
  #
  # The woken beat draws no lane. Its page names who spoke to her and
  # where, never what they said: that reaches her through irc_read, as data.
  # It runs at the lowest realm her life is kept at that is no lower than
  # the room (PersonaLife#realm_for_room); a room above all of them wakes
  # nobody.
  class Wake
    DEFAULTS = { "gap_minutes" => 20, "per_day" => 8, "delay_minutes" => 3, "jitter_minutes" => 0, "backoff" => 2 }.freeze
    RANGES = { "gap_minutes" => 5..1440, "per_day" => 1..48, "delay_minutes" => 0..60, "jitter_minutes" => 0..60,
               "backoff" => 1..4 }.freeze
    # The gap of a run of wakes never grows past this many times itself.
    BACKOFF_MAX = 8
    # Not woken for this long: the run is over, and the next wake is a first.
    REST = 6.hours
    # This many wakes in a row and her page says the room is answering itself.
    DEEP = 3
    WINDOW = 24.hours
    # Another beat of hers is running: try again this much later.
    BUSY_RETRY = 2.minutes
    # A pending wake this far past due lost its job; a new line queues another.
    STALE = 15.minutes
    CALLS_KEPT = 8

    def self.problems(config)
      return [] if config.nil?

      shape = "life.wakes is { gap_minutes, per_day, delay_minutes, jitter_minutes, backoff }, each a whole number"
      return [ shape ] unless config.is_a?(Hash)

      config = config.stringify_keys
      problems = []
      unknown = config.keys - DEFAULTS.keys
      problems << "life.wakes has unknown keys: #{unknown.join(', ')}" if unknown.any?
      RANGES.each do |key, range|
        value = config[key]
        next if value.nil? || (value.is_a?(Integer) && range.cover?(value))

        problems << "life.wakes.#{key} is a whole number from #{range.first} to #{range.last}"
      end
      problems
    end

    # Whether `body` names `nick`, as a word: case aside, and not inside a
    # longer name (twilight is not twilights, nor twilight_2).
    def self.names?(body, nick)
      body.to_s.match?(/(?<![[:alnum:]_])#{Regexp.escape(nick)}(?![[:alnum:]_])/i)
    end

    # After `lines` were said in `channel` (Irc.say): queue a wake for each
    # persona they reach. Never fails the line.
    def self.heard(channel, lines)
      spoken = lines.select { |line| IrcLine::SPOKEN.include?(line.kind) && line.sender_id }
      return if spoken.empty?

      sender = spoken.first
      others = channel.members.reject { |member| member.id == sender.sender_id }
      named = channel.dm? ? others : others.select { |member| spoken.any? { |line| names?(line.body, member.name) } }
      return if named.empty?

      Persona.transaction(requires_new: true) do
        PersonaLife.living.where("jsonb_typeof(life->'wakes') = 'object'")
                   .where("tools->>'agent' IN (?)", named.map(&:name)).find_each do |persona|
          wake = new(PersonaLife.new(persona))
          wake.call!(channel, nick: sender.nick, line: spoken.last) if named.include?(wake.life.agent)
        end
      end
    rescue StandardError => e
      Rails.logger.error("irc wake from #{channel.name}: #{e.class}: #{e.message}")
    end

    attr_reader :life

    def initialize(life)
      @life = life
      @persona = life.persona
    end

    def on?
      @life.config["wakes"].is_a?(Hash)
    end

    def setting(key)
      (@life.config["wakes"].to_h[key] || DEFAULTS[key]).to_i
    end

    def gap = setting("gap_minutes").minutes
    def per_day = setting("per_day")
    def delay = setting("delay_minutes").minutes
    def backoff = setting("backoff")

    # How long this wake waits: her delay, and some of her jitter.
    def wait
      delay + rand(0..setting("jitter_minutes") * 60).seconds
    end

    # How long a wake waits after her last one, `streak` wakes into a run:
    # her gap after the first, then `backoff` times longer after each.
    def gap_after(streak)
      gap * [ backoff**[ streak - 1, 0 ].max, BACKOFF_MAX ].min
    end

    # How many wakes in a row she is into, as of `now`: none once she has
    # rested, or once something new reached a room that is naming her.
    def streak(now)
      last = last_woken_at
      return 0 if last.nil? || last <= now - REST

      rooms = IrcChannel.where(id: Array(state["calls"]).map { |call| call["channel"] })
      return 0 if rooms.any? { |room| Irc::Pulse.new(room).fresh_at&.>=(last) }

      state["streak"].to_i
    end

    def state
      @persona.wake.to_h
    end

    def last_woken_at
      at = state["last_at"]
      at && Time.zone.parse(at)
    end

    def woken_since(now)
      Array(state["woken"]).map { |at| Time.zone.parse(at) }.select { |at| at > now - WINDOW }
    end

    # Someone named her in `channel` (or wrote to her there, a DM). Queues
    # a wake `delay` from now, or joins the one pending.
    def call!(channel, nick:, line:, now: Time.current)
      agent = @life.agent
      return unless on? && agent
      return if @life.realm_for_room(channel.realm).nil?
      return if Realm.rank_of(channel.realm) > Realm.rank_of(agent.max_clearance)

      queue = nil
      @persona.with_lock do
        current = state
        calls = Array(current["calls"]).reject { |call| call["channel"] == channel.id }
        calls << { "channel" => channel.id, "nick" => nick, "line" => line.id }
        due = current["due_at"] && Time.zone.parse(current["due_at"])
        if due.nil? || due < now - STALE
          due = now + wait
          queue = due
        end
        @persona.update_columns(wake: current.merge("calls" => calls.last(CALLS_KEPT), "due_at" => due.utc.iso8601))
      end
      PersonaWakeJob.set(wait_until: queue).perform_later(@persona.id) if queue
    end

    # Her room's pulse (Irc::Pulse): `channel` needs something, for `reason`.
    # Queues a wake like a call does, or joins the one pending; unlike a
    # call it is not answered by reading, only by the beat it wakes.
    # -> :queued, or why not.
    def pulse!(channel, reason:, now: Time.current)
      agent = @life.agent
      return :wakes_off unless on?
      return :no_agent unless agent
      return :above_her if @life.realm_for_room(channel.realm).nil? || Realm.rank_of(channel.realm) > Realm.rank_of(agent.max_clearance)
      return :not_in_channel unless channel.memberships.exists?(principal: agent)
      return :over_budget if @life.budget.over?(now)

      queue = nil
      @persona.with_lock do
        current = state
        due = current["due_at"] && Time.zone.parse(current["due_at"])
        # A wake pending far off is a run of names backing off: the room does not wait for that.
        if due.nil? || due < now - STALE || due > now + delay
          due = now + delay
          queue = due
        end
        @persona.update_columns(wake: current.merge("pulse" => { "channel" => channel.id, "reason" => reason },
                                                    "due_at" => due.utc.iso8601))
      end
      PersonaWakeJob.set(wait_until: queue).perform_later(@persona.id) if queue
      :queued
    end

    # The pending wake, when it is due: runs it, waits out her gap, or drops
    # it. -> :woken, :deferred, :busy, or a reason it was dropped.
    def run!(now: Time.current, rng: Random.new)
      result = @life.exclusively { settle!(now, rng) }
      if result == :busy
        Rails.logger.info("wake #{@persona.key}: another beat of hers is running; trying again shortly")
        PersonaWakeJob.set(wait_until: now + BUSY_RETRY).perform_later(@persona.id)
      end
      result
    end

    private

    def settle!(now, rng)
      @persona.reload
      due = state["due_at"] && Time.zone.parse(state["due_at"])
      return :nothing_pending if due.nil? || due > now
      return drop!("wakes are off") unless on?

      wake = Clearance.with(@life.top_realm) { waiting }
      return drop!("nothing is waiting for her") if wake.nil?

      hosting = wake.key?(:pulse)
      run = hosting ? 0 : Clearance.with(@life.top_realm) { streak(now) }
      ready = [ Clearance.with(@life.top_realm) { @life.last_beat_at }&.+(gap),
                last_woken_at&.+(hosting ? gap : gap_after(run)) ].compact.max
      if ready && ready > now
        defer!(ready)
        return :deferred
      end
      return drop!("#{per_day} wakes in a day already") if !hosting && woken_since(now).size >= per_day
      return drop!("over her token budget") if @life.budget.over?(now)

      @persona.update_columns(wake: { "last_at" => now.utc.iso8601, "streak" => hosting ? 0 : run + 1,
                                      "woken" => (woken_since(now) + (hosting ? [] : [ now ])).map { |at| at.utc.iso8601 } })
      if hosting
        Clearance.with(@life.top_realm) do
          Irc::Pulse.new(IrcChannel.find(wake[:pulse][:channel_id])).fired!(now: now, reason: wake[:pulse][:reason],
                                                                                 host: @persona.key)
        end
      end
      Rails.logger.info("wake #{@persona.key}: woken at #{wake[:realm]} by " +
                        (wake[:calls].map { |call| "#{call[:nick]} in #{call[:where]}" } +
                         [ wake[:pulse] && "the pulse of #{wake[:pulse][:where]}" ]).compact.join(", ") +
                        (run.positive? ? ", #{run} in a row before it" : ""))
      @life.beat!(now: now, rng: rng, wake: wake.merge(streak: run))
      :woken
    end

    # Who named her where, of the calls pending, that she has not read yet
    # and her agent can reach; and the realm the beat runs at (the highest
    # any of them asks for). Nil when none is left.
    def waiting
      agent = @life.agent or return nil
      calls = Array(state["calls"]).filter_map do |call|
        channel = IrcChannel.find_by(id: call["channel"]) or next
        realm = @life.realm_for_room(channel.realm) or next
        next if Realm.rank_of(channel.realm) > Realm.rank_of(agent.max_clearance)

        membership = channel.memberships.find_by(principal: agent) or next
        next if membership.read_line_id.to_i >= call["line"].to_i

        { where: channel.dm? ? nil : channel.name, channel_id: channel.id, nick: call["nick"], realm: realm }
      end
      pulse = pulse_waiting(agent)
      return nil if calls.empty? && pulse.nil?

      realm = (calls.map { |c| c[:realm] } + [ pulse&.dig(:realm) ]).compact.max_by { |r| Realm.rank_of(r) }
      return nil unless Mcp::Agent.capabilities(agent, realm).key?("irc_read")

      { realm: realm, calls: calls, pulse: pulse }.compact
    end

    # The room whose pulse woke her, while her agent is still in it.
    def pulse_waiting(agent)
      pulse = state["pulse"] or return nil
      channel = IrcChannel.find_by(id: pulse["channel"]) or return nil
      realm = @life.realm_for_room(channel.realm) or return nil
      return nil if Realm.rank_of(channel.realm) > Realm.rank_of(agent.max_clearance)
      return nil unless channel.memberships.exists?(principal: agent)

      { where: channel.name, channel_id: channel.id, reason: pulse["reason"], realm: realm }
    end

    def defer!(at)
      @persona.update_columns(wake: state.merge("due_at" => at.utc.iso8601))
      Rails.logger.info("wake #{@persona.key}: inside her gap; waiting until #{at.utc.iso8601}")
      PersonaWakeJob.set(wait_until: at).perform_later(@persona.id)
    end

    def drop!(reason)
      @persona.update_columns(wake: state.except("due_at", "calls", "pulse"))
      Rails.logger.info("wake #{@persona.key}: skipped, #{reason}")
      reason
    end
  end
end
