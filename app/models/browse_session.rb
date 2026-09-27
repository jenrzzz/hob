# A tab an agent (or a person) has open in one of the household's browsers
# (BROWSE.md), for a stated goal. The row is what binds every later step to
# the goal that was judged when the session opened: browse.act needs a
# session, a session comes only from browse.open, and browse.open is where
# policy looks at what the visit is for. The row is also the record of the
# visit: where it went, how many steps, how it ended.
#
# The page itself is never stored here; the backend (gofer) holds the tab
# and hob asks it afresh each step. `remote_id` is the backend's name for it.
class BrowseSession < ApplicationRecord
  STATUSES = %w[open closed expired lost].freeze
  MAX_STEPS = 300

  belongs_to :browser
  belongs_to :principal

  validates :goal, presence: true
  validates :remote_id, presence: true
  validates :status, inclusion: { in: STATUSES }

  before_create { self.id ||= ULID.generate }

  scope :open, -> { where(status: "open") }
  scope :owned_by, ->(principal) { where(principal: principal) }

  def open?
    status == "open"
  end

  # Steps hob has seen on this session; the backend counts its own.
  def step!(state)
    update!(steps: steps + 1, url: state["url"].to_s.truncate(255), title: state["title"].to_s.truncate(255), last_step_at: Time.current)
  end

  def seen!(state)
    update!(url: state["url"].to_s.truncate(255), title: state["title"].to_s.truncate(255))
  end

  def close!(status, reason = nil)
    update!(status: status, close_reason: reason, closed_at: Time.current) if open?
  end

  def as_json(*)
    { "id" => id, "browser" => browser.name, "goal" => goal, "domains" => domains, "status" => status,
      "steps" => steps, "url" => url, "title" => title, "opened_by" => principal.name,
      "close_reason" => close_reason, "on_mission" => on_mission_id,
      "created_at" => created_at, "last_step_at" => last_step_at, "closed_at" => closed_at }
  end
end
