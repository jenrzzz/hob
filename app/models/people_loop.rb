# Something still open with a person (PEOPLE.md): a reach-out not answered, a
# reply or a favor owed, an answer awaited. Written only by People::Loops,
# from events: it opens on one, the latest that kept it open is
# `latest_event`, and it closes on one. Its age runs from `opened_at`, the
# first event of the silence. A person's snooze (`snoozed_until`) hides it
# from default reads for a while; a dismissal closes it as a false positive,
# with an event saying so.
class PeopleLoop < ApplicationRecord
  KINDS = %w[unanswered_inbound owed_reply owed_action awaiting_them].freeze
  STATES = %w[open closed dismissed].freeze

  belongs_to :person, optional: true
  belongs_to :group, class_name: "PeopleGroup", optional: true
  belongs_to :principal, optional: true
  belongs_to :opened_by, class_name: "PeopleEvent"
  belongs_to :latest_event, class_name: "PeopleEvent"
  belongs_to :closed_by, class_name: "PeopleEvent", optional: true
  belongs_to :handle, class_name: "PersonHandle", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :state, inclusion: { in: STATES }
  validates :realm, :opened_at, presence: true

  before_create { self.id ||= ULID.generate }

  scope :outstanding, -> { where(state: "open") }

  def snoozed?(now = Time.current)
    state == "open" && snoozed_until.present? && snoozed_until > now
  end

  # What a read calls it: open, snoozed, closed, or dismissed.
  def shown_state(now = Time.current)
    snoozed?(now) ? "snoozed" : state
  end

  def age_days(now = Time.current)
    ((now - opened_at) / 1.day).floor
  end

  def as_json(*)
    now = Time.current
    { "id" => id, "person" => person && { "id" => person.id, "display_name" => person.display_name },
      "group" => group && { "id" => group.id, "name" => group.name }, "kind" => kind, "channel" => channel,
      "summary" => summary, "state" => shown_state(now), "opened_at" => opened_at.utc.iso8601, "age_days" => age_days(now),
      "opened_by" => opened_by_id, "latest_event" => latest_event_id, "closed_by" => closed_by_id,
      "closed_at" => closed_at&.utc&.iso8601, "snoozed_until" => snoozed_until&.utc&.iso8601, "whose" => principal&.name,
      "realm" => realm }.compact
  end
end
