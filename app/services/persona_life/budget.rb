class PersonaLife
  # What a persona's life may spend in a day (`life.budget`, MELUZINA.md, "A
  # persona's life"): the tokens of every round of her beats, scheduled or
  # woken, over the last 24 hours, as hob's usage ledger has them (events
  # with ref persona/<key>/life; input, output, cache read and cache write).
  # At or over it, nothing wakes her (PersonaLife::Wake) and her agent cannot
  # speak on IRC (Irc.say). Her scheduled beats still run, and say so.
  #
  #   { "tokens_per_day" => 200_000 }
  #
  # Absent is no budget.
  class Budget
    WINDOW = 24.hours
    MAX = 100_000_000
    UNITS = %w[input_tokens output_tokens cache_read_tokens cache_creation_tokens].freeze

    def self.problems(config)
      return [] if config.nil?

      shape = "life.budget is { tokens_per_day: a whole number from 1 to #{MAX} }"
      return [ shape ] unless config.is_a?(Hash)

      config = config.stringify_keys
      tokens = config["tokens_per_day"]
      return [ shape ] unless config.keys == %w[tokens_per_day] && tokens.is_a?(Integer) && tokens.between?(1, MAX)

      []
    end

    # The living persona whose agent this is, with a budget, or nil.
    def self.for_agent(agent)
      return nil unless agent&.agent?

      persona = PersonaLife.living.where("tools->>'agent' = ?", agent.name).where("jsonb_typeof(life->'budget') = 'object'").first
      persona && PersonaLife.new(persona).budget
    end

    def initialize(life)
      @life = life
    end

    def persona
      @life.persona
    end

    def tokens_per_day
      @life.config.dig("budget", "tokens_per_day")&.to_i
    end

    def set?
      tokens_per_day.to_i.positive?
    end

    # The ledger is not realm-scoped, so this is the same at any clearance.
    def events(now)
      UsageEvent.where(ref: "persona/#{@life.persona.key}/life", created_at: (now - WINDOW)..now)
    end

    def spent(now = Time.current)
      sum = UNITS.map { |unit| "COALESCE((units->>'#{unit}')::bigint, 0)" }.join(" + ")
      events(now).sum(Arel.sql(sum)).to_i
    end

    def over?(now = Time.current)
      set? && spent(now) >= tokens_per_day
    end

    # When enough of the last day's spending has aged out that she is under
    # again: the oldest events drop off first.
    def again_at(now = Time.current)
      left = spent(now)
      return now unless set? && left >= tokens_per_day

      events(now).order(:created_at).each do |event|
        left -= UNITS.sum { |unit| event.units.to_h[unit].to_i }
        return event.created_at + WINDOW if left < tokens_per_day
      end
      now + WINDOW
    end

    # For a surface to show (GET life); nil without a budget.
    def as_json(now = Time.current)
      return nil unless set?

      spent = spent(now)
      { "tokens_per_day" => tokens_per_day, "spent_24h" => spent, "over" => spent >= tokens_per_day,
        "again_at" => (again_at(now).utc.iso8601 if spent >= tokens_per_day) }.compact
    end
  end
end
