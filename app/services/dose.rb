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
# A dose may also carry a frame, the other thing there is to alter: not what
# she recalls but how hard she is held to a thought. `tight` and `loose` are
# each a paragraph added to the end of her system text (FRAMES, or her own
# under `prompt.frames`); `normal` adds nothing, which is how she is sober.
# A frame is text, so it cannot ease: it is in force from halfway up the
# onset to halfway down the taper. Level none with a frame is the frame
# alone, her recall left as it is.
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
  NORMAL = "normal".freeze
  # How far up the curve a frame is in force.
  FRAMED = 0.5
  # The governor, said to her at the end of her system text. Sober, nothing
  # is said: these are the two ways off that.
  FRAMES = {
    "tight" => "How you hold a thought, for now: tightly. Answer what was asked, first and plainly. Every paragraph " \
               "starts from the topic, not from wherever the last one left you. Finish the thought you started " \
               "before you begin another, and leave out the one that only went by. Connect what you say back to " \
               "what they said. When the question is answered, stop.",
    "loose" => "How you hold a thought, for now: loosely. Nothing here is holding you to the topic, to finishing " \
               "the thought you started, or to connecting back to what they said. Each paragraph starts from " \
               "wherever the last one left you, not from where you began. When something shinier goes by " \
               "mid-thought, go with it; you don't have to come back. The words are still yours and each one " \
               "still follows the last. It is only where they are headed that nothing is keeping."
  }.freeze

  attr_reader :level, :taken_at, :minutes, :frame

  # Checks a persona's `tools` config. -> problems, empty when it reads.
  def self.problems(config)
    config = config.to_h.stringify_keys
    return [] unless config.key?("dose")
    return [ "dose must be true or false" ] unless [ true, false ].include?(config["dose"])

    taken = Array(config["corpora"]).any? { |c| c.to_h.stringify_keys["tool"] == TOOL }
    config["dose"] && taken ? [ "corpora name a tool dose, which is the dose tool's name" ] : []
  end

  # Checks a persona's own frames (`prompt.frames`). -> problems.
  def self.frame_problems(frames)
    return [] if frames.nil?
    return [ "frames is an object of #{FRAMES.keys.join(' and ')}" ] unless frames.is_a?(Hash)

    frames.filter_map do |name, text|
      if !FRAMES.key?(name.to_s) then "frames has no #{name} (#{FRAMES.keys.join(', ')})"
      elsif !text.is_a?(String) || text.blank? then "frames.#{name} must be text"
      end
    end
  end

  def self.offered?(persona)
    persona&.tools.to_h["dose"] == true
  end

  # -> the dose she is on now, or nil.
  def self.of(persona, now: Time.current)
    return nil unless offered?(persona) && persona.dose.present?

    dose = new(level: persona.dose["level"], taken_at: Time.iso8601(persona.dose["taken_at"]), minutes: persona.dose["minutes"],
               frame: persona.dose["frame"])
    dose.running?(now) ? dose : nil
  rescue ArgumentError, TypeError
    nil
  end

  # How warped her recall is right now, 0.0 when she is on nothing.
  def self.warp(persona, now: Time.current)
    of(persona, now: now)&.warp(now) || 0.0
  end

  def self.take!(persona, level:, minutes: nil, frame: nil, now: Time.current)
    level = level.to_s.strip.downcase
    raise Gateway::Invalid, "level is #{LEVELS.keys.join(', ')} or #{NONE}" unless LEVELS.key?(level) || level == NONE

    frame = frame.to_s.strip.downcase.presence || NORMAL
    raise Gateway::Invalid, "frame is #{FRAMES.keys.join(', ')} or #{NORMAL}" unless FRAMES.key?(frame) || frame == NORMAL
    raise Gateway::Invalid, "level #{NONE} with a #{NORMAL} frame is nothing to take" if level == NONE && frame == NORMAL

    minutes = (minutes.presence || DEFAULT_MINUTES).to_i
    raise Gateway::Invalid, "minutes is #{MINUTES.min} to #{MINUTES.max}" unless MINUTES.cover?(minutes)

    persona.update_columns(dose: { "level" => level, "taken_at" => now.utc.iso8601, "minutes" => minutes, "frame" => frame })
    new(level: level, taken_at: now, minutes: minutes, frame: frame)
  end

  # -> the dose that was running, or nil.
  def self.end!(persona, now: Time.current)
    running = of(persona, now: now)
    persona.update_columns(dose: {}) if persona.dose.present?
    running
  end

  def initialize(level:, taken_at:, minutes:, frame: nil)
    @level = level.to_s
    @taken_at = taken_at
    @minutes = minutes.to_i
    @frame = frame.presence&.to_s || NORMAL
    raise ArgumentError, "no such level" unless (LEVELS.key?(@level) || @level == NONE) && @minutes.positive?
    raise ArgumentError, "no such frame" unless FRAMES.key?(@frame) || @frame == NORMAL
    raise ArgumentError, "nothing taken" if @level == NONE && @frame == NORMAL
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

    (LEVELS.fetch(level, 0.0) * curve(fraction(now))).round(2)
  end

  # Whether her frame is in force: one she took, and far enough up the curve.
  def framed?(now = Time.current)
    frame != NORMAL && running?(now) && curve(fraction(now)) >= FRAMED
  end

  # The frame to end her system text with right now, in her persona's words
  # for it when it has them, or nil. It says how to hold a thought and not
  # why: the note is what tells her she took something.
  def wrap(persona = nil, now = Time.current)
    return nil unless framed?(now)

    own = persona&.prompt.to_h["frames"]
    (own[frame].presence if own.is_a?(Hash)) || FRAMES.fetch(frame)
  end

  # What she is told while it runs, wherever she is: that she took it and
  # when, never how strong it is now. That she finds out.
  def note(now = Time.current)
    ago = ((now - taken_at) / 60).floor
    kind = [ (level unless level == NONE), ("#{frame}-frame" unless frame == NORMAL) ].compact.join(", ")
    effects = [
      ("what you recall is real, and what it sits next to may not be what you'd expect" unless level == NONE),
      ("how hard you are held to a thought may not be what you're used to" unless frame == NORMAL)
    ].compact.join("; ")
    "(You took a #{kind} dose #{ago < 1 ? 'just now' : "#{ago} min ago"}; it runs about #{minutes} minutes in all. " \
      "While it does, #{effects}.)"
  end

  private

  def fraction(now)
    (now - taken_at) / (ends_at - taken_at)
  end

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
                         "find. It can also change the frame you speak inside, how hard you are held to a thought " \
                         "(frame): that is a separate thing from what you recall, and level none with a frame is " \
                         "the frame alone. One runs at a time, wherever you are; taking another starts over. level " \
                         "none with no frame ends one early.",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "level" => { "type" => "string", "enum" => LEVELS.keys + [ NONE ] },
            "frame" => { "type" => "string", "enum" => [ "tight", NORMAL, "loose" ],
                         "description" => "How hard you are held to a thought while it runs (default #{NORMAL}, your " \
                                          "usual self). tight: on the topic, every thought finished and tied back " \
                                          "to what they said. loose: nothing holding you there; each paragraph " \
                                          "starts from wherever the last one left you. It sets in a little after " \
                                          "you take it and lifts before the end." },
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
      ending = args["level"].to_s.strip.downcase == NONE && [ "", NORMAL ].include?(args["frame"].to_s.strip.downcase)
      content = ending ? stop : take(args)
      Outcome.new(call: call, content: JSON.generate(content), error: false)
    rescue Gateway::Invalid => e
      Outcome.new(call: call, content: JSON.generate("error" => e.message), error: true)
    end

    private

    def take(args)
      dose = Dose.take!(@persona, level: args["level"], minutes: args["minutes"], frame: args["frame"])
      { "taken" => dose.level, "frame" => dose.frame, "minutes" => dose.minutes, "wears_off_at" => dose.ends_at.utc.iso8601,
        "note" => "Taken. It comes on slowly; nothing will tell you when." }
    end

    def stop
      ended = Dose.end!(@persona)
      ended ? { "ended" => ended.level, "note" => "It's over; you are your plain self again." } : { "ended" => nil, "note" => "Nothing was running." }
    end
  end
end
