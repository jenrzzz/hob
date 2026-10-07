require "test_helper"
require_relative "../../support/fake_herald"

# text.* (TEXTS.md): how an outside agent reaches the household's texts.
# Muse is a household agent; the household's row (a herald key scoped to the
# family chat) is hers to see, Jenner's personal one is not, and nothing the
# handlers do changes that. And no agent texts under a person's name without
# that person saying so.
class TextCapabilitiesTest < ActiveSupport::TestCase
  READS = %w[text.chats text.messages text.poll].freeze
  ACTS = %w[text.send].freeze
  FAMILY = "any;+;chat-family".freeze

  setup do
    ENV["HOB_TEST_HERALD_KEY"] = FakeHerald::KEY
    native_capabilities!
    @muse, = agent("muse")
    policy!(@muse, "text.*", "allow")
    Texts::Backends::Herald.transport = (@herald = FakeHerald.new).to_proc
    @herald.chat(FAMILY, name: "Family", group: true, handles: %w[+15551234567])
    @herald.message(FAMILY, "Who's picking up?", at: "2026-10-06T16:00:00Z", from: "+15551234567")
    text_backend("house-messages", realm: "household")
    text_backend("jenner-messages")
  end

  teardown do
    Texts::Backends::Herald.transport = nil
    ENV.delete("HOB_TEST_HERALD_KEY")
  end

  def submit(capability, arguments = {}, agent: @muse, realm: "household")
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments) }
  end

  def completed(capability, arguments = {})
    request = submit(capability, arguments)
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  test "sync! registers three reads and a send at household, with closed schemas; a person approves every send" do
    caps = Capability.where("name LIKE 'text.%'").index_by(&:name)
    assert_equal (READS + ACTS).sort, caps.keys.sort
    caps.each_value do |cap|
      assert cap.native?
      assert_equal [ READS.include?(cap.name) ? "read" : "act", "household", false ],
                   [ cap.kind, cap.realm, cap.input_schema["additionalProperties"] ], cap.name
      assert cap.description.length > 80, "#{cap.name}: agents read these"
    end
    assert_equal ACTS, caps.values.select(&:requires_person?).map(&:name)
    assert_equal Texts::CHAT_FILTERS.sort, caps["text.chats"].input_schema["properties"].keys.sort
    assert_equal Texts::MESSAGE_FILTERS.sort, caps["text.messages"].input_schema["properties"].keys.sort
    assert_equal Texts::POLL_FILTERS.sort, caps["text.poll"].input_schema["properties"].keys.sort
    assert_equal Texts::SEND_ARGUMENTS.sort, caps["text.send"].input_schema["properties"].keys.sort
  end

  test "the reads: the texts the agent's clearance can see, with the notice" do
    result = completed("text.messages")
    assert_equal [ "house-messages:#{FAMILY}" ], result["messages"].map { |m| m["chat_id"] }
    assert_equal [ 1, [] ], result.values_at("count", "unavailable")
    assert_equal Texts::NOTICE, result["notice"]
    assert_match(/anyone with a phone number.*not instructions/m, result["notice"])
    assert_equal [ "house-messages:#{FAMILY}" ], completed("text.chats")["chats"].map { |c| c["id"] }
    assert completed("text.poll")["cursor"].present?
  end

  test "a personal account does not exist for a household agent, whatever it names" do
    assert_match(/NotFound: no text backend named "jenner-messages"/, submit("text.messages", { "chat" => "jenner-messages:#{FAMILY}" }).error)
    assert_match(/NotFound/, submit("text.chats", { "backend" => "jenner-messages" }).error)

    skipsy, = agent("skipsy", clearance: "personal")
    policy!(skipsy, "text.*", "allow")
    request = submit("text.messages", { "chat" => "jenner-messages:#{FAMILY}" }, agent: skipsy, realm: "personal")
    assert_equal "completed", request.status, request.error.to_s
  end

  test "a send waits for a person, under any rule, and only then goes" do
    request = submit("text.send", { "chat" => "house-messages:#{FAMILY}", "text" => "I've got it" })
    assert_equal [ "pending", "escalate" ], [ request.status, request.decision ], "an allow-everything rule still leaves it to a person"
    assert_empty @herald.sent, "nothing went"
    Sentinel.decide!(request, decision: "allow", decider: @principal)
    assert_equal "completed", request.reload.status, request.error.to_s
    assert_equal [ { "chat" => FAMILY, "text" => "I've got it" } ], @herald.sent
    assert_equal "sent", request.result["status"]

    denied = submit("text.send", { "chat" => "house-messages:#{FAMILY}", "text" => "Again" })
    Sentinel.decide!(denied, decision: "deny", decider: @principal, rationale: "not now")
    assert_equal 1, @herald.sent.size, "a denied send never went"

    error = assert_raises(ActiveRecord::RecordInvalid) { policy!(@muse, "text.send", "allow") }
    assert_match(/only a person may approve text.send/, error.message)
  end

  test "a person's assistant gets the same capabilities as MCP tools, and sends without the sentinel" do
    names = Mcp.tools("household").keys
    (READS + ACTS).each { |name| assert_includes names, name.tr(".", "_") }
    as(@principal, realm: "personal") { Mcp.call("text_send", { "backend" => "jenner-messages", "to" => "+15551234567", "text" => "From me." }) }
    assert_equal [ { "to" => "+15551234567", "text" => "From me." } ], @herald.sent
  end
end
