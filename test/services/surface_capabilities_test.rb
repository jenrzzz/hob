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
    @notify_url = ENV["HOB_NOTIFY_URL"]
    @fetched = []
    @manifest = MANIFEST.deep_dup
    SurfaceCapabilities.transport = lambda { |url| @fetched << url; [ "200", JSON.generate(@manifest) ] }
    @coolify = FakeCoolify.new
    @registry = SurfaceCapabilities.new(coolify: Provision::Coolify.new(transport: @coolify))
  end

  teardown do
    SurfaceCapabilities.transport = nil
    Notify.transport = nil
    @notify_url ? ENV["HOB_NOTIFY_URL"] = @notify_url : ENV.delete("HOB_NOTIFY_URL")
  end

  def register(**args)
    @registry.register(**{ surface: "mise", url: "https://mise.test/" }.merge(args))
  end

  def refresh(**args)
    @registry.refresh(**{ surface: "mise" }.merge(args))
  end

  def pantry_scan(**attrs)
    { "name" => "mise.pantry.scan", "description" => "What is in the pantry, from the last scan of its shelves.",
      "kind" => "read", "realm" => "household", "input_schema" => { "type" => "object" } }.merge(attrs)
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
    assert recipes.accepted?, "a person registering a surface has looked at what it offers"
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
       "what is gone is disabled, and the secret rotates with the old one overlapping" do
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
    assert_equal first_secret, recipes.config["previous_secret"], "the old secret still signs while the surface restarts"
    assert_equal recipes.config["secret"], Capability.find_by!(name: "mise.plan").config["secret"]
    assert Capability.find_by!(name: "mise.plan").accepted?
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
    assert_match(/todo is reserved/, error.message, "hob's native namespaces are refused outright")
    assert Capability.find_by!(name: "todo.list").native?
  end

  test "a petition waiting on a capability is granted when the surface registers it" do
    muse, = agent("muse")
    petition = Petition.create!(principal: muse, want: "search the recipes", capability_name: "mise.recipes",
                                surface: "muse", realm: "household", status: "building", action: "build", effect: "allow")

    register(app: "app-1")

    assert_equal "granted", petition.reload.status
  end

  test "a manifest realm hob does not know, a reserved namespace, or a repeated name is refused before anything is pushed" do
    @manifest["capabilities"][0]["realm"] = "secret"
    error = assert_raises(SurfaceCapabilities::Error) { register(app: "app-1") }
    assert_match(/mise.recipes/, error.message)
    assert_empty @coolify.calls, "nothing pushed, nothing restarted"
    assert_equal 0, Capability.where("name LIKE 'mise.%'").count

    @manifest["capabilities"][0]["realm"] = "household"
    @manifest["capabilities"] << @manifest["capabilities"][0]
    assert_match(/more than once/, assert_raises(SurfaceCapabilities::Error) { register }.message)

    %w[mail hob people sentinel forge].each do |reserved|
      @manifest = { "surface" => reserved, "capabilities" => [ pantry_scan("name" => "#{reserved}.new_thing") ] }
      error = assert_raises(SurfaceCapabilities::Error) { register(surface: reserved) }
      assert_match(/reserved/, error.message)
    end
    assert_empty @fetched.grep(/mail/), "a reserved name is refused before its manifest is fetched"
    assert_includes SurfaceCapabilities.reserved_namespaces, "calendar", "derived from the native handlers"
    assert_raises(SurfaceCapabilities::Error) { register(surface: "Mise.x") }
  end

  test "refresh follows the manifest without touching the secret or the app" do
    register(app: "app-1")
    secret = Capability.find_by!(name: "mise.recipes").config["secret"]
    @coolify.calls.clear

    @manifest["capabilities"][0]["description"] = "Search the recipes; now with times."
    result = refresh

    assert_equal [ 0, 2, 0 ], [ result.created, result.updated, result.disabled ]
    refute result.pushed
    assert_empty @coolify.calls
    recipes = Capability.find_by!(name: "mise.recipes")
    assert_match(/with times/, recipes.description)
    assert_equal secret, recipes.config["secret"]
  end

  test "what refresh adds waits, disabled and unaccepted, out of every rule's reach, and a person hears about it" do
    register(app: "app-1")
    muse, = agent("muse")
    policy!(muse, "*", "allow")
    petition = Petition.create!(principal: muse, want: "know what is in the pantry", capability_name: "mise.pantry.scan",
                                surface: "muse", realm: "household", status: "building", action: "build", effect: "allow")
    told = []
    ENV["HOB_NOTIFY_URL"] = "https://ntfy.test/house"
    Notify.transport = ->(_url, title, body, _headers) { told << [ title, body ]; "200" }

    @manifest["capabilities"] << pantry_scan("realm" => "personal")
    result = refresh

    assert_equal [ "mise.pantry.scan" ], result.proposed
    scan = Capability.find_by!(name: "mise.pantry.scan")
    refute scan.accepted?
    refute scan.enabled
    assert_equal scan.config["secret"], Capability.find_by!(name: "mise.recipes").config["secret"], "it signs as the surface's rows do"
    assert_equal "building", petition.reload.status, "a waiting petition is not granted on a proposal"
    assert_equal 1, told.size
    assert_match(/mise offers a new capability, mise.pantry.scan/, told.first[0])
    assert_match(/hob:capabilities:accept\[mise.pantry.scan\]/, told.first[1])

    error = as(muse, realm: "household") { assert_raises(Sentinel::Invalid) { Sentinel.submit!(agent: muse, capability: "mise.pantry.scan") } }
    assert_match(/unknown capability/, error.message, "the wildcard does not reach it")
    assert_raises(ActiveRecord::RecordInvalid) { scan.update!(enabled: true) }

    # Until it is accepted, the proposal follows the manifest.
    @manifest["capabilities"][-1]["realm"] = "intimate"
    told.clear
    refresh
    assert_equal "intimate", scan.reload.realm
    assert_empty told, "a proposal is announced once"

    scan.accept!(by: @principal, realm: "personal")
    assert scan.accepted?
    assert scan.enabled
    assert_equal [ "personal", @principal ], [ scan.realm, scan.accepted_by ]
    assert_equal "granted", petition.reload.status, "accepting grants what was waiting"
    assert_raises(Capability::Error) { scan.accept! }

    @manifest["capabilities"][-1]["realm"] = "household"
    refresh
    assert_equal "personal", scan.reload.realm, "an accepted row's realm is the household's"
  end

  test "refresh needs a registration, and will not move a surface to another URL" do
    assert_match(/not registered/, assert_raises(SurfaceCapabilities::Error) { refresh }.message)

    register
    assert_match(/re-register/, assert_raises(SurfaceCapabilities::Error) { refresh(url: "https://elsewhere.test") }.message)
    assert_equal 2, refresh(url: "https://mise.test/").updated
    assert_equal [ "https://mise.test/hob/capabilities" ], @fetched.uniq
  end

  test "rotate writes the new secret, keeps the old one signing for the overlap, then pushes it" do
    register(app: "app-1")
    old = Capability.find_by!(name: "mise.recipes").config["secret"]
    @coolify.calls.clear

    result = @registry.rotate(surface: "mise", app: "app-1")
    assert result.pushed
    assert_empty @fetched.drop(1), "rotate does not re-read the manifest"
    recipes = Capability.find_by!(name: "mise.recipes")
    new = recipes.config["secret"]
    refute_equal old, new
    assert_equal old, recipes.config["previous_secret"]
    assert_equal [ :post, "/applications/app-1/restart", nil ], @coolify.calls.last

    body = '{"request":"r1"}'
    header = Sentinel::Webhook.signature(Sentinel::Webhook.signing_secrets(recipes.config), Time.now.to_i, body)
    assert Sentinel::Webhook.verify(old, header, body), "a surface still holding the old secret verifies"
    assert Sentinel::Webhook.verify(new, header, body), "and one restarted with the new one"
    assert_match(/,v1=#{OpenSSL::HMAC.hexdigest('SHA256', new, "#{header[/t=(\d+)/, 1]}.#{body}")}\z/, header,
                 "the new secret's signature is last, for a verifier that reads only the last")

    travel SurfaceCapabilities::ROTATION_OVERLAP + 1.minute do
      assert_equal [ new ], Sentinel::Webhook.signing_secrets(recipes.config), "the old secret retires"
    end

    assert_raises(SurfaceCapabilities::Error) { @registry.rotate(surface: "parboil") }
  end
end
