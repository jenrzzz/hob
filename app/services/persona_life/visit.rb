class PersonaLife
  # How a persona is on IRC (IRC.md, "A visit"). `life.irc`:
  #
  #   { "lines" => 3,        the most lines a woken beat may say; each draws its own, 1 to this
  #     "sheet" => "...",    her habits there, in her page: how she types, what she goes on
  #                          about, who she likes and who she needles
  #     "stances" => [...] } how a visit may go, one drawn per woken beat (default STANCES)
  #
  # Absent, nothing changes. With it, a beat woken by a name is a visit: a
  # stance drawn at random and a few lines, which Irc.say holds her to
  # (Current.irc_lines). A roomful who each answer everyone who named them,
  # a finished sentence apiece, is a seminar and not a channel (#upstairs,
  # 2026-11-24); what makes a channel is that people drop in differently
  # each time. Hosting (Irc::Pulse) has no stance and HOSTING_LINES.
  class Visit
    DEFAULT_LINES = 3
    LINES = 1..10
    HOSTING_LINES = 6
    SHEET_MAX = 2_400
    STANCES_MAX = 24
    STANCE_MAX = 400

    STANCES = [
      "React and go. A few words to one thing that was said, the way you would with half your attention on something else.",
      "Push back. Somebody up there said something you don't buy, or liked something you don't. Say so plainly and " \
        "don't soften it; you do not have to make up afterwards.",
      "Talk to someone who did not name you. Let the ones who did wait.",
      "Bring up what you were doing before you came up: something from your own day, nothing to do with what the room is on.",
      "One /me and nothing else (irc_say with action: true).",
      "Ask one person one real question, the kind you actually want the answer to, and leave it there.",
      "Lurk. Read, and say nothing unless a line made you laugh or got on your nerves; then only that.",
      "You have had enough of this subject. Say what you would rather talk about, and start.",
      "Answer the one who named you last, and only that one, as briefly as you would between other things.",
      "Tease someone about something they said a while back, not the last thing.",
      "One of them asked you something real. Answer it properly, to them, and skip the rest.",
      "You only half followed what they were on about. Say so, or get it a little wrong; nobody reads the whole scrollback."
    ].freeze

    # What a beat may still say on IRC: Irc.say counts it down.
    Allowance = Struct.new(:left)

    def self.problems(config)
      return [] if config.nil?
      return [ "life.irc is { lines, sheet, stances }" ] unless config.is_a?(Hash)

      config = config.stringify_keys
      problems = []
      unknown = config.keys - %w[lines sheet stances]
      problems << "life.irc has unknown keys: #{unknown.join(', ')}" if unknown.any?
      lines = config["lines"]
      unless lines.nil? || (lines.is_a?(Integer) && LINES.cover?(lines))
        problems << "life.irc.lines is a whole number from #{LINES.first} to #{LINES.last}"
      end
      sheet = config["sheet"]
      unless sheet.nil? || (sheet.is_a?(String) && sheet.length <= SHEET_MAX)
        problems << "life.irc.sheet is text of at most #{SHEET_MAX} characters"
      end
      stances = config["stances"]
      unless stances.nil? || (stances.is_a?(Array) && stances.size.between?(1, STANCES_MAX) &&
                              stances.all? { |s| s.is_a?(String) && s.present? && s.length <= STANCE_MAX })
        problems << "life.irc.stances is a list of 1 to #{STANCES_MAX} lines of at most #{STANCE_MAX} characters"
      end
      problems
    end

    # `wake`: the beat's (Beat#initialize); nil on her own clock.
    def initialize(life, wake:, rng:)
      @config = life.config["irc"]
      @wake = wake
      @rng = rng
    end

    def on?
      @config.is_a?(Hash)
    end

    def sheet
      @config["sheet"].presence if on?
    end

    def hosting?
      @wake&.key?(:pulse) || false
    end

    # A visit: woken by a name, not to host.
    def visit?
      on? && @wake.present? && !hosting?
    end

    # How many lines this beat may say on IRC; nil is no limit of hers.
    def lines
      return @lines if defined?(@lines)

      @lines = if !on? || @wake.nil? then nil
      elsif hosting? then HOSTING_LINES
      else 1 + @rng.rand((@config["lines"] || DEFAULT_LINES).to_i)
      end
    end

    def stance
      return @stance if defined?(@stance)

      @stance = visit? ? (@config["stances"].presence || STANCES).sample(random: @rng) : nil
    end

    def allowance
      lines && Allowance.new(lines)
    end
  end
end
