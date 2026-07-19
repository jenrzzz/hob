# The gateway plane: surfaces ask for a model *role*; hob resolves it through
# the role's fallback chain to a concrete provider+model and meters the call.
# ruby_llm is the provider abstraction underneath (same layer mise uses today).
module Gateway
  Error = Class.new(StandardError)
  NoProviderError = Class.new(Error)
  UnknownRoleError = Class.new(Error)

  # -> [RubyLLM::Chat, ModelRole::Resolution]
  # params: request-level provider params (from a preset); they win over the
  # role chain's own params.
  def self.chat(role:, params: {})
    resolution = ModelRole.resolve!(role)
    provider = resolution.provider

    context = RubyLLM.context do |config|
      case provider.kind
      when "anthropic"
        config.anthropic_api_key = provider.api_key
      when "openai_compat"
        config.openai_api_key = provider.api_key
        config.openai_api_base = provider.config["base_url"]
      end
    end

    # assume_model_exists: a new model release is a config row, never a code change.
    chat = context.chat(
      model: resolution.model,
      provider: provider.kind == "anthropic" ? :anthropic : :openai,
      assume_model_exists: true
    )
    merged = resolution.params.merge(params.to_h)
    chat = chat.with_params(**merged.symbolize_keys) if merged.present?
    [ chat, resolution ]
  end

  def self.record_usage!(chat:, resolution:, role:, ref: nil)
    assistant_messages = chat.messages.select { |m| m.role == :assistant }
    UsageEvent.record(
      principal: Current.principal, surface: Current.surface,
      role: role.to_s, provider: resolution.provider.slug, model: resolution.model,
      units: {
        "input_tokens" => assistant_messages.sum { |m| m.input_tokens.to_i },
        "output_tokens" => assistant_messages.sum { |m| m.output_tokens.to_i }
      },
      ref: ref
    )
  end
end
