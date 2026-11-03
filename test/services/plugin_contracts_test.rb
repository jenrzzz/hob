require "test_helper"

# PLUGINS.md, Phase 1d (section 7): a plugin may loosen an accepted
# capability's contract, but not break it under the same name. A breaking
# entry, or one that declares another kind or realm, is refused alone: it
# keeps the contract a person accepted and is suspended until a person
# resumes it against a manifest that holds to it.
class PluginContractsTest < ActiveSupport::TestCase
  SCHEMA = {
    "type" => "object", "required" => [ "q" ],
    "properties" => { "q" => { "type" => "string" }, "tag" => { "type" => "string", "enum" => %w[soup bread] } }
  }.freeze

  setup do
    @manifest = {
      "surface" => "mise",
      "capabilities" => [
        { "name" => "mise.recipes", "description" => "Search the household's recipes, most recent first, by words or tag.",
          "kind" => "read", "realm" => "household", "input_schema" => SCHEMA.deep_dup },
        { "name" => "mise.plan.add", "description" => "Put a recipe or a note on a day of the household's meal plan in mise.",
          "kind" => "act", "realm" => "household", "input_schema" => { "type" => "object" } }
      ]
    }
    SurfaceCapabilities.transport = ->(_url, _headers) { [ "200", JSON.generate(@manifest), {} ] }
    @told = []
    ENV["HOB_NOTIFY_URL"] = "https://ntfy.test/house"
    Notify.transport = ->(_url, title, body, _headers) { @told << [ title, body ]; "200" }
    @registry = SurfaceCapabilities.new
    @registry.register(surface: "mise", url: "https://mise.test")
  end

  teardown do
    SurfaceCapabilities.transport = nil
    Sentinel::Webhook.transport = nil
    Notify.transport = nil
    ENV.delete("HOB_NOTIFY_URL")
  end

  def recipes
    Capability.find_by!(name: "mise.recipes")
  end

  def schema
    @manifest["capabilities"][0]["input_schema"]
  end

  def refresh
    @registry.refresh(surface: "mise")
  end

  test "ContractDiff: what breaks and what loosens" do
    breaks = ->(change) { ContractDiff.breaking(SCHEMA, SCHEMA.deep_dup.tap(&change)) }

    assert_empty breaks.call(->(s) { s["properties"]["page"] = { "type" => "integer" } }), "a new optional input"
    assert_empty breaks.call(->(s) { s["required"] = [] }), "a required input becoming optional"
    assert_empty breaks.call(->(s) { s["properties"]["tag"]["enum"] << "cake" }), "an enum that widens"
    assert_empty breaks.call(->(s) { s["properties"]["q"]["type"] = %w[string null] }), "a type that widens"
    assert_empty ContractDiff.breaking({ "type" => "integer" }, { "type" => "number" })

    assert_equal [ "input.tag was removed" ], breaks.call(->(s) { s["properties"].delete("tag") })
    assert_equal [ "input.tag is now required" ], breaks.call(->(s) { s["required"] << "tag" })
    assert_equal [ "input.q was string, now integer" ], breaks.call(->(s) { s["properties"]["q"]["type"] = "integer" })
    assert_equal [ "input.tag no longer accepts \"bread\"" ], breaks.call(->(s) { s["properties"]["tag"]["enum"] = %w[soup] })
    assert_equal [ "input.q now must be one of a, b" ], breaks.call(->(s) { s["properties"]["q"]["enum"] = %w[a b] })
    assert_equal [ "input no longer takes properties it does not name" ], breaks.call(->(s) { s["additionalProperties"] = false })
    nested = ContractDiff.breaking({ "type" => "object", "properties" => { "on" => { "type" => "object", "properties" => { "day" => {} } } } },
                                   { "type" => "object", "properties" => { "on" => { "type" => "object", "properties" => {} } } })
    assert_equal [ "input.on.day was removed" ], nested
  end

  test "a loosening change goes through and bumps the contract revision; a description alone does not" do
    @manifest["capabilities"][0]["description"] = "Search the household's recipes by words or tag, newest first."
    refresh
    assert_equal 1, recipes.contract_revision

    schema["properties"]["page"] = { "type" => "integer" }
    result = refresh
    assert_empty result.suspended
    assert_equal 2, recipes.contract_revision
    assert recipes.input_schema["properties"].key?("page")
  end

  test "a breaking change suspends that entry alone, keeps its accepted contract, and tells a person" do
    schema["properties"].delete("tag")
    @manifest["capabilities"][1]["description"] = "Put a recipe or a note on a day of the meal plan, in mise."

    result = refresh

    assert_equal [ "mise.recipes" ], result.suspended.map(&:first)
    assert recipes.suspended?
    assert_match(/input.tag was removed.*mise.recipes.v2/, recipes.suspended_reason)
    assert recipes.input_schema["properties"].key?("tag"), "the accepted contract is kept, for audit"
    assert_equal 1, recipes.contract_revision
    assert_match(/meal plan, in mise/, Capability.find_by!(name: "mise.plan.add").description, "the rest of the manifest went through")
    title, body = @told.last
    assert_match(/mise broke mise.recipes, now suspended/, title)
    assert_match(/hob:capabilities:resume\[mise.recipes\]/, body)

    # Refreshing again does not suspend twice or tell again, and holds the row as it is.
    @told.clear
    assert_empty refresh.suspended
    assert_empty @told
    assert recipes.input_schema["properties"].key?("tag")
  end

  test "a changed declaration of kind or realm needs a person to look again; the household's own stay" do
    @manifest["capabilities"][0]["kind"] = "act"
    result = refresh
    assert_match(/declares kind act \(was read\)/, result.suspended.sole.last)
    assert_equal "read", recipes.kind

    @registry.resume(name: "mise.recipes", by: @principal, kind: "act")
    assert_not recipes.suspended?
    assert_equal "act", recipes.kind
    assert_empty refresh.suspended, "the new declaration is the one reviewed"
  end

  test "a suspended capability is refused at the gate, not offered, and not delivered even if approved before" do
    muse, = agent("muse")
    policy!(muse, "mise.*", "allow")
    approved = SentinelRequest.create!(principal: muse, capability: recipes, arguments: { "q" => "soup" }, surface: "muse", realm: "household")

    schema["properties"].delete("tag")
    refresh

    request = as(muse, realm: "household") { Sentinel.submit!(agent: muse, capability: "mise.recipes", arguments: { "q" => "soup" }) }
    assert_equal [ "deny", "plugin" ], [ request.decision, request.decided_by ]
    assert_match(/mise.recipes is suspended/, request.rationale)
    assert_not_includes Capability.offered_to(muse).pluck(:name), "mise.recipes"
    assert_includes Capability.offered_to(muse).pluck(:name), "mise.plan.add"
    error = assert_raises(Sentinel::Webhook::Error) { Sentinel::Webhook.deliver(approved.capability, approved) }
    assert_match(/suspended/, error.message)
  end

  test "a request asked against an older contract is not delivered" do
    muse, = agent("muse")
    asked = SentinelRequest.create!(principal: muse, capability: recipes, arguments: { "q" => "soup" }, surface: "muse", realm: "household")
    assert_equal 1, asked.contract_revision
    schema["properties"]["page"] = { "type" => "integer" }
    refresh
    delivered = []
    Sentinel::Webhook.transport = ->(url, _body, _headers) { delivered << url; [ "200", "{}" ] }

    error = assert_raises(Sentinel::Webhook::Error) { Sentinel::Webhook.deliver(asked.capability, asked) }
    assert_match(/contract changed \(revision 1 to 2\)/, error.message)
    assert_empty delivered

    again = SentinelRequest.create!(principal: muse, capability: recipes, arguments: { "q" => "soup" }, surface: "muse", realm: "household")
    Sentinel::Webhook.deliver(again.capability, again)
    assert_equal 1, delivered.size
  end

  test "resuming reads the manifest again: refused while it still breaks, resumed once it holds to the contract" do
    schema["properties"].delete("tag")
    refresh

    error = assert_raises(SurfaceCapabilities::Error) { @registry.resume(name: "mise.recipes", by: nil) }
    assert_match(/still breaks its accepted contract \(input.tag was removed\)/, error.message)
    assert recipes.suspended?

    # The plugin restores the old contract, and loosens it.
    schema["properties"]["tag"] = { "type" => "string", "enum" => %w[soup bread cake] }
    result = @registry.resume(name: "mise.recipes", by: nil)
    assert_equal [ "mise.recipes" ], result.resumed
    assert_not recipes.suspended?
    assert_equal 2, recipes.contract_revision
    assert_includes recipes.input_schema["properties"]["tag"]["enum"], "cake"
  end

  test "only a person resumes, and only what is suspended" do
    muse, = agent("muse")
    assert_match(/only a person/, assert_raises(SurfaceCapabilities::Error) { @registry.resume(name: "mise.recipes", by: muse) }.message)
    assert_match(/not suspended/, assert_raises(SurfaceCapabilities::Error) { @registry.resume(name: "mise.recipes", by: nil) }.message)
  end

  test "an entry that is gone while suspended is disabled, not resumed" do
    schema["properties"].delete("tag")
    refresh
    @manifest["capabilities"].shift

    assert_match(/no longer in mise's manifest/, assert_raises(SurfaceCapabilities::Error) { @registry.resume(name: "mise.recipes", by: nil) }.message)
    assert recipes.suspended?
    assert_not recipes.enabled
  end

  test "a new version is a new capability: it waits for acceptance and no exact rule follows it" do
    muse, = agent("muse")
    policy!(muse, "mise.recipes", "allow")
    @manifest["capabilities"] << @manifest["capabilities"][0].merge(
      "name" => "mise.recipes.v2", "version" => 2, "input_schema" => { "type" => "object", "required" => %w[q page] }
    )
    @manifest["capabilities"][0].merge!("deprecated_at" => "2026-11-01T00:00:00Z", "sunset_at" => "2027-01-01T00:00:00Z")

    result = refresh

    assert_equal [ "mise.recipes.v2" ], result.proposed
    v2 = Capability.find_by!(name: "mise.recipes.v2")
    assert_not v2.accepted?
    assert_equal 2, v2.config["version"]
    assert_empty v2.reaching_rules
    assert_equal Time.utc(2027, 1, 1), recipes.sunset_at

    found = as(muse, realm: "household") { Sentinel::Native::CapabilitySearch.new(Struct.new(:arguments).new({ "query" => "recipes" })).call }
    hit = found["results"].find { |r| r["name"] == "mise.recipes" }
    assert_match(/deprecated and goes away on 2027-01-01/, hit["warning"])
  end

  test "a manifest with a malformed sunset or version is refused whole" do
    @manifest["capabilities"][0]["sunset_at"] = "whenever"
    assert_match(/sunset_at must be an ISO 8601 time/, assert_raises(SurfaceCapabilities::Error) { refresh }.message)
    @manifest["capabilities"][0].delete("sunset_at")
    @manifest["capabilities"][0]["version"] = { "major" => 2 }
    assert_match(/version must be a string or an integer/, assert_raises(SurfaceCapabilities::Error) { refresh }.message)
  end
end
