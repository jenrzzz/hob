# The ledger. One row per gateway attempt — success, refusal, an empty
# reply, rate limit, or error — so "what did this cost" and "what failed"
# are the same table. `empty` is a normal stop with nothing said
# (Gateway::Response#empty?), kept apart from a refusal.
class UsageEvent < ApplicationRecord
  STATUSES = %w[success refused empty rate_limited error].freeze

  belongs_to :principal, optional: true
  # Realm-scoped (RLS): nil when the reader's clearance is below the call's.
  has_one :payload, class_name: "UsagePayload", dependent: nil

  validates :status, inclusion: { in: STATUSES }

  scope :successful, -> { where(status: "success") }
  scope :failed, -> { where(status: %w[error rate_limited]) }
  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :since, ->(time) { time ? where(created_at: time..) : all }

  # The ledger must never be able to break the feature it's metering.
  # Cost is derived from model_prices when not given.
  #
  # payload: { request:, response: } — what the call said, stored at `realm`
  # (UsagePayload). Losing it loses the audit trail, not the row.
  def self.record(payload: nil, **attrs)
    event = guarded("usage ledger write") do
      attrs[:cost] = ModelPrice.cost_for(model: attrs[:model], units: attrs[:units] || {}) unless attrs.key?(:cost)
      create!(created_at: Time.current, **attrs)
    end
    event&.attach_payload(**payload) if payload&.values&.any?
    event
  end

  # A savepoint, so a failed write (an RLS check, a bad value) can't poison
  # a transaction the caller happens to be in.
  def self.guarded(what)
    transaction(requires_new: true) { yield }
  rescue StandardError => e
    Rails.logger.warn("#{what} failed: #{e.class}: #{e.message}")
    Rails.error.report(e, handled: true, severity: :error, source: "hob.ledger")
    nil
  end

  def attach_payload(request: nil, response: nil)
    self.class.guarded("usage payload write") do
      UsagePayload.create!(usage_event: self, realm: realm.presence || self.class.content_realm,
                           request: request, response: response, created_at: created_at)
    end
  end

  # The realm a call's content belongs to when the caller didn't say: the
  # clearance it ran at (it could have seen nothing higher), else the most
  # restrictive realm there is.
  def self.content_realm
    Clearance.current.presence || Realm.order(rank: :desc).pick(:slug)
  end

  def tokens
    %w[input_tokens output_tokens].sum { |k| units.to_h[k].to_i }
  end

  def conversation_id
    ref.to_s[%r{\Aconversation/(.+)\z}, 1] || metadata.to_h["conversation"].presence
  end

  def failed? = %w[error rate_limited].include?(status)

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
