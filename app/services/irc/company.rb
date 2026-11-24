module Irc
  # A room's company (IRC.md, "Company"). A life can be kept to a room's
  # company, `life.company`:
  #
  #   { "room" => "#upstairs",   the room she lives for
  #     "minutes" => 30 }        she runs only within this long of its last company
  #
  # Thirteen characters talking to each other all day in a room nobody was
  # reading cost more than it was worth (#upstairs, 2026-11-24). So the
  # room has company (`irc_channels.company_at`) when a person reads it
  # from a surface, or when someone who lives without its company says
  # something there of their own accord: not from a beat a line woke, or
  # the ones kept to the room would keep it awake by naming her. Without
  # it, a life kept to the room takes no scheduled beat and no wake, and
  # the room's pulse does not fire.
  #
  # Company arriving in a room that had none runs the pulse at once, so
  # whoever came finds something started and not a room waiting on its
  # next sweep.
  class Company
    DEFAULT_MINUTES = 30
    MINUTES = 5..1440
    # A surface following along asks every half minute; the room is marked
    # no more often than this.
    MARK_EVERY = 1.minute

    def self.problems(config)
      return [] if config.nil?
      return [ "life.company is { room, minutes }" ] unless config.is_a?(Hash)

      config = config.stringify_keys
      problems = []
      unknown = config.keys - %w[room minutes]
      problems << "life.company has unknown keys: #{unknown.join(', ')}" if unknown.any?
      problems << "life.company.room is a channel's name" unless config["room"].to_s.match?(IrcChannel::NAME)
      minutes = config["minutes"]
      unless minutes.nil? || (minutes.is_a?(Integer) && MINUTES.cover?(minutes))
        problems << "life.company.minutes is a whole number from #{MINUTES.first} to #{MINUTES.last}"
      end
      problems
    end

    def self.minutes(config)
      (config.to_h["minutes"] || DEFAULT_MINUTES).to_i
    end

    def initialize(channel)
      @channel = channel
    end

    # The lives kept to this room's company.
    def kept
      PersonaLife.living.where("life->'company'->>'room' = ?", @channel.name)
    end

    def within?(minutes, now = Time.current)
      at = @channel.company_at
      at.present? && at > now - minutes.minutes
    end

    # Whether the room is kept for company it does not have: nobody here
    # for longer than any life kept to it waits.
    def away?(now = Time.current)
      waits = kept.pluck(:life).map { |life| self.class.minutes(life["company"]) }
      waits.any? && !within?(waits.max, now)
    end

    # Someone is here. -> true when the room had been without.
    def here!(now: Time.current)
      return false unless @channel.channel?
      return false if within?(MARK_EVERY / 1.minute, now)

      arrived = away?(now)
      @channel.update_columns(company_at: now)
      IrcPulseJob.perform_later if arrived && @channel.pulse
      arrived
    end

    # `who` said something here: company, unless she is kept to the room
    # herself or a line woke her to say it.
    def said!(who, now: Time.current)
      return false if Current.woken
      return false if kept.exists?([ "tools->>'agent' = ?", who.name ])

      here!(now: now)
    end
  end
end
