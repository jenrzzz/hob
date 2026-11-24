module Casts
  # How long the quiet between two takes is. (kat's VoicePacer, from the
  # Playhouse and Velvet players, brought over for the seams of a show.)
  #
  # A script's pause conflates two things: the TURN, the moment between one
  # voice and the next in a live exchange, which in real talk is a fifth of
  # a second; and the BEAT, a silence the script means (a punchline landing,
  # a heavy story sinking in). Give every seam the same pause and an
  # exchange limps. So a turn gets a natural gap, shorter when a different
  # voice answers than when the same one carries on, with a little jitter so
  # a run of them doesn't tick; and a beat is held.
  #
  # Inside one dialogue take the provider's model does its own turn-taking;
  # this times what hob joins: take to take. With `voicing: lines` every
  # line is its own take, and this is the whole of the show's rhythm.
  class Pacer
    TURN = 0.22
    SAME_SPEAKER = 0.45
    JITTER = 0.08
    BEAT = 0.95
    FLOOR = 0.05

    # seed: anything stable for the episode, so a remix lands the same.
    def initialize(seed = 0)
      @random = Random.new(seed.to_s.sum)
    end

    def gap(previous_speaker, next_speaker, beat: false)
      return BEAT if beat

      base = previous_speaker == next_speaker ? SAME_SPEAKER : TURN
      [ FLOOR, base + (@random.rand * 2 - 1) * JITTER ].max.round(3)
    end
  end
end
