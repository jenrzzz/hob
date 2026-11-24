module Casts
  # Where every clip sits in the episode: pure arithmetic over durations, so
  # the shape of a show can be read (and tested) without making a sound.
  #
  #   cold open ─ theme, alone ─ theme ducks under the welcome and fades ─
  #   segment ─ sting ─ segment ─ sting ─ ... ─ sign-off over the theme's
  #   last stretch, which swells when they stop and plays out to its ending
  #
  # In:  parts  [{ "kind" => cold_open|segment|sign_off, "takes" => [{ clip:, duration:, first:, last:, beat: }] }]
  #      theme  { clip:, duration: } or nil; stingers [{ clip:, duration: }]
  # Out: { placements: [{ clip:, bus: :voice|:bed, at:, offset:, length:, envelope: [[t, gain], ...] }], duration: }
  #      An envelope is the clip's gain over its own time, straight lines between points.
  class Timeline
    LEAD_IN = 0.3
    TAIL = 0.4
    THEME_FULL = 0.8
    THEME_BED = 0.13
    INTRO_SOLO = 6.0        # the theme alone, before anyone speaks
    INTRO_BED = 12.0        # then under the welcome for this long
    INTRO_FADE = 4.0
    DUCK = 1.2              # how long a swell or a duck takes
    OUTRO_LEAD = 1.0        # the theme arrives this long before the sign-off
    OUTRO_FULL = 6.0        # and plays this long after it, before fading
    OUTRO_FADE = 3.5
    STING_GAIN = 0.55
    STING_BEFORE = 0.35     # quiet after a segment, before its sting
    STING_OVERLAP = 0.15    # the next segment starts this much before the sting has rung out
    BARE_GAP = 0.9          # between segments when there is no sting

    def initialize(parts:, theme: nil, stingers: [], pacer: Pacer.new)
      @parts = parts
      @theme = theme
      @stingers = Array(stingers)
      @pacer = pacer
      @placements = []
    end

    def call
      t = LEAD_IN
      cold = @parts.find { |p| p["kind"] == "cold_open" }
      segments = @parts.select { |p| p["kind"] == "segment" }
      sign_off = @parts.find { |p| p["kind"] == "sign_off" }

      t = say(cold, t) if cold
      t = intro(t, cold.present?)
      segments.each_with_index do |segment, i|
        t = sting(t, i - 1) if i.positive?
        t = say(segment, t)
      end
      t = outro(sign_off, t)

      { placements: @placements.sort_by { |p| p[:at] }, duration: (t + TAIL).round(3) }
    end

    private

    # A part's takes, one after another with the pacer's quiet between.
    def say(part, t)
      previous = nil
      part["takes"].each do |take|
        t += @pacer.gap(previous[:last], take[:first], beat: previous[:beat]) if previous
        @placements << { clip: take[:clip], bus: :voice, at: t.round(3), offset: 0.0, length: take[:duration],
                         envelope: [ [ 0.0, 1.0 ] ] }
        t += take[:duration]
        previous = take
      end
      t
    end

    # The theme: alone, then ducked under the first segment, then gone.
    def intro(t, after_cold_open)
      return t + (after_cold_open ? 0.6 : 0.0) unless @theme

      at = after_cold_open ? t + 0.25 : 0.0
      solo = [ INTRO_SOLO, @theme[:duration] * 0.4 ].min
      length = [ @theme[:duration], solo + INTRO_BED + INTRO_FADE ].min
      fade_from = [ length - INTRO_FADE, solo + DUCK ].max
      @placements << { clip: @theme[:clip], bus: :bed, at: at.round(3), offset: 0.0, length: length.round(3),
                       envelope: [ [ 0.0, THEME_FULL ], [ solo - DUCK / 2, THEME_FULL ], [ solo + DUCK / 2, THEME_BED ],
                                   [ fade_from, THEME_BED ], [ length, 0.0 ] ] }
      at + solo
    end

    def sting(t, index)
      return t + BARE_GAP if @stingers.empty?

      sting = @stingers[index % @stingers.size]
      at = t + STING_BEFORE
      @placements << { clip: sting[:clip], bus: :bed, at: at.round(3), offset: 0.0, length: sting[:duration],
                       envelope: [ [ 0.0, STING_GAIN ] ] }
      at + [ sting[:duration] - STING_OVERLAP, 0.2 ].max
    end

    # The sign-off over the theme's last stretch: the music is cut so its
    # own ending is the episode's, rather than faded out from the middle.
    def outro(sign_off, t)
      t += 0.5
      return (sign_off ? say(sign_off, t) : t) unless @theme

      start = t
      spoken_from = start + (sign_off ? OUTRO_LEAD : 0.0)
      spoken_to = sign_off ? say(sign_off, spoken_from) : spoken_from
      under = spoken_to - start
      wanted = under + DUCK + OUTRO_FULL + OUTRO_FADE
      length = [ wanted, @theme[:duration] ].min
      # A theme shorter than the sign-off comes in late rather than running out.
      start += wanted - length
      under -= wanted - length
      under = [ under, 0.0 ].max
      rise = [ OUTRO_LEAD, under ].min
      @placements << { clip: @theme[:clip], bus: :bed, at: start.round(3), offset: (@theme[:duration] - length).round(3),
                       length: length.round(3),
                       envelope: [ [ 0.0, sign_off ? 0.0 : THEME_FULL ], [ rise, sign_off ? THEME_BED : THEME_FULL ],
                                   [ under, sign_off ? THEME_BED : THEME_FULL ], [ under + DUCK, THEME_FULL ],
                                   [ length - OUTRO_FADE, THEME_FULL ], [ length, 0.0 ] ] }
      start + length
    end
  end
end
