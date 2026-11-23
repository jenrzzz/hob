class PersonaLife
  # A beat soon after a persona's agent is spoken to on hob's IRC (IRC.md,
  # "Woken"). `life.wakes`:
  #
  #   { "gap_minutes" => 20,     no wake within this of her last beat, scheduled or woken
  #     "per_day" => 8,          at most this many wakes in any 24 hours
  #     "delay_minutes" => 3 }   how long a wake waits, so a burst is read in one beat
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
  # The woken beat draws no lane. Its page names who spoke to her and
  # where, never what they said: that reaches her through irc_read, as data.
  # It runs at the lowest realm her life is kept at that is no lower than
  # the room (PersonaLife#realm_for_room); a room above all of them wakes
  # nobody.
  class Wake
    DEFAULTS = { "gap_minutes" => 20, "per_day" => 8, "delay_minutes" => 3 }.freeze
    RANGES = { "gap_minutes" => 5..1440, "per_day" => 1..48, "delay_minutes" => 0..60 }.freeze
    WINDOW = 24.hours
    # Another beat of hers is running: try again this much later.
    BUSY_RETRY = 2.minutes
    # A pending wake this far past due lost its job; a new line queues another.
    STALE = 15.minutes
    CALLS_KEPT = 8

    def self.problems(config)
      return [] if config.nil?

      shape = "life.wakes is { gap_minutes, per_day, delay_minutes }, each a whole number"
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
          due = now + delay
          queue = due
        end
        @persona.update_columns(wake: current.merge("calls" => calls.last(CALLS_KEPT), "due_at" => due.utc.iso8601))
      end
      PersonaWakeJob.set(wait_until: queue).perform_later(@persona.id) if queue
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

      last = [ Clearance.with(@life.top_realm) { @life.last_beat_at }, last_woken_at ].compact.max
      if last && last > now - gap
        defer!(last + gap)
        return :deferred
      end
      return drop!("#{per_day} wakes in a day already") if woken_since(now).size >= per_day
      return drop!("over her token budget") if @life.budget.over?(now)

      wake = Clearance.with(@life.top_realm) { waiting }
      return drop!("nothing is waiting for her") if wake.nil?

      @persona.update_columns(wake: { "last_at" => now.utc.iso8601,
                                      "woken" => (woken_since(now) + [ now ]).map { |at| at.utc.iso8601 } })
      Rails.logger.info("wake #{@persona.key}: woken at #{wake[:realm]} by " +
                        wake[:calls].map { |call| "#{call[:nick]} in #{call[:where]}" }.join(", "))
      @life.beat!(now: now, rng: rng, wake: wake)
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

        { where: channel.dm? ? nil : channel.name, nick: call["nick"], realm: realm }
      end
      return nil if calls.empty?
      return nil unless Mcp::Agent.capabilities(agent, calls.map { |c| c[:realm] }.max_by { |r| Realm.rank_of(r) }).key?("irc_read")

      { realm: calls.map { |c| c[:realm] }.max_by { |r| Realm.rank_of(r) }, calls: calls }
    end

    def defer!(at)
      @persona.update_columns(wake: state.merge("due_at" => at.utc.iso8601))
      Rails.logger.info("wake #{@persona.key}: inside her gap; waiting until #{at.utc.iso8601}")
      PersonaWakeJob.set(wait_until: at).perform_later(@persona.id)
    end

    def drop!(reason)
      @persona.update_columns(wake: state.except("due_at", "calls"))
      Rails.logger.info("wake #{@persona.key}: skipped, #{reason}")
      reason
    end
  end
end
