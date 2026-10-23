# What version of a component an asset was seen running, by whom, and over
# what span (THREATS.md). Coolify's inventory writes them on every sync;
# the ward worker and people post probes. A resolution points at these.
class WardObservation < ApplicationRecord
  SOURCES = %w[coolify probe person].freeze

  belongs_to :asset, class_name: "WardAsset", inverse_of: :observations
  belongs_to :principal, optional: true

  validates :component, presence: true
  validates :source, inclusion: { in: SOURCES }

  before_create { self.id ||= ULID.generate }

  def as_json_for_ward
    {
      "id" => id, "asset" => asset.name, "component" => component, "version" => version, "digest" => digest,
      "source" => source, "by" => principal&.name, "started_at" => started_at&.utc&.iso8601,
      "first_seen_at" => first_seen_at.utc.iso8601, "last_seen_at" => last_seen_at.utc.iso8601
    }.compact
  end
end
