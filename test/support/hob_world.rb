# The smallest household that exercises every code path: three realms, a
# configured provider, a fallback and an unconfigured one, the roles the
# tests need, a principal with a key.
module HobWorld
  ROLE_CHAINS = {
    "chat-default" => [ { "provider" => "anthropic", "model" => "claude-sonnet-5", "params" => { "max_tokens" => 4096 } } ],
    "extractor" => [ { "provider" => "anthropic", "model" => "claude-sonnet-5" },
                     { "provider" => "backup", "model" => "gpt-test" } ],
    "interviewer" => [ { "provider" => "anthropic", "model" => "claude-opus-4-7", "strict" => true,
                         "params" => { "thinking" => { "type" => "adaptive" } } } ],
    "strict-offline" => [ { "provider" => "offline", "model" => "nope", "strict" => true },
                          { "provider" => "anthropic", "model" => "claude-sonnet-5" } ],
    "lenient-offline" => [ { "provider" => "offline", "model" => "nope" },
                           { "provider" => "anthropic", "model" => "claude-sonnet-5" } ]
  }.freeze

  def seed_world!
    ENV["HOB_TEST_ANTHROPIC_KEY"] = "test-key"
    ENV["HOB_TEST_BACKUP_KEY"] = "test-key"
    ENV.delete("HOB_TEST_OFFLINE_KEY")

    [ %w[household 0], %w[personal 1], %w[intimate 2] ].each do |slug, rank|
      Realm.find_or_create_by!(slug: slug) { |r| r.rank = rank.to_i }
    end
    Realm.reset_cache!

    Provider.find_or_create_by!(slug: "anthropic") { |p| p.kind = "anthropic"; p.config = { "api_key_env" => "HOB_TEST_ANTHROPIC_KEY" } }
    Provider.find_or_create_by!(slug: "backup") { |p| p.kind = "openai_compat"; p.config = { "api_key_env" => "HOB_TEST_BACKUP_KEY", "base_url" => "http://backup.test" } }
    Provider.find_or_create_by!(slug: "offline") { |p| p.kind = "anthropic"; p.config = { "api_key_env" => "HOB_TEST_OFFLINE_KEY" } }

    ROLE_CHAINS.each { |role, chain| ModelRole.find_or_create_by!(role: role) { |mr| mr.chain = chain } }
    ModelPrice.find_or_create_by!(model: "claude-sonnet-5") { |p| p.input = 3; p.output = 15; p.cache_read = 0.3; p.cache_write = 3.75 }

    @principal = Principal.find_or_create_by!(name: "tester") { |p| p.kind = "human"; p.max_clearance = "intimate" }
    @token = ApiKey.issue!(principal: @principal, surface: "test", default_clearance: "intimate")
  end

  # An external agent (SENTINEL.md) with a key at the given clearance.
  # -> [principal, token]
  def agent(name = "muse", clearance: "household")
    principal = Principal.find_or_create_by!(name: name) { |p| p.kind = "agent"; p.max_clearance = clearance }
    [ principal, ApiKey.issue!(principal: principal, surface: name, default_clearance: clearance) ]
  end

  def native_capabilities!
    ModelRole.find_or_create_by!(role: "sentinel-reviewer") { |mr| mr.chain = [ { "provider" => "anthropic", "model" => "claude-sonnet-5" } ] }
    Sentinel::Native.sync!
  end

  def policy!(agent, capability, effect, **attrs)
    SentinelPolicy.create!(principal: agent, capability: capability, effect: effect, **attrs)
  end

  # Runs a block the way a request from `principal` at `realm` would.
  def as(principal, realm:, surface: principal.name)
    Clearance.with(realm) do
      Current.set(principal: principal, surface: surface, clearance: realm) { yield }
    end
  end

  def clearance!(realm)
    conn = ActiveRecord::Base.connection
    conn.execute("SET app.clearance = #{conn.quote(realm)}")
  end

  def conversation(realm: "personal", kind: "chat")
    Conversation.create!(surface: "test", realm: realm, taint_realm: realm, kind: kind)
  end

  def persona(key, system_core: "You are #{key}.", instruction: nil, model_role: nil)
    Persona.create!(key: key, name: key.capitalize, model_role: model_role,
                    prompt: { "system_core" => system_core, "instruction" => instruction }.compact)
  end

  def user_message(text)
    { "role" => "user", "content" => text }
  end
end
