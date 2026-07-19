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

{
  "chat-default" => [
    { "provider" => "anthropic", "model" => "claude-sonnet-5" },
    { "provider" => "openai-compat", "model" => ENV.fetch("HOB_COMPAT_CHAT_MODEL", "gpt-5.2") }
  ],
  "cheap-classifier" => [
    { "provider" => "anthropic", "model" => "claude-haiku-4-5-20251001" }
  ]
}.each do |role, chain|
  ModelRole.find_or_create_by!(role: role) { |mr| mr.chain = chain }
end

jenner = Principal.find_or_create_by!(name: "jenner") do |p|
  p.kind = "human"
  p.max_clearance = "intimate"
end

if jenner.api_keys.where(surface: "dev").none?
  token = ApiKey.issue!(principal: jenner, surface: "dev", default_clearance: "intimate")
  puts "dev API key (shown once): #{token}"
end

Preset.find_or_create_by!(key: "default") do |p|
  p.name = "Default"
  p.stages = Assembly::Pipeline::STAGE_DEFAULTS.map(&:dup)
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
