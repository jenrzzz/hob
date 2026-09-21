# hob's household calendar mirror (SENTINEL.md, hob.calendar.push): one row
# per event an agent has pushed for a household member's calendar, keyed by
# (source_agent, owner, calendar, uid). title and location are only ever
# written when the push's visibility was "details"; a free_busy push clears
# them on the way in, even if a prior "details" push had set them. Holds no
# provider credentials and is reached by no read path yet.
class CalendarEvent < ApplicationRecord
  VISIBILITIES = %w[free_busy details].freeze

  belongs_to :source_agent, class_name: "Principal"
  belongs_to :owner, class_name: "Principal"

  before_create { self.id ||= ULID.generate }

  validates :uid, presence: true
  validates :start_at, presence: true
  validates :end_at, presence: true
  validates :visibility, inclusion: { in: VISIBILITIES }
  validate :owner_is_a_person
  validate :source_agent_is_an_agent

  private

  def owner_is_a_person
    errors.add(:owner, "must be a household member") if owner && !owner.trusted?
  end

  def source_agent_is_an_agent
    errors.add(:source_agent, "must be an agent") if source_agent && !source_agent.agent?
  end
end
