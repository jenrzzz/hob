# One entry in a threat's append-only history (THREATS.md): reported,
# merged, triaged, a transition, a posture action, a note, an indicator, a
# resolution pass, a proposal and its decision. Never edited.
class WardThreatEvent < ApplicationRecord
  KINDS = %w[reported merged triaged transition posture note indicator pass proposal decision enrichment upstream review].freeze

  belongs_to :threat, class_name: "WardThreat", inverse_of: :events
  belongs_to :principal, optional: true

  validates :kind, inclusion: { in: KINDS }

  before_create { self.id ||= ULID.generate }
  before_update { raise ActiveRecord::ReadOnlyRecord, "threat history is append-only" }

  def as_json_for_ward
    {
      "id" => id, "kind" => kind, "at" => created_at.utc.iso8601, "by" => principal&.name || "ward",
      "from" => from_status, "to" => to_status, "body" => body, "data" => data.presence
    }.compact
  end
end
