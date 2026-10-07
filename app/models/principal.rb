class Principal < ApplicationRecord
  # agent: an external AI (SENTINEL.md) — its keys can only act through the
  # sentinel, never call the model-facing endpoints directly.
  KINDS = %w[human persona worker surface agent].freeze

  has_many :api_keys, dependent: :destroy
  has_many :devices, dependent: :destroy
  has_many :sentinel_policies, dependent: :destroy
  has_many :sentinel_requests, dependent: :restrict_with_exception
  has_many :authorization_claims, dependent: :restrict_with_exception
  has_many :petitions, dependent: :restrict_with_exception
  has_many :missions, foreign_key: :assignee_id, inverse_of: :assignee, dependent: :restrict_with_exception
  has_many :sent_agent_messages, class_name: "AgentMessage", foreign_key: :sender_id, inverse_of: :sender,
                                 dependent: :restrict_with_exception
  has_many :received_agent_messages, class_name: "AgentMessage", foreign_key: :recipient_id, inverse_of: :recipient,
                                     dependent: :restrict_with_exception

  validates :kind, inclusion: { in: KINDS }
  validates :name, presence: true, uniqueness: true
  validates :max_clearance, presence: true
  # Where this principal hears about its missions: an ntfy topic URL (see
  # Notify). Blank means nobody is told; the principal finds out by polling.
  validates :channel, format: { with: %r{\Ahttps?://\S+\z}, message: "must be an http(s) URL" }, allow_blank: true
  normalizes :channel, with: ->(url) { url.to_s.strip.presence }
  # Who this is at the household's OIDC provider (the id token's `sub`), so a
  # person can sign in to the admin pages. Set with `hob:link`.
  validates :oidc_subject, uniqueness: true, allow_nil: true
  normalizes :oidc_subject, with: ->(sub) { sub.to_s.strip.presence }

  scope :agents, -> { where(kind: "agent") }

  def agent?
    kind == "agent"
  end

  # Who may decide sentinel requests and manage policies: people, not the
  # agents being gated and not the surfaces the agents act through.
  def trusted?
    kind == "human"
  end

  # Trust consequences of a failed spot-check (SENTINEL.md, "User-
  # authorization claims"): every one of this agent's requests is denied at
  # the gate until a person reviews the incident and clears it. Named apart
  # from Ruby's own freeze/frozen? (ActiveRecord relies on those for record
  # mutability) so this never collides with them.
  def capabilities_frozen?
    capabilities_frozen_at.present?
  end

  def freeze_capabilities!(reason:)
    update!(capabilities_frozen_at: Time.current, capabilities_freeze_reason: reason.to_s.truncate(2000))
  end

  def unfreeze_capabilities!
    update!(capabilities_frozen_at: nil, capabilities_freeze_reason: nil)
  end

  # The next `count` claim-backed requests are spot-checked regardless of
  # the random rate, after a claim failed its rubric or its spot-check
  # (Sentinel::Claims). Never lowers what is already owed. Both are single
  # UPDATEs, so concurrent requests can't read the same count and write
  # back a stale one.
  def start_claim_scrutiny!(count)
    self.class.where(id: id).update_all([ "claim_scrutiny_remaining = GREATEST(claim_scrutiny_remaining, ?)", count ])
    self.claim_scrutiny_remaining = self.class.where(id: id).pick(:claim_scrutiny_remaining)
    clear_attribute_change(:claim_scrutiny_remaining)
  end

  # Spends one owed check. -> true if one was owed (and is now spent).
  def consume_claim_scrutiny!
    spent = self.class.where(id: id).where("claim_scrutiny_remaining > 0")
                .update_all("claim_scrutiny_remaining = claim_scrutiny_remaining - 1")
    self.claim_scrutiny_remaining = self.class.where(id: id).pick(:claim_scrutiny_remaining)
    clear_attribute_change(:claim_scrutiny_remaining)
    spent.positive?
  end
end
