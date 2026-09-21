# Free text a person attaches to a subject the ward reports on (WARD.md): a
# host, a Coolify resource, a check. The reviewed decisions of SECURITY.md
# in a form the triage reads back when that subject comes up again.
class WardNote < ApplicationRecord
  belongs_to :author, class_name: "Principal", optional: true

  validates :subject, :body, presence: true
  normalizes :subject, with: ->(s) { s.to_s.strip }

  before_create { self.id ||= ULID.generate }

  scope :recent, -> { order(created_at: :desc) }
  scope :about, ->(subjects) { where(subject: Array(subjects)) }

  def as_json_for_ward
    { "id" => id, "subject" => subject, "body" => body, "author" => author&.name, "created_at" => created_at.utc.iso8601 }
  end
end
