class UsageEvent < ApplicationRecord
  belongs_to :principal, optional: true

  # The ledger must never be able to break the feature it's metering.
  def self.record(**attrs)
    create!(created_at: Time.current, **attrs)
  rescue StandardError => e
    Rails.logger.warn("usage ledger write failed: #{e.message}")
    nil
  end
end
