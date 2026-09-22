require "test_helper"

# hob:surface:register (SENTINEL.md): a surface's manifest becomes webhook
# capability rows, and the surface gets the secret hob will sign with.
class SurfaceCapabilitiesTest < ActiveSupport::TestCase
  class FakeCoolify
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(method, path, body)
      @calls << [ method, path, body ]
      method == :get ? [] : {}
    end
  end

  MANIFEST = {
    "surface" => "mise",
    "capabilities" => [
      { "name" => "mise.recipes", "description" => "Search the household's recipes, most recent first, by words, tag, or ingredient.",
        "kind" => "read", "realm" => "household",
        "input_schema" => { "type" => "object", "properties" => { "q" => { "type" => "string" } }, "additionalProperties" => false } },
      { "name" => "mise.plan.add", "description" => "Put a recipe or a note on a day of the household's meal plan in mise.",
        "kind" => "act", "realm" => "household",
        "input_schema" => { "type" => "object", "properties" => { "recipe_id" => { "type" => "integer" } }, "additionalProperties" => false } }
    ]
  }.freeze

  setup do
    @fetched = []
    @manifest = MANIFEST.deep_dup
    SurfaceCapabilities.transport = lambda { |url| @fetched << url; [ "200", JSON.generate(@manifest) ] }
    @coolify = FakeCoolify.new
    @registry = SurfaceCapabilities.new(coolify: Provision::Coolify.new(transport: @coolify))
  end

  teardown { SurfaceCapabilities.transport = nil }

  def register(**args)
    @registry.call(**{ surface: "mise", url: "https://mise.test/" }.merge(args))
  end

  test "reads the manifest, mints a secret, hands it to the app, and registers a webhook row per capability" do
    result = register(app: "app-1")

    assert_equal [ "https://mise.test/hob/capabilities" ], @fetched, "the trailing slash is not doubled"
    assert_equal [ 2, 0, 0 ], [ result.created, result.updated, result.disabled ]
    assert result.pushed
    assert_nil result.secret, "a pushed secret is not shown"

    pushed = @coolify.calls.find { |_, path, body| path.end_with?("/envs") && body }
    assert_equal "HOB_WEBHOOK_SECRET", pushed[2][:key]
    assert pushed[2][:is_shown_once]
    secret = pushed[2][:value]
    assert_equal 64, secret.length
    assert_equal [ :post, "/applications/app-1/restart", nil ], @coolify.calls.last

    recipes = Capability.find_by!(name: "mise.recipes")
    assert_equal "webhook", recipes.venue
    assert_equal({ "url" => "https://mise.test/hob/capabilities/mise.recipes", "secret" => secret, "surface" => "mise" }, recipes.config)
    assert_equal [ "read", "household", true ], [ recipes.kind, recipes.realm, recipes.enabled ]
    assert_equal({ "q" => { "type" => "string" } }, recipes.input_schema["properties"])
    assert_equal "act", Capability.find_by!(name: "mise.plan.add").kind
    assert_equal %w[mise.plan.add mise.recipes], SurfaceCapabilities.registered("mise").map(&:name)
  end

  test "without an app the secret is handed back once; with SECRET= it is the one given" do
    result = register
    refute result.pushed
    assert_equal result.secret, Capability.find_by!(name: "mise.recipes").config["secret"]
    assert_empty @coolify.calls

    register(secret: "chosen")
    assert_equal "chosen", Capability.find_by!(name: "mise.recipes").config["secret"]
  end

  test "re-running follows the manifest: descriptions and schemas update, kind and realm and enabled are left alone, " \
       "what is gone is disabled, and the secret rotates" do
    register(app: "app-1")
    plan_add = Capability.find_by!(name: "mise.plan.add")
    plan_add.update!(realm: "personal", enabled: false, kind: "read")
    first_secret = Capability.find_by!(name: "mise.recipes").config["secret"]

    @manifest["capabilities"][0]["description"] = "Search the household's recipes by words, tag, ingredient, or time; newest first."
    @manifest["capabilities"].delete_at(1)
    @manifest["capabilities"] << { "name" => "mise.plan", "description" => "The household's meal plan for a week, every day of it.",
                                   "kind" => "read", "realm" => "household", "input_schema" => { "type" => "object" } }
    result = register(app: "app-1", restart: false)

    assert_equal [ 1, 1, 0 ], [ result.created, result.updated, result.disabled ], "plan.add was already disabled"
    refute result.restarted
    recipes = Capability.find_by!(name: "mise.recipes")
    assert_match(/or time/, recipes.description)
    refute_equal first_secret, recipes.config["secret"]
    assert_equal recipes.config["secret"], Capability.find_by!(name: "mise.plan").config["secret"]
    plan_add.reload
    assert_equal [ "personal", false, "read" ], [ plan_add.realm, plan_add.enabled, plan_add.kind ], "a household's tuning holds"
    assert Capability.exists?(name: "mise.plan.add"), "not deleted"

    @manifest["capabilities"].shift
    result = register(app: "app-1", restart: false)
    assert_equal 1, result.disabled
    refute Capability.find_by!(name: "mise.recipes").enabled
    assert Capability.find_by!(name: "mise.plan").enabled
  end

  test "a manifest that is not the surface's, or is malformed, registers nothing" do
    @manifest["surface"] = "parboil"
    assert_raises(SurfaceCapabilities::Error) { register }

    @manifest["surface"] = "mise"
    @manifest["capabilities"][0]["name"] = "todo.list"
    error = assert_raises(SurfaceCapabilities::Error) { register }
    assert_match(/not mise's to offer/, error.message)
    assert_equal 0, Capability.where("name LIKE 'mise.%'").count

    @manifest["capabilities"][0]["name"] = "mise.recipes"
    @manifest["capabilities"][0]["kind"] = "delete"
    assert_raises(SurfaceCapabilities::Error) { register }

    SurfaceCapabilities.transport = ->(_url) { [ "500", "nope" ] }
    assert_match(/HTTP 500/, assert_raises(SurfaceCapabilities::Error) { register }.message)
    SurfaceCapabilities.transport = ->(_url) { [ "200", "<html>" ] }
    assert_match(/not answer JSON/, assert_raises(SurfaceCapabilities::Error) { register }.message)
    assert_raises(SurfaceCapabilities::Error) { register(url: "mise.test") }
  end

  test "a native capability's name cannot be taken over by a surface" do
    native_capabilities!
    @manifest["capabilities"][0]["name"] = "mise.recipes"
    @manifest["surface"] = "todo"
    @manifest["capabilities"] = [ @manifest["capabilities"][0].merge("name" => "todo.list") ]

    error = assert_raises(SurfaceCapabilities::Error) { register(surface: "todo") }
    assert_match(/native capability/, error.message)
    assert Capability.find_by!(name: "todo.list").native?
  end

  test "a petition waiting on a capability is granted when the surface registers it" do
    muse, = agent("muse")
    petition = Petition.create!(principal: muse, want: "search the recipes", capability_name: "mise.recipes",
                                surface: "muse", realm: "household", status: "building", action: "build", effect: "allow")

    register(app: "app-1")

    assert_equal "granted", petition.reload.status
  end
end
