class Provider < ApplicationRecord
  # elevenlabs is a voice provider (Voice, CASTS.md): it makes audio, never
  # completions, so only the voice-* roles name it.
  # gemini is Google's own API (generateContent), not its OpenAI-compatible
  # endpoint, so thought signatures and finish reasons come back intact.
  KINDS = %w[anthropic openai_compat gemini elevenlabs].freeze

  validates :slug, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }

  # config keys: api_key_env (name of the env var, never the secret itself),
  # base_url (openai_compat; on gemini, Vertex AI's publisher endpoint
  # instead of the Gemini Developer API)
  def api_key
    ENV[config["api_key_env"].to_s].presence
  end

  def available?
    api_key.present?
  end
end
