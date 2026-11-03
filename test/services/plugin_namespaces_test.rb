require "test_helper"

# PLUGINS.md, Phase 1c: an installation's namespace is not its plugin type.
# Two installations of one app run the same code and name their operations
# the same way; hob offers each under its own namespace and addresses the
# plugin by the plugin's own name.
class PluginNamespacesTest < ActiveSupport::TestCase
  def contacts_manifest(*extra)
    {
      "surface" => "contacts",
      "capabilities" => [
        { "name" => "contacts.card.get", "description" => "One card from the address book, by name or email address.",
          "kind" => "read", "realm" => "household", "input_schema" => { "type" => "object" } }
      ] + extra
    }
  end

  setup do
    @manifests = { "https://house.test" => contacts_manifest, "https://jenner.test" => contacts_manifest }
    SurfaceCapabilities.transport = lambda do |url, _headers|
      [ "200", JSON.generate(@manifests.fetch(url.delete_suffix(SurfaceCapabilities::MANIFEST_PATH))), {} ]
    end
    @registry = SurfaceCapabilities.new
  end

  teardown do
    SurfaceCapabilities.transport = nil
    Sentinel::Webhook.transport = nil
  end

  def register(namespace, url, **args)
    @registry.register(surface: namespace, url: url, type: "contacts", **args)
  end

  test "two installations of one type: one operation, offered under each namespace, addressed by the plugin's name" do
    register("contacts-house", "https://house.test")
    register("contacts-jenner", "https://jenner.test", owner: @principal)

    house = Capability.find_by!(name: "contacts-house.card.get")
    mine = Capability.find_by!(name: "contacts-jenner.card.get")
    assert_equal [ "contacts.card.get" ] * 2, [ house.remote_name, mine.remote_name ]
    assert_equal "https://house.test/hob/capabilities/contacts.card.get", house.config["url"]
    assert_equal "https://jenner.test/hob/capabilities/contacts.card.get", mine.config["url"]
    assert_equal %w[contacts contacts], [ house.plugin.plugin_type, mine.plugin.plugin_type ]
    refute_equal house.plugin_id, mine.plugin_id
    assert_nil Capability.find_by(name: "contacts.card.get"), "the type's own name is offered by no one"
    assert mine.plugin.personal?
  end

  test "a delivery names the plugin's operation and the installation hob is calling as" do
    register("contacts-house", "https://house.test")
    muse, = agent("muse")
    policy!(muse, "contacts-house.*", "allow")
    delivered = []
    Sentinel::Webhook.transport = ->(url, body, _headers) { delivered << [ url, JSON.parse(body) ]; [ "200", "{}" ] }

    request = as(muse, realm: "household") { Sentinel.submit!(agent: muse, capability: "contacts-house.card.get") }

    assert_equal "completed", request.status
    url, body = delivered.sole
    assert_equal "https://house.test/hob/capabilities/contacts.card.get", url
    assert_equal [ "contacts.card.get", "contacts-house" ], body.values_at("capability", "installation")
  end

  test "refresh follows the manifest under the namespace: new operations are mapped, missing ones disabled" do
    register("contacts-house", "https://house.test")
    @manifests["https://house.test"] = contacts_manifest(
      { "name" => "contacts.card.search", "description" => "Cards in the address book that match some words.",
        "kind" => "read", "realm" => "household", "input_schema" => { "type" => "object" } }
    )
    @manifests["https://house.test"]["capabilities"].shift

    result = @registry.refresh(surface: "contacts-house")

    assert_equal [ "contacts-house.card.search" ], result.proposed
    assert_equal "contacts.card.search", Capability.find_by!(name: "contacts-house.card.search").remote_name
    refute Capability.find_by!(name: "contacts-house.card.get").enabled
  end

  test "an installation's type is fixed at registration and checked on every read of its manifest" do
    register("contacts-house", "https://house.test")

    error = assert_raises(SurfaceCapabilities::Error) { register("contacts-house", "https://house.test", type: "mise") }
    assert_match(/contacts installation, and its type never changes/, error.message)
    assert_raises(ActiveRecord::ActiveRecordError) { Plugin.find_by!(namespace: "contacts-house").update!(plugin_type: "mise") }

    # The app behind the URL now says it is something else.
    @manifests["https://house.test"] = { "surface" => "mise", "capabilities" => [
      { "name" => "mise.recipes", "description" => "Search the household's recipes, by words, tag, or ingredient.",
        "kind" => "read", "realm" => "household", "input_schema" => { "type" => "object" } }
    ] }
    assert_match(/says it is "mise", not "contacts"/, assert_raises(SurfaceCapabilities::Error) { @registry.refresh(surface: "contacts-house") }.message)
    assert_nil Capability.find_by(name: "contacts-house.recipes")
  end

  test "without TYPE= a namespace is its own type: an app that says otherwise is refused, with the way to register it" do
    error = assert_raises(SurfaceCapabilities::Error) { @registry.register(surface: "contacts-house", url: "https://house.test") }
    assert_match(/says it is "contacts", not "contacts-house" \(.*TYPE=contacts\)/, error.message)
    assert_nil Plugin.find_by(namespace: "contacts-house")
  end

  test "an operation named outside the type is refused, and a reserved namespace stays reserved whatever the type" do
    @manifests["https://house.test"] = contacts_manifest(
      { "name" => "people.merge", "description" => "Merge two people in hob's own people graph into one.",
        "kind" => "act", "realm" => "household", "input_schema" => { "type" => "object" } }
    )
    assert_match(/people.merge is not a contacts operation/,
                 assert_raises(SurfaceCapabilities::Error) { register("contacts-house", "https://house.test") }.message)

    reserved = SurfaceCapabilities.reserved_namespaces.first
    assert_match(/reserved/, assert_raises(SurfaceCapabilities::Error) { register(reserved, "https://jenner.test") }.message)
    assert_empty Plugin.all
  end

  test "an installation whose namespace is its type keeps its names on both sides" do
    @manifests["https://house.test"] = contacts_manifest
    @registry.register(surface: "contacts", url: "https://house.test")

    cap = Capability.find_by!(name: "contacts.card.get")
    assert_equal "contacts.card.get", cap.remote_name
    assert_equal "contacts", cap.plugin.plugin_type
  end
end
