class Principal < ApplicationRecord
  # agent: an external AI (SENTINEL.md) — its keys can only act through the
  # sentinel, never call the model-facing endpoints directly.
  KINDS = %w[human persona worker surface agent].freeze

  has_many :api_keys, dependent: :destroy
  has_many :sentinel_policies, dependent: :destroy
  has_many :sentinel_requests, dependent: :restrict_with_exception
  has_many :missions, foreign_key: :assignee_id, inverse_of: :assignee, dependent: :restrict_with_exception

  validates :kind, inclusion: { in: KINDS }
  validates :name, presence: true, uniqueness: true
  validates :max_clearance, presence: true

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
