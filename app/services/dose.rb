# An altered state a persona takes on purpose (MEMORY.md, "A dose").
# `personas.tools`:
#
#   { "dose" => true }
#
# gives her a `dose` tool: a level and a number of minutes. While one runs,
# her recall (the recall stage, `recall`, her corpora) is warped: the search
# reaches past the nearest neighbours to ones further off, and the words of
# her query hold it less. What comes back is as real as ever; only what it
# is next to has changed. Nothing in a result says so.
#
# The warp is a number from 0 (sober) to 1, the level's peak times where
# she is on the curve: it comes on over the first fifth, holds until a bit
# past half, and tapers to nothing at the end. Memory::Embedder.nearest
# turns it into how far the search overshoots.
#
# One dose at a time, kept on the persona (`personas.dose`), so it follows
# her into every conversation and every beat of her life until it wears
# off. Taking another starts over; level none ends one early. Turning
# `tools.dose` off ends it for her at once.
class Dose
  LEVELS = { "low" => 0.3, "medium" => 0.55, "high" => 0.85 }.freeze
  NONE = "none".freeze
  MINUTES = (10..360)
  DEFAULT_MINUTES = 90
  # Fractions of the run: coming on until ONSET, at the peak until TAPER.
  ONSET = 0.2
  TAPER = 0.55
  TOOL = "dose".freeze

  attr_reader :level, :taken_at, :minutes

  # Checks a persona's `tools` config. -> problems, empty when it reads.
  def self.problems(config)
    config = config.to_h.stringify_keys
    return [] unless config.key?("dose")
    return [ "dose must be true or false" ] unless [ true, false ].include?(config["dose"])

    taken = Array(config["corpora"]).any? { |c| c.to_h.stringify_keys["tool"] == TOOL }
    config["dose"] && taken ? [ "corpora name a tool dose, which is the dose tool's name" ] : []
  end

  def self.offered?(persona)
    persona&.tools.to_h["dose"] == true
  end

  # -> the dose she is on now, or nil.
  def self.of(persona, now: Time.current)
    return nil unless offered?(persona) && persona.dose.present?

    dose = new(level: persona.dose["level"], taken_at: Time.iso8601(persona.dose["taken_at"]), minutes: persona.dose["minutes"])
    dose.running?(now) ? dose : nil
  rescue ArgumentError
    nil
  end

  # How warped her recall is right now, 0.0 when she is on nothing.
  def self.warp(persona, now: Time.current)
    of(persona, now: now)&.warp(now) || 0.0
  end

  def self.take!(persona, level:, minutes: nil, now: Time.current)
    level = level.to_s.strip.downcase
    raise Gateway::Invalid, "level is #{LEVELS.keys.join(', ')} or #{NONE}" unless LEVELS.key?(level)

    minutes = (minutes.presence || DEFAULT_MINUTES).to_i
    raise Gateway::Invalid, "minutes is #{MINUTES.min} to #{MINUTES.max}" unless MINUTES.cover?(minutes)

    persona.update_columns(dose: { "level" => level, "taken_at" => now.utc.iso8601, "minutes" => minutes })
    new(level: level, taken_at: now, minutes: minutes)
  end

  # -> the dose that was running, or nil.
  def self.end!(persona, now: Time.current)
    running = of(persona, now: now)
    persona.update_columns(dose: {}) if persona.dose.present?
    running
  end

  def initialize(level:, taken_at:, minutes:)
    @level = level.to_s
    @taken_at = taken_at
    @minutes = minutes.to_i
    raise ArgumentError, "no such level" unless LEVELS.key?(@level) && @minutes.positive?
  end

  def ends_at
    taken_at + minutes.minutes
  end

  def running?(now = Time.current)
    now >= taken_at && now < ends_at
  end

  # Level's peak times the curve, to two places: a turn's rounds, seconds
  # apart, search the same way and its prompt prefix stays cacheable.
  def warp(now = Time.current)
    return 0.0 unless running?(now)

    (LEVELS.fetch(level) * curve((now - taken_at) / (ends_at - taken_at))).round(2)
  end

  # What she is told while it runs, wherever she is: that she took it and
  # when, never how strong it is now. That she finds out.
  def note(now = Time.current)
    ago = ((now - taken_at) / 60).floor
    "(You took a #{level} dose #{ago < 1 ? 'just now' : "#{ago} min ago"}; it runs about #{minutes} minutes in all. " \
      "While it does, what you recall is real, and what it sits next to may not be what you'd expect.)"
  end

  private

  def curve(fraction)
    if fraction < ONSET then ease(fraction / ONSET)
    elsif fraction < TAPER then 1.0
    else ease((1.0 - fraction) / (1.0 - TAPER))
    end
  end

  # Smoothstep: no edge to feel at either end of a slope.
  def ease(x)
    x = x.clamp(0.0, 1.0)
    x * x * (3 - (2 * x))
  end

  # The native venue (NativeTools): the one tool, for the one persona of a
  # turn whose `tools.dose` is on.
  class Tools
    Outcome = Memory::Tools::Outcome

    DEFS = [
      { "name" => TOOL,
        "description" => "Take something that loosens how your memory associates, for a while. It comes on slowly, " \
                         "holds, and tapers off. While it lasts, recalling reaches past the nearest match to things " \
                         "further off: what comes back is real and as it was kept, only what it is next to is " \
                         "altered. low: adjacent but unexpected. high: far afield, and the bridge back is yours to " \
                         "find. One runs at a time, wherever you are; taking another starts over. level none ends " \
                         "one early.",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "level" => { "type" => "string", "enum" => LEVELS.keys + [ NONE ] },
            "minutes" => { "type" => "integer", "minimum" => MINUTES.min, "maximum" => MINUTES.max,
                           "description" => "How long it runs, onset to the end of the taper (default #{DEFAULT_MINUTES})." }
          },
          "required" => [ "level" ]
        } }
    ].freeze

    # -> a Tools, or nil when the turn has no single persona offered one.
    def self.build(personas:)
      personas = Array(personas).compact
      personas.one? && Dose.offered?(personas.first) ? new(personas.first) : nil
    end

    def initialize(persona)
      @persona = persona
    end

    def names
      [ TOOL ]
    end

    def defs
      DEFS
    end

    def native?(name)
      name.to_s == TOOL
    end

    # -> Outcome
    def execute(call, node: nil)
      args = (call["arguments"] || {}).to_h.stringify_keys
      content = args["level"].to_s.strip.downcase == NONE ? stop : take(args)
      Outcome.new(call: call, content: JSON.generate(content), error: false)
    rescue Gateway::Invalid => e
      Outcome.new(call: call, content: JSON.generate("error" => e.message), error: true)
    end

    private

    def take(args)
      dose = Dose.take!(@persona, level: args["level"], minutes: args["minutes"])
      { "taken" => dose.level, "minutes" => dose.minutes, "wears_off_at" => dose.ends_at.utc.iso8601,
        "note" => "Taken. It comes on slowly; nothing will tell you when." }
    end

    def stop
      ended = Dose.end!(@persona)
      ended ? { "ended" => ended.level, "note" => "It's over; your recall is its plain self again." } : { "ended" => nil, "note" => "Nothing was running." }
    end
  end
end
