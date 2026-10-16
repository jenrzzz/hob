module People
  # How often the household and a person are usually in touch, and whether
  # it has gone quiet (PEOPLE.md, use case 4). Judged against the
  # relationship's own rhythm, never a global timer: the median gap between
  # days with a 1:1 contact, over the last CONTACT_DAYS of them, unless a
  # person said how often to expect contact (`cadence_days`), which wins.
  #
  # Quiet is longer than twice the expected gap since the last contact, and
  # at least MIN_QUIET_DAYS. Without a rhythm (fewer than MIN_GAPS gaps and
  # no cadence_days) nothing is ever quiet: a guess that fires wrongly
  # teaches people to ignore all of them.
  #
  # Only what the caller can see counts, since the events are read through
  # RLS; group messages and notes are not contact.
  module Cadence
    CONTACT_DAYS = 30
    MIN_GAPS = 2
    MIN_QUIET_DAYS = 3
    FACTOR = 2

    Reading = Struct.new(:last_inbound_at, :last_outbound_at, :last_contact_at, :usual_gap_days, :expected_days,
                         :days_since, :quiet, keyword_init: true) do
      def as_json(*)
        { "last_inbound_at" => last_inbound_at&.utc&.iso8601, "last_outbound_at" => last_outbound_at&.utc&.iso8601,
          "last_contact_at" => last_contact_at&.utc&.iso8601, "usual_gap_days" => usual_gap_days,
          "expected_days" => expected_days, "days_since_contact" => days_since, "quiet" => quiet }
      end
    end

    module_function

    # One person's reading. `events` may be given (already loaded, newest
    # first) to spare a query.
    def read(person, now: Time.current, events: nil)
      events ||= contact(person.identity_ids).order(at: :desc).limit(500).to_a
      return Reading.new(expected_days: person.cadence_days, quiet: false) if events.empty?

      last_in = events.find { |e| e.direction == "inbound" }&.at
      last_out = events.find { |e| e.direction != "inbound" }&.at
      last = events.first.at
      days = events.map { |e| e.at.in_time_zone(Texts.zone).to_date }.uniq.first(CONTACT_DAYS)
      gaps = days.each_cons(2).map { |newer, older| (newer - older).to_i }
      usual = gaps.size >= MIN_GAPS ? median(gaps) : nil
      expected = person.cadence_days || usual
      since = ((now - last) / 1.day).floor
      quiet = expected.present? && since >= MIN_QUIET_DAYS && since > FACTOR * expected
      Reading.new(last_inbound_at: last_in, last_outbound_at: last_out, last_contact_at: last, usual_gap_days: usual,
                  expected_days: expected, days_since: since, quiet: quiet)
    end

    # 1:1 interactions with these people.
    def contact(person_ids)
      PeopleEvent.interactions.where(person_id: person_ids, group_id: nil)
    end

    def median(values)
      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round
    end
  end
end
