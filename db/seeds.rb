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
# OpenRouter speaks chat completions: any model there is a role away
# (hob:role[name,openrouter,<model id>]).
Provider.find_or_create_by!(slug: "openrouter") do |p|
  p.kind = "openai_compat"
  p.config = { "api_key_env" => "HOB_OPENROUTER_KEY", "base_url" => "https://openrouter.ai/api/v1" }
end

# Voice (CASTS.md): speech, sound effects, and music. Only voice-* roles use it.
Provider.find_or_create_by!(slug: "elevenlabs") do |p|
  p.kind = "elevenlabs"
  p.config = { "api_key_env" => "ELEVENLABS_API_KEY" }
end

# Model roles. Per-role params ride on the chain link; `strict` links fail
# the request rather than fall through (the question is the product).
{
  "chat-default" => [
    { "provider" => "anthropic", "model" => "claude-sonnet-5-5" },
    { "provider" => "openai-compat", "model" => ENV.fetch("HOB_COMPAT_CHAT_MODEL", "gpt-5.2") }
  ],
  "cheap-classifier" => [
    { "provider" => "anthropic", "model" => "claude-haiku-4-5-20251001" }
  ],
  # airing/parboil: the questioner. Opus 5.5 always thinks (adaptive) and
  # defaults to medium effort, so effort is pinned at high, the level the
  # opus roles ran at before it.
  "interviewer" => [
    { "provider" => "anthropic", "model" => "claude-opus-5-5", "strict" => true,
      "params" => { "max_tokens" => 8192, "thinking" => { "type" => "adaptive" }, "output_config" => { "effort" => "high" } } }
  ],
  # airing/parboil/mise: schema-constrained extraction; long outputs.
  "extractor" => [
    { "provider" => "anthropic", "model" => "claude-sonnet-5-5", "params" => { "max_tokens" => 16_384 } },
    { "provider" => "openai-compat", "model" => ENV.fetch("HOB_COMPAT_CHAT_MODEL", "gpt-5.2") }
  ],
  # mise: the kitchen companions.
  "companion" => [
    { "provider" => "anthropic", "model" => "claude-sonnet-5-5", "params" => { "max_tokens" => 4096 } },
    { "provider" => "openai-compat", "model" => ENV.fetch("HOB_COMPAT_CHAT_MODEL", "gpt-5.2") }
  ],
  # lumen: 64k-token story generations.
  "narrator" => [
    { "provider" => "anthropic", "model" => "claude-opus-5-5", "params" => { "max_tokens" => 64_000, "output_config" => { "effort" => "high" } } }
  ],
  # SENTINEL.md: judges external agents' requests under a rule's guidance.
  "sentinel-reviewer" => [
    { "provider" => "anthropic", "model" => "claude-sonnet-5-5", "params" => { "max_tokens" => 1024 } },
    { "provider" => "anthropic", "model" => "claude-haiku-4-5-20251001", "params" => { "max_tokens" => 1024 } }
  ],
  # SENTINEL.md: decides petitions for capabilities and drafts specs for the
  # forge; rare, so the strongest model is affordable.
  "sentinel-steward" => [
    { "provider" => "anthropic", "model" => "claude-opus-5-5", "params" => { "max_tokens" => 8192, "output_config" => { "effort" => "high" } } },
    { "provider" => "anthropic", "model" => "claude-sonnet-5-5", "params" => { "max_tokens" => 8192 } }
  ],
  # MEMORY.md, "Review": the occasional second reader of a persona's file. A
  # different and larger model than the one that runs her, a few calls a month.
  "review" => [
    { "provider" => "anthropic", "model" => "claude-fable-5-2",
      "params" => { "thinking" => { "type" => "adaptive" }, "max_tokens" => 32000 } }
  ],
  # WARD.md: reads what changed in a security check's report and tells a
  # person what matters; a few calls a week.
  "ward-triage" => [
    { "provider" => "anthropic", "model" => "claude-sonnet-5-5", "params" => { "max_tokens" => 2048 } },
    { "provider" => "anthropic", "model" => "claude-haiku-4-5-20251001", "params" => { "max_tokens" => 2048 } }
  ],
  # CASTS.md: rewrites a briefing as two people talking; one call an episode.
  "cast-writer" => [
    { "provider" => "anthropic", "model" => "claude-opus-5-5", "params" => { "max_tokens" => 16_384 } },
    { "provider" => "anthropic", "model" => "claude-sonnet-5-5", "params" => { "max_tokens" => 16_384 } }
  ],
  # CASTS.md, "Voice": what speaks, what makes a stinger, what composes a theme.
  "voice-dialogue" => [ { "provider" => "elevenlabs", "model" => "eleven_v4" } ],
  "voice-sound" => [ { "provider" => "elevenlabs", "model" => "eleven_text_to_sound_v2" } ],
  "voice-music" => [ { "provider" => "elevenlabs", "model" => "music_v1" } ]
}.each do |role, chain|
  ModelRole.find_or_create_by!(role: role) { |mr| mr.chain = chain }
end

# USD per million tokens, provider list prices. Prefix rows match dated
# ids; cache rates default to 0.1x read / 1.25x write of input unless a third
# value gives the read rate (Opus 5.5 and Fable 5.2 read cache at 0.05x and
# 0.025x; an embedding has no cache). Seeds only add missing rows: a live
# price is set with `hob:price` or PUT /v1/prices, which also reprices the
# ledger. `hob:prices` lists what is still unpriced.
{
  "claude-haiku-4-5"       => [ 1.00, 5.00 ],
  "claude-sonnet-4-6"      => [ 3.00, 15.00 ],
  "claude-sonnet-5"        => [ 2.00, 10.00 ],
  "claude-sonnet-5-5"      => [ 2.00, 10.00 ],
  "claude-opus-4-6"        => [ 5.00, 25.00 ],
  "claude-opus-4-7"        => [ 5.00, 25.00 ],
  "claude-opus-4-8"        => [ 5.00, 25.00 ],
  "claude-opus-5"          => [ 5.00, 25.00 ],
  "claude-opus-5-5"        => [ 4.00, 20.00, 0.20 ],
  "claude-fable-5-2"       => [ 8.00, 40.00, 0.20 ],
  "text-embedding-3-large" => [ 0.13, 0.00, 0.00 ]
}.each do |model, (input, output, cache_read)|
  next if ModelPrice.exists?(model: model)

  ModelPrice.set!(model: model, input: input, output: output, cache_read: cache_read, note: "seed", reprice: false)
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
# Upgrade older default presets in canonical order as new default stages land.
missing = Assembly::Pipeline::STAGE_DEFAULTS.reject do |stage|
  default_preset.stages.any? { |existing| existing["name"] == stage["name"] }
end
if missing.any?
  by_name = (default_preset.stages + missing.map(&:dup)).index_by { |stage| stage["name"] }
  known = Assembly::Pipeline::STAGE_DEFAULTS.filter_map { |stage| by_name.delete(stage["name"]) }
  default_preset.update!(stages: known + by_name.values)
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

# The sentinel's native capabilities follow the handlers in code.
Sentinel::Native.sync!

# WARD.md: the first check is infra's security audit, expected weekly.
WardCheck.find_or_create_by!(slug: "exposure") do |c|
  c.description = "infra security/audit.py: Coolify inventory, routes, Authelia gates, full TCP exposure"
end
