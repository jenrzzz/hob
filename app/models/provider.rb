class Provider < ApplicationRecord
  KINDS = %w[anthropic openai_compat].freeze

  validates :slug, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }

  # config keys: api_key_env (name of the env var, never the secret itself),
  # base_url (openai_compat only)
  def api_key
    ENV[config["api_key_env"].to_s].presence
  end

  def available?
    api_key.present?
  end
end
