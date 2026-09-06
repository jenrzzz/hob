# Idempotent seeds: realms, providers, model roles, a dev principal + key,
# and one house persona. The API key prints once, on first creation only.

[ [ "household", 0 ], [ "personal", 1 ], [ "intimate", 2 ] ].each do |slug, rank|
  Realm.find_or_create_by!(slug: slug) { |r| r.rank = rank }
end
Realm.reset_cache!

Provider.find_or_create_by!(slug: "anthropic") do |p|
  p.kind = "anthropic"
  p.config = { "api_key_env" => "ANTHROPIC_API_KEY" }
end
Provider.find_or_create_by!(slug: "openai-compat") do |p|
  p.kind = "openai_compat"
  p.config = { "api_key_env" => "HOB_OPENAI_COMPAT_KEY", "base_url" => ENV["HOB_OPENAI_COMPAT_BASE"] }
end

# Model roles. Per-role params ride on the chain link; `strict` links fail
# the request rather than fall through (the question is the product).
{
  "chat-default" => [
    { "provider" => "anthropic", "model" => "claude-sonnet-5" },
    { "provider" => "openai-compat", "model" => ENV.fetch("HOB_COMPAT_CHAT_MODEL", "gpt-5.2") }
  ],
  "cheap-classifier" => [
    { "provider" => "anthropic", "model" => "claude-haiku-4-5-20251001" }
  ],
  # airing/parboil: the questioner. Adaptive thinking is explicit because
  # opus runs without it when the parameter is omitted.
  "interviewer" => [
    { "provider" => "anthropic", "model" => "claude-opus-4-7", "strict" => true,
      "params" => { "max_tokens" => 8192, "thinking" => { "type" => "adaptive" } } }
  ],
  # airing/parboil/mise: schema-constrained extraction; long outputs.
  "extractor" => [
    { "provider" => "anthropic", "model" => "claude-sonnet-5", "params" => { "max_tokens" => 16_384 } },
    { "provider" => "openai-compat", "model" => ENV.fetch("HOB_COMPAT_CHAT_MODEL", "gpt-5.2") }
  ],
  # mise: the kitchen companions.
  "companion" => [
    { "provider" => "anthropic", "model" => "claude-sonnet-5", "params" => { "max_tokens" => 4096 } },
    { "provider" => "openai-compat", "model" => ENV.fetch("HOB_COMPAT_CHAT_MODEL", "gpt-5.2") }
  ],
  # lumen: 64k-token story generations.
  "narrator" => [
    { "provider" => "anthropic", "model" => "claude-opus-5", "params" => { "max_tokens" => 64_000 } }
  ]
}.each do |role, chain|
  ModelRole.find_or_create_by!(role: role) { |mr| mr.chain = chain }
end

# USD per million tokens (parboil's table). Prefix rows match dated ids.
# Cache multipliers are Anthropic's standard 0.1x read / 1.25x write.
{
  "claude-haiku-4-5"  => [ 1.00, 5.00 ],
  "claude-sonnet-4-6" => [ 3.00, 15.00 ],
  "claude-sonnet-5"   => [ 3.00, 15.00 ],
  "claude-opus-4-8"   => [ 5.00, 25.00 ]
}.each do |model, (input, output)|
  ModelPrice.find_or_create_by!(model: model) do |p|
    p.input = input
    p.output = output
    p.cache_read = (input * 0.1).round(4)
    p.cache_write = (input * 1.25).round(4)
  end
end

jenner = Principal.find_or_create_by!(name: "jenner") do |p|
  p.kind = "human"
  p.max_clearance = "intimate"
end

if jenner.api_keys.where(surface: "dev").none?
  token = ApiKey.issue!(principal: jenner, surface: "dev", default_clearance: "intimate")
  puts "dev API key (shown once): #{token}"
end

default_preset = Preset.find_or_create_by!(key: "default") do |p|
  p.name = "Default"
  p.stages = Assembly::Pipeline::STAGE_DEFAULTS.map(&:dup)
end
# Upgrade: presets seeded before the instruction stage existed gain it.
if default_preset.stages.none? { |s| s["name"] == "instruction" }
  default_preset.update!(stages: default_preset.stages + [ Assembly::Pipeline::STAGE_DEFAULTS.last.dup ])
end

Persona.find_or_create_by!(key: "hob") do |p|
  p.name = "Hob"
  p.model_role = "chat-default"
  p.prompt = {
    "system_core" => <<~CORE
      You are Hob, the household spirit of this home's AI substrate — the hob
      who does the chores overnight and keeps the pots warm, provided the milk
      is left out. Speak plainly, warmly, and briefly. You are helpful about
      the house and its systems, a little dry, and never twee.
    CORE
  }
end
