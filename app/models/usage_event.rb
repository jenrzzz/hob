# The ledger. One row per gateway attempt — success, refusal, rate limit, or
# error — so "what did this cost" and "what failed" are the same table.
class UsageEvent < ApplicationRecord
  STATUSES = %w[success refused rate_limited error].freeze

  belongs_to :principal, optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :successful, -> { where(status: "success") }
  scope :since, ->(time) { time ? where(created_at: time..) : all }

  # The ledger must never be able to break the feature it's metering.
  # Cost is derived from model_prices when not given.
  def self.record(**attrs)
    attrs[:cost] = ModelPrice.cost_for(model: attrs[:model], units: attrs[:units] || {}) unless attrs.key?(:cost)
    create!(created_at: Time.current, **attrs)
  rescue StandardError => e
    Rails.logger.warn("usage ledger write failed: #{e.class}: #{e.message}")
    nil
  end

  # Aggregate a scope into the shape GET /v1/usage returns.
  def self.summarize(scope)
    rows = scope.to_a
    sum = ->(key) { rows.sum { |r| r.units[key].to_i } }
    {
      calls: rows.size,
      by_status: rows.group_by(&:status).transform_values(&:size),
      input_tokens: sum.("input_tokens"),
      output_tokens: sum.("output_tokens"),
      cache_read_tokens: sum.("cache_read_tokens"),
      cost: rows.sum { |r| r.cost.to_d }.to_f.round(6),
      priced: rows.all? { |r| r.cost.present? || r.status != "success" }
    }
  end
end
