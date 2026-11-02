require "test_helper"
require_relative "../../clients/ruby/lib/hob/plugin"

# PLUGINS.md, Phase 1b: an installation's own key signs its manifest, hob
# verifies before it writes anything, and a rotation's old credentials keep
# working until the plugin proves it holds the new ones.
class PluginSigningTest < ActiveSupport::TestCase
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
        "kind" => "read", "realm" => "household", "input_schema" => { "type" => "object" } }
    ]
  }.freeze

  setup do
    @hob_url = ENV["HOB_CLIENT_URL"]
    ENV["HOB_CLIENT_URL"] = "https://hob.test/"
    @manifest = MANIFEST.deep_dup
    @fetches = []
    @revision = 100
    # What the fake plugin signs with (nil: it does not sign), and as.
    @sign_with = nil
    SurfaceCapabilities.transport = lambda do |_url, headers|
      @fetches << headers
      body = @body || JSON.generate(@manifest)
      signature = @sign_with && PluginSignature.sign_manifest(
        key: @sign_with, namespace: @sign_as || headers["X-Hob-Installation"], revision: @revision,
        nonce: @nonce || headers["X-Hob-Nonce"], kid: @kid.to_s, body: body
      )
      [ "200", body, signature ? { "X-Hob-Manifest-Signature" => signature } : {} ]
    end
    @coolify = FakeCoolify.new
    @registry = SurfaceCapabilities.new(coolify: Provision::Coolify.new(transport: @coolify))
  end

  teardown do
    SurfaceCapabilities.transport = nil
    @hob_url ? ENV["HOB_CLIENT_URL"] = @hob_url : ENV.delete("HOB_CLIENT_URL")
  end

  def register(**args)
    @registry.register(**{ surface: "mise", url: "https://mise.test", app: "app-1" }.merge(args))
  end

  def refresh(**args)
    @registry.refresh(**{ surface: "mise" }.merge(args))
  end

  def plugin
    Plugin.find_by!(namespace: "mise").reload
  end

  def pushed_env
    @coolify.calls.select { |_, path, body| path.end_with?("/envs") && body }.to_h { |_, _, body| [ body[:key], body[:value] ] }
  end

  def delivery_secret
    Capability.find_by!(name: "mise.recipes").config["secret"]
  end

  # The fake plugin starts signing with what hob handed it.
  def start_signing!
    @sign_with = pushed_env["HOB_PLUGIN_KEY"]
    @kid = PluginSignature.delivery_key_id(pushed_env["HOB_WEBHOOK_SECRET"])
  end

  test "registering hands the plugin its own key, its id, and where hob is; the key is not a bearer key" do
    register

    env = pushed_env
    assert_equal %w[HOB_PLUGIN_ID HOB_PLUGIN_KEY HOB_PLUGIN_URL HOB_WEBHOOK_SECRET], env.keys.sort
    assert_equal [ "mise", "https://hob.test" ], env.values_at("HOB_PLUGIN_ID", "HOB_PLUGIN_URL")
    assert_equal plugin.key, env["HOB_PLUGIN_KEY"]
    refute_equal env["HOB_PLUGIN_KEY"], env["HOB_WEBHOOK_SECRET"]
    shown_once = @coolify.calls.filter_map { |_, _, body| body && body[:is_shown_once] && body[:key] }
    assert_equal %w[HOB_PLUGIN_KEY HOB_WEBHOOK_SECRET], shown_once.sort
    assert_nil ApiKey.authenticate(env["HOB_PLUGIN_KEY"])
    assert_equal [ "mise" ], @fetches.map { |h| h["X-Hob-Installation"] }
    assert_match(/\A\h{32}\z/, @fetches.first["X-Hob-Nonce"])
  end

  test "an installation that has never signed keeps its HTTPS origin's word, for a person only; once it signs, it must" do
    register
    refute plugin.signed?
    assert_equal 1, refresh.updated, "unsigned, as mise is today"
    error = assert_raises(SurfaceCapabilities::Error) { refresh(automatic: true) }
    assert_match(/never signed/, error.message)

    start_signing!
    result = refresh
    assert result.signed
    assert plugin.signed?
    assert plugin.key_confirmed_at
    assert_equal 100, plugin.manifest_revision
    assert_equal 1, refresh(automatic: true).updated

    @sign_with = nil
    @manifest["capabilities"][0]["description"] = "Unsigned, and changed: whoever answers the URL now."
    error = assert_raises(SurfaceCapabilities::Error) { refresh }
    assert_match(/unsigned manifest, but mise signs/, error.message)
    refute_match(/whoever/, Capability.find_by!(name: "mise.recipes").description, "nothing was changed")

    # A person registering again is bootstrap: it takes the unsigned answer,
    # and the installation has to prove itself again.
    register
    refute plugin.signed?
    assert_match(/whoever/, Capability.find_by!(name: "mise.recipes").description)
  end

  test "a signature that does not verify, was made for another fetch, or for another installation changes nothing" do
    register
    start_signing!
    refresh
    @manifest["capabilities"][0]["description"] = "Changed by someone without the key, but long enough to pass."

    @sign_with = "not-the-key"
    assert_match(/does not verify/, assert_raises(SurfaceCapabilities::Error) { refresh }.message)

    start_signing!
    @nonce = "a" * 32
    assert_match(/does not verify/, assert_raises(SurfaceCapabilities::Error) { refresh }.message, "a replayed answer")

    @nonce = nil
    @sign_as = "parboil"
    assert_match(/does not verify/, assert_raises(SurfaceCapabilities::Error) { refresh }.message)

    refute_match(/without the key/, Capability.find_by!(name: "mise.recipes").description)
    assert plugin.signed?, "a bad answer never counts against the installation"
  end

  test "an older revision, or the same revision with another body, is refused" do
    register
    start_signing!
    @revision = 200
    refresh

    @revision = 150
    assert_match(/older than 200/, assert_raises(SurfaceCapabilities::Error) { refresh }.message)

    @revision = 200
    assert_equal 1, refresh.updated, "the same revision, the same body"
    @manifest["capabilities"][0]["description"] = "The same revision, but this is not what it said before."
    assert_match(/different manifest/, assert_raises(SurfaceCapabilities::Error) { refresh }.message)

    @revision = 201
    refresh
    assert_match(/not what it said/, Capability.find_by!(name: "mise.recipes").description)
    assert_equal 201, plugin.manifest_revision
  end

  test "rotating a signing installation: the old key verifies and the old secret signs until its manifest proves the new ones" do
    register
    start_signing!
    refresh
    old_key = @sign_with
    old_secret = delivery_secret
    @coolify.calls.clear

    @registry.rotate(surface: "mise", app: "app-1")
    new_secret = delivery_secret
    new_key = pushed_env["HOB_PLUGIN_KEY"]
    refute_equal old_secret, new_secret
    refute_equal old_key, new_key
    config = Capability.find_by!(name: "mise.recipes").config
    assert_nil config["previous_secret_until"], "no clock: it waits for the plugin"
    travel 2.days do
      assert_equal [ old_secret, new_secret ], Sentinel::Webhook.signing_secrets(config)
    end

    # Not restarted yet: it signs with the old key and holds the old secret.
    assert refresh.signed
    assert_equal old_secret, Capability.find_by!(name: "mise.recipes").config["previous_secret"]
    assert_nil plugin.key_confirmed_at

    # Restarted with what hob pushed.
    start_signing!
    refresh
    assert plugin.key_confirmed_at
    assert_nil plugin.previous_key
    refute Capability.find_by!(name: "mise.recipes").config.key?("previous_secret"), "the old secret is retired"
    assert_equal [ new_secret ], Sentinel::Webhook.signing_secrets(Capability.find_by!(name: "mise.recipes").config)

    @sign_with = old_key
    assert_match(/does not verify/, assert_raises(SurfaceCapabilities::Error) { refresh }.message, "the old key is retired too")
  end

  test "rotating twice before the first lands keeps what last worked" do
    register
    start_signing!
    refresh
    working_key = @sign_with
    working_secret = delivery_secret

    2.times { @registry.rotate(surface: "mise", app: "app-1") }

    assert_includes plugin.accepted_keys, working_key
    assert_equal working_secret, Capability.find_by!(name: "mise.recipes").config["previous_secret"]
    assert refresh.signed, "the plugin, never restarted, still gets through"
  end

  test "an installation that has never signed rotates as before: an hour's overlap" do
    register
    @registry.rotate(surface: "mise", app: "app-1")
    assert Capability.find_by!(name: "mise.recipes").config["previous_secret_until"].present?
  end

  test "what the gem signs is what hob verifies" do
    header = Hob::Plugin.sign_manifest(body: "{}", nonce: "n1", revision: 7, key: "key", installation: "mise", delivery_secret: "s3cret")
    signed = PluginSignature.verify_manifest(header, keys: %w[other key], namespace: "mise", nonce: "n1", body: "{}")
    assert_equal [ 7, PluginSignature.delivery_key_id("s3cret"), "key" ], [ signed.revision, signed.kid, signed.key ]
    assert_equal Hob::Plugin.delivery_key_id("s3cret"), PluginSignature.delivery_key_id("s3cret")
    assert_nil PluginSignature.verify_manifest(header, keys: [ "key" ], namespace: "mise", nonce: "n2", body: "{}")

    ping = Hob::Plugin.sign_announcement(body: "{}", key: "key", installation: "mise")
    assert_equal "key", PluginSignature.verify_announcement(ping, keys: [ "key" ], namespace: "mise", body: "{}")
    assert_nil PluginSignature.verify_announcement(ping, keys: [ "key" ], namespace: "parboil", body: "{}")
  end
end
