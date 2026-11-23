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
  #     "quiet_minutes" => 180,    nothing said for this long
  #     "loop_lines" => 24,        or the last this many lines ...
  #     "loop_nicks" => 2,         ... came from this few nicks
  #     "stale_lines" => 40,       or this many lines said since anything new was brought in
  #     "gap_minutes" => 240,      no pulse within this of the last
  #     "per_day" => 3 }           at most this many in any 24 hours
  #
  # A pulse is a wake (PersonaLife::Wake#pulse!) on the room's count, not
  # hers: her gap and token budget still hold, her wakes a day do not. It
  # is counted when her beat runs (#fired!), so a pulse she could not take
  # costs the room nothing and the next sweep asks again.
  class Pulse
    DEFAULTS = { "quiet_minutes" => 180, "loop_lines" => 24, "loop_nicks" => 2, "stale_lines" => 40,
                 "gap_minutes" => 240, "per_day" => 3 }.freeze
    RANGES = { "quiet_minutes" => 15..10_080, "loop_lines" => 6..200, "loop_nicks" => 1..10, "stale_lines" => 10..500,
               "gap_minutes" => 30..10_080, "per_day" => 1..24 }.freeze
    WINDOW = 24.hours

    def self.problems(config)
      return [] if config.nil?
      return [ "a pulse is { host, #{DEFAULTS.keys.join(', ')} }" ] unless config.is_a?(Hash)

      config = config.stringify_keys
      problems = []
      unknown = config.keys - DEFAULTS.keys - [ "host" ]
      problems << "a pulse has unknown keys: #{unknown.join(', ')}" if unknown.any?
      problems << "a pulse needs a host, a persona's key" if config["host"].blank?
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

    def host_agent
      host && PersonaLife.new(host).agent
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

    # Her hosted beat is running (PersonaLife::Wake): the pulse is counted now.
    def fired!(now: Time.current, reason: nil)
      @channel.update_columns(pulse_state: { "last_at" => now.utc.iso8601, "reason" => reason,
                                             "fired" => (fired_since(now) + [ now ]).map { |at| at.utc.iso8601 } }.compact)
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
      return :no_host if host.nil?

      why = reason(now: now) or return :fine
      life = PersonaLife.new(host)
      return :host_not_living unless PersonaLife.living.exists?(id: host.id)

      queued = PersonaLife::Wake.new(life).pulse!(@channel, reason: why, now: now)
      return queued unless queued == :queued

      Rails.logger.info("irc pulse #{@channel.name}: calling #{host.key}, #{why}")
      :pulsed
    end

    private

    def span(seconds)
      hours = (seconds / 1.hour).round
      return "about #{(seconds / 1.minute).round} minutes" if hours < 1
      return "about #{hours} hour#{'s' unless hours == 1}" if hours < 48

      "about #{(hours / 24.0).round} days"
    end
  end
end
