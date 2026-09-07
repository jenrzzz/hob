require "test_helper"

class ProvisionTest < ActiveSupport::TestCase
  # Records what provisioning asks Coolify for; answers a fixed env listing.
  class FakeCoolify
    Call = Struct.new(:method, :path, :body)

    attr_reader :calls

    def initialize(existing: [], fail_with: nil)
      @existing = existing
      @fail_with = fail_with
      @calls = []
    end

    def call(method, path, body)
      @calls << Call.new(method, path, body)
      return @existing.map { |key| { "key" => key, "value" => "old" } } if method == :get && path.end_with?("/envs")
      raise @fail_with if @fail_with && method != :get

      {}
    end
  end

  def provision(url: "https://hob.example", addr: "100.64.0.1", **coolify)
    @coolify = FakeCoolify.new(**coolify)
    Provision.new(coolify: Provision::Coolify.new(transport: @coolify), url: url, addr: addr)
  end

  def pushed(key)
    @coolify.calls.find { |c| c.body && c.body[:key] == key }
  end

  test "issues a key for the surface and pushes url, address and key to the app" do
    result = provision.call(surface: "airing", app: "app-1", principal: "tester")

    assert_equal %w[HOB_URL HOB_ADDR HOB_KEY], result.env
    assert_equal "https://hob.example", pushed("HOB_URL").body[:value]
    assert_equal "100.64.0.1", pushed("HOB_ADDR").body[:value]
    assert_equal :post, pushed("HOB_KEY").method
    assert pushed("HOB_KEY").body[:is_shown_once], "the key is hidden in the Coolify UI"
    refute pushed("HOB_URL").body[:is_shown_once]

    key = ApiKey.authenticate(pushed("HOB_KEY").body[:value])
    assert_equal "airing", key.surface
    assert_equal "personal", key.default_clearance
    assert_equal @principal, key.principal
    assert_equal [ :post, "/applications/app-1/restart" ], @coolify.calls.last.then { |c| [ c.method, c.path ] }
    assert result.restarted
    assert_equal 0, result.rotated
  end

  test "existing variables are patched rather than re-posted, and restart can be skipped" do
    provision(existing: %w[HOB_URL HOB_KEY]).call(surface: "airing", app: "app-1", principal: "tester", restart: false)

    assert_equal :patch, pushed("HOB_URL").method
    assert_equal :patch, pushed("HOB_KEY").method
    assert_equal :post, pushed("HOB_ADDR").method
    refute @coolify.calls.any? { |c| c.path.end_with?("/restart") }
  end

  test "re-provisioning rotates: the old key dies only after the new one is pushed" do
    provision.call(surface: "airing", app: "app-1", principal: "tester")
    old = pushed("HOB_KEY").body[:value]

    result = provision.call(surface: "airing", app: "app-1", principal: "tester")
    fresh = pushed("HOB_KEY").body[:value]

    assert_equal 1, result.rotated
    assert_nil ApiKey.authenticate(old)
    assert_equal "airing", ApiKey.authenticate(fresh).surface
    assert_equal 1, ApiKey.where(surface: "airing").count
    assert ApiKey.authenticate(@token), "other surfaces' keys are untouched"
  end

  test "a Coolify failure leaves no orphan key" do
    error = assert_raises(Provision::Error) do
      provision(fail_with: Provision::Error.new("HTTP 500")).call(surface: "airing", app: "app-1", principal: "tester")
    end
    assert_match(/500/, error.message)
    assert_equal 0, ApiKey.where(surface: "airing").count
  end

  test "address is optional, url and a known realm are not" do
    provision(addr: nil).call(surface: "airing", app: "app-1", principal: "tester")
    assert_nil pushed("HOB_ADDR")

    assert_raises(Provision::Error) { provision(url: nil).call(surface: "airing", app: "app-1", principal: "tester") }
    assert_raises(ArgumentError) { provision.call(surface: "airing", app: "app-1", clearance: "cosmic", principal: "tester") }
    assert_equal 1, ApiKey.where(surface: "airing").count, "nothing issued for a bad realm"
  end

  test "the transport refuses to start without Coolify credentials" do
    assert_raises(Provision::Error) { Provision::Coolify.new(url: nil, token: nil) }
  end
end
