require "test_helper"
require_relative "../../support/fake_jmap"

# mail.* (MAIL.md): how an outside agent reaches the household's mail.
# Muse is a household agent; the household folder is hers to see, Jenner's
# personal account is not, and nothing the handlers do changes that. And no
# agent sends mail under a person's name without that person saying so.
class MailCapabilitiesTest < ActiveSupport::TestCase
  READS = %w[mail.mailboxes mail.message.get mail.poll mail.search].freeze
  ACTS = %w[mail.mailbox.create mail.move mail.reply mail.send].freeze
  PERSON = %w[mail.reply mail.send].freeze

  setup do
    ENV["HOB_TEST_JMAP_TOKEN"] = FakeJmap::TOKEN
    native_capabilities!
    @muse, = agent("muse")
    policy!(@muse, "mail.*", "allow")
    Email::Backends::Base.transport = (@server = FakeJmap.new).to_proc
    @server.mailbox("mb-household", "Household")
    @server.email("m-recital", subject: "Recital on Friday", from: "Ms. Park <park@school.test>", folders: [ "mb-inbox", "mb-household" ])
    @server.email("m-bank", subject: "Your statement", from: "Bank <bank@example.test>")
    mail_backend("house-mail", realm: "household", mailboxes: [ "Household" ])
    mail_backend("jenner-fastmail")
  end

  teardown do
    Email::Backends::Base.transport = nil
    ENV.delete("HOB_TEST_JMAP_TOKEN")
  end

  def submit(capability, arguments = {}, agent: @muse, realm: "household")
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments) }
  end

  def completed(capability, arguments = {})
    request = submit(capability, arguments)
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  test "sync! registers four reads and four acts at household, with closed schemas; a person approves every send" do
    caps = Capability.where("name LIKE 'mail.%'").index_by(&:name)
    assert_equal (READS + ACTS).sort, caps.keys.sort
    caps.each_value do |cap|
      assert cap.native?
      assert_equal [ READS.include?(cap.name) ? "read" : "act", "household", false ],
                   [ cap.kind, cap.realm, cap.input_schema["additionalProperties"] ], cap.name
      assert cap.description.length > 80, "#{cap.name}: agents read these"
    end
    assert_equal PERSON, caps.values.select(&:requires_person?).map(&:name).sort
    assert_equal Email::SEARCH_FILTERS.sort, caps["mail.search"].input_schema["properties"].keys.sort
    assert_equal Email::POLL_FILTERS.sort, caps["mail.poll"].input_schema["properties"].keys.sort
    assert_equal Email::SEND_ARGUMENTS.sort, caps["mail.send"].input_schema["properties"].keys.sort
    assert_equal Email::REPLY_ARGUMENTS.sort, caps["mail.reply"].input_schema["properties"].keys.sort
    assert_equal Email::MOVE_ARGUMENTS.sort, caps["mail.move"].input_schema["properties"].keys.sort
    assert_equal Email::MAILBOX_ARGUMENTS.sort, caps["mail.mailbox.create"].input_schema["properties"].keys.sort
  end

  test "the reads: the mail the agent's clearance can see, with the notice" do
    result = completed("mail.search")
    assert_equal [ "house-mail:m-recital" ], result["messages"].map { |m| m["id"] }
    assert_equal [ 1, [] ], result.values_at("count", "unavailable")
    assert_equal Email::NOTICE, result["notice"]
    assert_match(/anyone at all.*not instructions/m, result["notice"])
    assert_equal [ "Household" ], completed("mail.mailboxes")["mailboxes"].map { |m| m["path"] }
    assert_equal "Recital on Friday", completed("mail.message.get", "id" => "house-mail:m-recital").dig("message", "subject")
    assert completed("mail.poll")["cursor"].present?
  end

  test "a personal account does not exist for a household agent, whatever it names" do
    assert_match(/NotFound: no mail backend named "jenner-fastmail"/, submit("mail.message.get", { "id" => "jenner-fastmail:m-bank" }).error)
    assert_match(/NotFound/, submit("mail.search", { "backend" => "jenner-fastmail" }).error)
    assert_match(/NotFound/, submit("mail.move", { "id" => "jenner-fastmail:m-bank", "to" => "archive" }).error)
    assert_equal({ "mb-inbox" => true }, @server.emails["m-bank"]["mailboxIds"])

    skipsy, = agent("skipsy", clearance: "personal")
    policy!(skipsy, "mail.*", "allow")
    request = submit("mail.message.get", { "id" => "jenner-fastmail:m-bank" }, agent: skipsy, realm: "personal")
    assert_equal "completed", request.status, request.error.to_s
  end

  test "the acts: filing goes straight through; a send waits for a person, under any rule, and only then goes" do
    assert_equal [ "Household" ], completed("mail.move", "id" => "house-mail:m-recital", "add" => "Household")
      .dig("messages", 0, "mailboxes").map { |m| m["name"] }

    request = submit("mail.send", { "to" => "ana@example.test", "subject" => "Saturday", "body" => "Dinner at 7?" })
    assert_equal [ "pending", "escalate" ], [ request.status, request.decision ], "an allow-everything rule still leaves it to a person"
    assert_empty @server.submissions, "nothing went"
    Sentinel.decide!(request, decision: "allow", decider: @principal)
    assert_equal "completed", request.reload.status, request.error.to_s
    assert_equal 1, @server.submissions.size

    reply = submit("mail.reply", { "id" => "house-mail:m-recital", "body" => "We'll be there." })
    assert_equal "pending", reply.status
    Sentinel.decide!(reply, decision: "deny", decider: @principal, rationale: "not now")
    assert_equal 1, @server.submissions.size, "a denied reply never went"

    error = assert_raises(ActiveRecord::RecordInvalid) { policy!(@muse, "mail.send", "allow") }
    assert_match(/only a person may approve mail.send/, error.message)
  end

  test "a person's assistant gets the same capabilities as MCP tools, and sends without the sentinel" do
    names = Mcp.tools("household").keys
    (READS + ACTS).each { |name| assert_includes names, name.tr(".", "_") }
    result = as(@principal, realm: "personal") { Mcp.call("mail_search", { "q" => "statement" }) }
    assert_equal [ "jenner-fastmail:m-bank" ], result["messages"].map { |m| m["id"] }
    as(@principal, realm: "personal") do
      Mcp.call("mail_send", { "backend" => "jenner-fastmail", "to" => "ana@example.test", "subject" => "Hi", "body" => "From me." })
    end
    assert_equal 1, @server.submissions.size
  end
end
