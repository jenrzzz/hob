class Principal < ApplicationRecord
  # agent: an external AI (SENTINEL.md) — its keys can only act through the
  # sentinel, never call the model-facing endpoints directly.
  KINDS = %w[human persona worker surface agent].freeze

  has_many :api_keys, dependent: :destroy
  has_many :devices, dependent: :destroy
  has_many :sentinel_policies, dependent: :destroy
  has_many :sentinel_requests, dependent: :restrict_with_exception
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

  scope :agents, -> { where(kind: "agent") }

  def agent?
    kind == "agent"
  end

  # Who may decide sentinel requests and manage policies: people, not the
  # agents being gated and not the surfaces the agents act through.
  def trusted?
    kind == "human"
  end
end
