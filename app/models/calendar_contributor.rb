# Who may push events for whom (SENTINEL.md, hob.calendar.push): a small
# owner -> allowed-agents registry. hob.calendar.push refuses to write
# anything for an owner unless the pushing agent has a row here. A person
# adds and removes rows; nothing an agent does grants it one.
class CalendarContributor < ApplicationRecord
  belongs_to :owner, class_name: "Principal"
  belongs_to :agent, class_name: "Principal"

  validates :agent_id, uniqueness: { scope: :owner_id }
  validate :owner_is_a_person
  validate :agent_is_an_agent

  private

  def owner_is_a_person
    errors.add(:owner, "must be a household member") if owner && !owner.trusted?
  end

  def agent_is_an_agent
    errors.add(:agent, "must be an agent") if agent && !agent.agent?
  end
end
