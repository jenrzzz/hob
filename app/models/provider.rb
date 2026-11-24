class Provider < ApplicationRecord
  # elevenlabs is a voice provider (Voice, CASTS.md): it makes audio, never
  # completions, so only the voice-* roles name it.
  KINDS = %w[anthropic openai_compat elevenlabs].freeze

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
