class PersonaLife
  # Reads the recent diary for a groove: the things that keep coming back
  # and the phrases reused verbatim. Used twice per life turn: to tell the
  # model what is worn out before it writes, and to refuse a first draft
  # that falls back in. Mechanical on purpose: "don't repeat the diary" in a
  # prompt loses to the diary sitting right there as examples; counting
  # does not. (Ported from kat's DiaryRut.)
  class Rut
    WINDOW = 12        # entries looked back over
    WORN_MIN = 3       # a thing is worn once it's in this many entries...
    WORN_SHARE = 0.3   # ...and at least this share of the window
    WORN_LIST_MAX = 14 # how many worn things the prompt names
    ECHO_WORDS = 3     # a draft leaning on this many worn things is an echo
    SHINGLE = 4        # a run of this many words lifted from the window is too

    CLOCK_OPENER = /\A\W*\d{1,2}(:\d{2})?\s*(am|pm)\b/i

    STOPWORDS = %w[
      the and but for nor yet not that this these those with from into onto over under about
      after before then than there here when where while what which who whom whose why how
      was were are been being have has had does did doing done will would could should can
      may might must shall its it's i'm i've i'll i'd he's she's they're we're you're that's
      there's don't didn't doesn't isn't wasn't won't can't couldn't haven't hasn't
      him her his hers she they them their our your you mine me my we us
      just still also even only very really some any all both each every more most much many
      one two three four five six seven eight nine ten now today tonight again back out off
      like got get gets getting went going goes made make makes thing things something nothing
      anything everything someone anyone because through until since same other another
      monday tuesday wednesday thursday friday saturday sunday
    ].to_set.freeze

    # entries: oldest first
    def initialize(entries)
      @entries = Array(entries).last(WINDOW).map(&:to_s)
    end

    # The worn-out things, most worn first, as they were actually written.
    def worn
      worn_stems.first(WORN_LIST_MAX).map { |stem| surface[stem] }
    end

    # Why a draft is an echo of the window, or nil when it's a fresh beat.
    def echo(candidate)
      text = candidate.to_s
      return "opens on the clock (the time is stamped for you; start with what happened)" if text.match?(CLOCK_OPENER)

      if (phrase = lifted_phrase(text))
        return "reuses \"#{phrase}\" from an earlier entry"
      end

      leaned = (stems_of(text).uniq & worn_stems).map { |stem| surface[stem] }
      return "is about #{leaned.first(5).join(', ')} again" if leaned.size >= ECHO_WORDS

      nil
    end

    private

    attr_reader :entries

    def worn_stems
      @worn_stems ||= begin
        floor = [ WORN_MIN, (entries.size * WORN_SHARE).ceil ].max
        document_frequency.select { |_, n| n >= floor }.sort_by { |stem, n| [ -n, stem ] }.map(&:first)
      end
    end

    def document_frequency
      @document_frequency ||= entries.each_with_object(Hash.new(0)) do |entry, counts|
        stems_of(entry).uniq.each { |stem| counts[stem] += 1 }
      end
    end

    # stem => the spelling used most, so the prompt names real words.
    def surface
      @surface ||= begin
        forms = Hash.new { |h, k| h[k] = Hash.new(0) }
        entries.each { |entry| content_words(entry).each { |word| forms[stem(word)][word] += 1 } }
        forms.transform_values { |counts| counts.max_by { |word, n| [ n, -word.length ] }.first }
      end
    end

    def lifted_phrase(text)
      shingles_of(text).find { |shingle| window_shingles.include?(shingle) }
    end

    def window_shingles
      @window_shingles ||= entries.flat_map { |entry| shingles_of(entry) }.to_set
    end

    def shingles_of(text)
      tokens(text).each_cons(SHINGLE).map { |run| run.join(" ") }
    end

    def stems_of(text)
      content_words(text).map { |word| stem(word) }
    end

    def content_words(text)
      tokens(text).reject { |word| word.length < 3 || STOPWORDS.include?(word) }
    end

    def tokens(text)
      text.downcase.scan(/[a-z][a-z']*/)
    end

    # Crude on purpose: folds watch/watches/watching together without a
    # stemmer dependency.
    def stem(word)
      word = word.delete_suffix("'s")
      word.length > 4 ? word.sub(/(ing|ed|es|s)\z/, "") : word
    end
  end
end
