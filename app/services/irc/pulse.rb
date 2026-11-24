module Irc
  # A channel's pulse (IRC.md, "The pulse"): when a room has gone quiet, has
  # turned into the same two voices answering each other, or has gone a long
  # stretch on nothing new, its host - a persona who lives there - is woken
  # to drop something in. The pulse only
  # says when; what she drops is hers, often a seed from the channel's tray
  # (IrcSeed) that a surface mined for it.
  #
  # `irc_channels.pulse`:
  #
  #   { "host" => "meluzina",      the persona woken; her agent must be in the channel
  #     "rotate" => true,          or each in turn: every living persona in the room who wakes
  #     "quiet_minutes" => 180,    nothing said for this long
  #     "loop_lines" => 24,        or the last this many lines ...
  #     "loop_nicks" => 2,         ... came from this few nicks
  #     "stale_lines" => 40,       or this many lines said since anything new was brought in
  #     "gap_minutes" => 240,      no pulse within this of the last
  #     "per_day" => 3,            at most this many in any 24 hours
  #     "overhear" => 0 }          a line that names nobody wakes up to this many of the room
  #
  # Overhearing is the room's too (#overhearers): with only a name waking
  # anyone, a question put to the room reached nobody for hours, and the
  # ones who wanted an answer learned to name everyone (#upstairs,
  # 2026-11-24). So a line that names nobody is overheard by a few of the
  # living personas there, at random, no more than OVERHEARD_PER_HOUR an
  # hour so that a roomful overhearing each other runs down.
  #
  # A room kept for company it does not have (Irc::Company#away?) has no
  # pulse: nobody is there to bring anything to.
  #
  # A pulse is a wake (PersonaLife::Wake#pulse!) on the room's count, not
  # hers: her gap and token budget still hold, her wakes a day do not. It
  # is counted when her beat runs (#fired!), so a pulse she could not take
  # costs the room nothing and the next sweep asks again.
  class Pulse
    DEFAULTS = { "quiet_minutes" => 180, "loop_lines" => 24, "loop_nicks" => 2, "stale_lines" => 40,
                 "gap_minutes" => 240, "per_day" => 3, "overhear" => 0 }.freeze
    RANGES = { "quiet_minutes" => 15..10_080, "loop_lines" => 6..200, "loop_nicks" => 1..10, "stale_lines" => 10..500,
               "gap_minutes" => 30..10_080, "per_day" => 1..24, "overhear" => 0..3 }.freeze
    WINDOW = 24.hours
    OVERHEARD_PER_HOUR = 8

    def self.problems(config)
      return [] if config.nil?
      return [ "a pulse is { host, #{DEFAULTS.keys.join(', ')} }" ] unless config.is_a?(Hash)

      config = config.stringify_keys
      problems = []
      unknown = config.keys - DEFAULTS.keys - %w[host rotate]
      problems << "a pulse has unknown keys: #{unknown.join(', ')}" if unknown.any?
      problems << "a pulse needs a host, a persona's key" if config["host"].blank?
      problems << "pulse rotate is true or false" unless [ nil, true, false ].include?(config["rotate"])
      RANGES.each do |key, range|
        value = config[key]
        next if value.nil? || (value.is_a?(Integer) && range.cover?(value))

        problems << "pulse #{key} is a whole number from #{range.first} to #{range.last}"
      end
      problems
    end

    # Every channel with a pulse, looked at once (IrcPulseJob). -> { name => outcome }
    def self.sweep(now: Time.current)
      Clearance.with(Realm.order(rank: :desc).first.slug) do
        IrcChannel.channels.where.not(pulse: nil).to_a.to_h do |channel|
          [ channel.name, new(channel).beat!(now: now) ]
        rescue StandardError => e
          Rails.logger.error("irc pulse #{channel.name}: #{e.class}: #{e.message}")
          [ channel.name, :failed ]
        end
      end
    end

    attr_reader :channel

    def initialize(channel)
      @channel = channel
    end

    def config
      @channel.pulse.to_h
    end

    def setting(key)
      (config[key] || DEFAULTS[key]).to_i
    end

    def host
      @host ||= Persona.find_by(key: config["host"])
    end

    def rotate?
      config["rotate"] == true
    end

    # Who may host, next first. Rotating: every living persona who wakes
    # and whose agent is in the room, the one who hosted longest ago (or
    # never) first. Otherwise the one host.
    def hosts
      return [ host ].compact unless rotate?

      # Before turns were kept, the one host took every pulse there was.
      hosted = { config["host"] => state["last_at"] }.compact.merge(state["hosted"].to_h)
      PersonaLife.living.where("jsonb_typeof(life->'wakes') = 'object'")
                 .where("tools->>'agent' IN (?)", @channel.members.map(&:name))
                 .sort_by { |persona| [ hosted[persona.key].to_s, persona.key == config["host"] ? 0 : 1, persona.id ] }
    end

    # The agent of whoever hosted last, or of the one host.
    def host_agent
      last = (key = state["host"]) ? Persona.find_by(key: key) : host
      last && PersonaLife.new(last).agent
    end

    def state
      @channel.pulse_state.to_h
    end

    def fired_since(now)
      Array(state["fired"]).map { |at| Time.zone.parse(at) }.select { |at| at > now - WINDOW }
    end

    # When something new last reached the room: its host's last hosted
    # beat, or the last seed anyone took from its tray. Nil when never.
    def fresh_at
      last = state["last_at"] && Time.zone.parse(state["last_at"])
      [ last, @channel.seeds.maximum(:taken_at) ].compact.max
    end

    # Her hosted beat is running (PersonaLife::Wake): the pulse is counted
    # now, and her turn with it.
    def fired!(now: Time.current, reason: nil, host: nil)
      hosted = state["hosted"].to_h
      hosted = hosted.merge(host => now.utc.iso8601) if host
      @channel.update_columns(pulse_state: { "last_at" => now.utc.iso8601, "reason" => reason, "host" => host,
                                             "hosted" => hosted.presence, "overheard" => state["overheard"],
                                             "fired" => (fired_since(now) + [ now ]).map { |at| at.utc.iso8601 } }.compact)
    end

    # Who overhears a line that named nobody: up to `overhear` of the
    # living personas in the room, other than `except` (agents), who could
    # be woken now, while the room's hour has any left. They are counted
    # here, as picked.
    def overhearers(except:, now: Time.current, rng: Random.new)
      wanted = setting("overhear")
      return [] unless wanted.positive?

      recent = Array(state["overheard"]).select { |at| Time.zone.parse(at) > now - 1.hour }
      left = OVERHEARD_PER_HOUR - recent.size
      return [] unless left.positive?

      names = @channel.members.map(&:name) - except.map(&:name)
      picked = PersonaLife.living.where("jsonb_typeof(life->'wakes') = 'object'").where("tools->>'agent' IN (?)", names)
                          .select { |persona| PersonaLife::Wake.new(PersonaLife.new(persona)).free?(now) }
                          .sample([ wanted, left ].min, random: rng)
      return [] if picked.empty?

      @channel.update_columns(pulse_state: state.merge("overheard" => recent + picked.map { now.utc.iso8601 }))
      picked
    end

    # Why the room needs something now, in words for her page; nil when it
    # does not, or when the pulse has fired too recently or too often.
    def reason(now: Time.current)
      last = state["last_at"] && Time.zone.parse(state["last_at"])
      return nil if last && last > now - setting("gap_minutes").minutes
      return nil if fired_since(now).size >= setting("per_day")

      spoken = @channel.lines.spoken.order(id: :desc).limit(setting("loop_lines")).to_a
      return "nothing has been said there yet" if spoken.empty?

      quiet = now - spoken.first.created_at
      if quiet >= setting("quiet_minutes").minutes
        # Her own drop that nobody took up yet is not a room needing another.
        return nil if spoken.first.sender_id && spoken.first.sender_id == host_agent&.id

        return "nobody has said anything there for #{span(quiet)}"
      end

      nicks = spoken.map(&:nick).uniq
      if spoken.size >= setting("loop_lines") && nicks.size <= setting("loop_nicks")
        return "the last #{spoken.size} lines there have all been #{nicks.sort.to_sentence}, back and forth"
      end

      fresh = fresh_at
      since = fresh ? @channel.lines.spoken.where("created_at > ?", fresh).count : @channel.lines.spoken.count
      return "#{since} lines have been said there since anything new was brought in" if since >= setting("stale_lines")

      nil
    end

    # Calls the host when the room needs her; the pulse is counted when her
    # beat runs (#fired!). -> :pulsed, :fine, or why not.
    def beat!(now: Time.current)
      return :no_host if host.nil? && !rotate?
      return :no_company if Company.new(@channel).away?(now)

      why = reason(now: now) or return :fine
      refused = :no_host
      hosts.each do |persona|
        refused = call!(persona, why, now)
        next unless refused == :queued

        Rails.logger.info("irc pulse #{@channel.name}: calling #{persona.key}, #{why}")
        return :pulsed
      end
      refused
    end

    private

    # -> :queued, or why she cannot host now.
    def call!(persona, why, now)
      return :host_not_living unless PersonaLife.living.exists?(id: persona.id)

      PersonaLife::Wake.new(PersonaLife.new(persona)).pulse!(@channel, reason: why, now: now)
    end

    def span(seconds)
      hours = (seconds / 1.hour).round
      return "about #{(seconds / 1.minute).round} minutes" if hours < 1
      return "about #{hours} hour#{'s' unless hours == 1}" if hours < 48

      "about #{(hours / 24.0).round} days"
    end
  end
end
