require "test_helper"

# Push: the companion app's notifications, behind Notify.person.
class PushTest < ActiveSupport::TestCase
  setup do
    @sent = []
    Push.transport = ->(device, note) { @sent << [ device, note ]; [ "200", nil ] }
    Notify.transport = ->(*) { "200" }
  end

  teardown do
    Push.transport = nil
    Notify.transport = nil
  end

  def phone(principal = @principal, token: SecureRandom.hex(32), environment: "sandbox", name: "phone")
    Device.register!(principal: principal, token: token, environment: environment, name: name)
  end

  test "every person's phone hears; nobody else's does; the note says what to open" do
    mine = phone(name: "Jenner's iPhone")
    other = Principal.create!(name: "tessa", kind: "human", max_clearance: "intimate")
    theirs = phone(other, environment: "production")
    muse, _token = agent("muse")
    Device.create!(principal: muse, token: SecureRandom.hex(32), environment: "production")

    petition = Petition.create!(principal: muse, want: "read the calendar", surface: "muse", realm: "household")
    assert_equal 2, Push.people(title: "hob: muse petitions", body: "read the calendar", about: petition)
    assert_equal [ mine, theirs ].map(&:id).sort, @sent.map { |d, _| d.id }.sort
    note = @sent.first.last
    assert_equal "hob: muse petitions", note[:title]
    assert_equal "petition", note[:category]
    assert_equal "petition/#{petition.id}", note[:thread]
    assert_equal({ kind: "petition", id: petition.id, status: "pending" }, note[:hob])
    assert_not_nil mine.reload.last_pushed_at
  end

  test "a dead token is forgotten; an error is logged; unconfigured is silent" do
    dead = phone(name: "old phone")
    live = phone(name: "new phone")
    Push.transport = ->(device, _note) { device == dead ? [ "410", "Unregistered" ] : [ "200", nil ] }
    assert_equal 1, Push.people(title: "t", body: "b")
    assert_nil Device.find_by(id: dead.id)
    assert Device.exists?(live.id)

    Push.transport = ->(*) { [ "400", "BadDeviceToken" ] }
    assert_equal 0, Push.people(title: "t", body: "b")
    assert_nil Device.find_by(id: live.id), "BadDeviceToken is dead too"

    phone
    Push.transport = ->(*) { [ "500", "InternalServerError" ] }
    assert_equal 0, Push.people(title: "t", body: "b")
    assert_equal 1, Device.count, "a transient failure keeps the device"
    Push.transport = ->(*) { raise IOError, "boom" }
    assert_equal 0, Push.people(title: "t", body: "b")

    Push.transport = nil
    assert_not Push.configured?
    assert_equal 0, Push.people(title: "t", body: "b")
    assert_raises(Push::NotConfigured) { Push.deliver!(Device.first, title: "t", body: "b") }
  end

  test "the real transport builds an APNs notification for the device's environment" do
    ENV["APNS_KEY"] = "-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----"
    ENV["APNS_KEY_ID"] = "KEY1234567"
    ENV["APNS_TEAM_ID"] = "TEAM123456"
    assert Push.configured?
    assert_equal "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n", Push.key
    assert_equal "place.amber.hob", Push.bundle_id
  ensure
    %w[APNS_KEY APNS_KEY_ID APNS_TEAM_ID].each { |k| ENV.delete(k) }
  end

  test "a .p8 survives whatever a secret store did to its newlines, and a bad one says so" do
    pem = OpenSSL::PKey::EC.generate("prime256v1").private_to_pem
    ENV["APNS_KEY_ID"] = "KEY1234567"
    ENV["APNS_TEAM_ID"] = "TEAM123456"
    Push.transport = nil
    {
      "intact" => pem, "escaped" => pem.gsub("\n", "\\n"), "joined" => pem.delete("\n"), "spaced" => pem.tr("\n", " "),
      "quoted" => %Q("#{pem.tr("\n", " ")}"), "crlf" => pem.gsub("\n", "\r\n"), "indented" => pem.gsub(/^/, "  ")
    }.each do |shape, text|
      ENV["APNS_KEY"] = text
      assert_equal pem, Push.key, shape
      assert Push.signing_key.private?, shape
    end

    ENV["APNS_KEY"] = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
    error = assert_raises(Push::NotConfigured) { Push.signing_key }
    assert_match(/APNS_KEY is not a PEM private key/, error.message)
    error = assert_raises(Push::NotConfigured) { Push.deliver!(phone, title: "t", body: "b") }
    assert_match(/APNS_KEY is not a PEM private key/, error.message, "the real transport checks the key before dialing Apple")

    ENV["APNS_KEY"] = "/etc/hob/AuthKey.p8"
    assert_raises(Push::NotConfigured) { Push.signing_key }
    ENV["APNS_KEY"] = OpenSSL::PKey::RSA.new(1024).private_to_pem
    assert_match(/not an EC private key/, assert_raises(Push::NotConfigured) { Push.signing_key }.message)
    assert_equal 0, Push.people(title: "t", body: "b"), "a broadcast never raises"
  ensure
    %w[APNS_KEY APNS_KEY_ID APNS_TEAM_ID].each { |k| ENV.delete(k) }
  end

  test "Notify.person reaches the phones, and a pending request pings" do
    phone
    posted = []
    Notify.transport = ->(url, title, body, headers) { posted << [ url, title, body, headers ]; "200" }
    ENV["HOB_NOTIFY_URL"] = "https://ntfy.test/hob"
    assert Notify.person(title: "t", body: "b")
    assert_equal 1, @sent.size
    assert_nil @sent.last.last[:hob]
    assert_nil posted.last[3]["Click"], "nothing to open"
    ENV.delete("HOB_NOTIFY_URL")
    assert Notify.person(title: "t", body: "b"), "no topic, but a phone heard"

    ENV["HOB_NOTIFY_URL"] = "https://ntfy.test/hob"
    native_capabilities!
    muse, _token = agent("muse")
    policy!(muse, "hob.usage", "confirm")
    request = as(muse, realm: "household") { Sentinel.submit!(agent: muse, capability: "hob.usage", reason: "budget check") }
    assert_equal "pending", request.status
    _device, note = @sent.last
    assert_equal "hob: muse asks for hob.usage", note[:title]
    assert_match(/budget check/, note[:body])
    assert_equal({ kind: "request", id: request.id, status: "pending" }, note[:hob])
    assert_equal "hob://request/#{request.id}", posted.last[3]["Click"], "the ntfy message opens the app too"

    policy!(muse, "hob.conversations.list", "deny")
    before = @sent.size
    as(muse, realm: "household") { Sentinel.submit!(agent: muse, capability: "hob.conversations.list") }
    assert_equal before, @sent.size, "a denial does not ping"
  ensure
    ENV.delete("HOB_NOTIFY_URL")
  end
end
