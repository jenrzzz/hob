require "test_helper"
require_relative "../support/fake_herald"

# Texts (TEXTS.md) over the herald adapter, with herald faked at the
# transport: what hob sends (the key, the paths and filters), what the
# façade merges and trims, how a send is put together, and what each
# failure becomes.
class TextsTest < ActiveSupport::TestCase
  ANA = "any;-;+15551234567".freeze
  TEAM = "any;+;chat8273".freeze

  setup do
    ENV["HOB_TEST_HERALD_KEY"] = FakeHerald::KEY
    ENV["HOB_TIME_ZONE"] = "America/Los_Angeles"
    Texts::Backends::Herald.transport = (@herald = FakeHerald.new).to_proc
    @herald.chat(ANA, name: "Ana Ruiz", unread: 1)
    @herald.chat(TEAM, name: "Soccer parents", group: true, handles: %w[+15551234567 +15559876543])
    @herald.message(TEAM, "Practice moved to 5", at: "2026-10-05T16:00:00Z", from: "+15559876543", name: "Bo")
    @herald.message(ANA, "Running 10 late", at: "2026-10-06T16:59:12Z", from: "+15551234567", name: "Ana Ruiz", read: false,
                         reply_to: "G-1", reactions: [ { "reaction" => "loved", "emoji" => nil, "from_me" => true, "from" => nil } ])
    @herald.message(ANA, "No rush", at: "2026-10-06T17:01:00Z")
  end

  teardown do
    Texts::Backends::Herald.transport = nil
    ENV.delete("HOB_TEST_HERALD_KEY")
    ENV.delete("HOB_TIME_ZONE")
  end

  test "chats: most recently active first, ids prefixed, times in the household's zone, the key sent as a bearer" do
    text_backend
    chats = Texts.chats["chats"]
    assert_equal [ "jenner-messages:#{ANA}", "jenner-messages:#{TEAM}" ], chats.map { |c| c["id"] }
    assert_equal({ "id" => "jenner-messages:#{ANA}", "backend" => "jenner-messages", "identifier" => "+15551234567",
                   "service" => "iMessage", "group" => false, "name" => "Ana Ruiz", "display_name" => nil,
                   "participants" => [ { "handle" => "+15551234567", "name" => nil } ], "last_message_at" => "2026-10-06T10:01:00-07:00",
                   "unread" => 1 }, chats.first)
    call = @herald.calls.last
    assert_equal [ "GET", "http://mini.test:8379/v1/chats", "Bearer hrd_test" ], [ call.verb, call.url.split("?").first, call.headers["Authorization"] ]

    Texts.chats("q" => "soccer", "active_after" => "2026-10-01", "limit" => 5)
    assert_equal({ "q" => "soccer", "active_after" => "2026-10-01T07:00:00Z", "limit" => "5" }, @herald.calls.last.query,
                 "a bare date is midnight where the household is, sent to herald in UTC")
  end

  test "messages: one chat or all of them, newest first, with everything prefixed" do
    text_backend
    result = Texts.messages("chat" => "jenner-messages:#{ANA}")
    assert_equal [ "No rush", "Running 10 late" ], result["messages"].map { |m| m["text"] }
    assert_equal({ "chat" => ANA, "limit" => "50" }, @herald.calls.last.query, "the chat goes to herald without hob's prefix")
    late = result["messages"].last
    assert_equal [ "jenner-messages:G-1002", "jenner-messages:#{ANA}", "jenner-messages:G-1", "2026-10-06T09:59:12-07:00" ],
                 late.values_at("id", "chat_id", "reply_to", "sent_at")
    assert_equal [ false, { "handle" => "+15551234567", "name" => "Ana Ruiz" }, false ], late.values_at("from_me", "sender", "read")
    assert_equal [ { "reaction" => "loved", "emoji" => nil, "from_me" => true, "from" => nil } ], late["reactions"]
    refute late.key?("seq"), "herald's seq stays behind"
    assert_nil result["messages"].first["sender"]

    all = Texts.messages("q" => "practice", "after" => "2026-10-05T00:00:00-07:00", "before" => "2026-10-07", "unread" => false, "from" => "bo")
    assert_equal [ "Practice moved to 5" ], all["messages"].map { |m| m["text"] }
    assert_equal({ "q" => "practice", "from" => "bo", "after" => "2026-10-05T07:00:00Z", "before" => "2026-10-07T07:00:00Z",
                   "unread" => "false", "limit" => "50" }, @herald.calls.last.query)

    limited = Texts.messages("limit" => 2)
    assert_equal [ 2, true ], [ limited["messages"].size, limited["truncated"] ]
  end

  test "reads merge across accounts, and an account that cannot answer is named, not fatal, unless it was asked for" do
    text_backend
    text_backend("house-messages", realm: "household")
    @herald.respond(503, { "error" => { "code" => "messages_unavailable", "message" => "herald cannot read the Messages database" } })
    result = Texts.messages
    assert_equal [ { "backend" => "house-messages", "error" => "herald cannot read the Messages database" } ], result["unavailable"]
    assert_equal 3, result["messages"].size

    @herald.respond(503, { "error" => { "code" => "messages_unavailable", "message" => "no" } })
    assert_raises(Texts::Unavailable) { Texts.messages("backend" => "house-messages") }
  end

  test "what goes in is checked: unknown filters, ids, times, limits, backends" do
    text_backend
    assert_match(/unknown filter mailbox/, assert_raises(Texts::Invalid) { Texts.messages("mailbox" => "inbox") }.message)
    assert_match(/<backend>:<id>/, assert_raises(Texts::Invalid) { Texts.messages("chat" => ANA.delete(":")) }.message)
    assert_match(/with an offset/, assert_raises(Texts::Invalid) { Texts.messages("after" => "2026-10-06T10:00:00") }.message)
    assert_match(/not after/, assert_raises(Texts::Invalid) { Texts.messages("after" => "2026-10-06", "before" => "2026-10-05") }.message)
    assert_match(/limit must be/, assert_raises(Texts::Invalid) { Texts.chats("limit" => 0) }.message)
    assert_match(/different backends/, assert_raises(Texts::Invalid) { Texts.messages("backend" => "x", "chat" => "jenner-messages:#{ANA}") }.message)
    assert_raises(Texts::NotFound) { Texts.messages("chat" => "nobody:#{ANA}") }
    assert_raises(Texts::NotFound) { Texts.messages("chat" => "jenner-messages:any;-;+15550000000") }
  end

  test "poll: a first look gives a cursor and nothing; after that, what arrived, incoming only unless asked" do
    text_backend
    first = Texts.poll
    assert_equal [ [], 0, false ], first.values_at("messages", "count", "more")
    assert_equal({ "from_me" => "false", "limit" => "100" }, @herald.calls.last.query)

    @herald.message(ANA, "Here now", at: "2026-10-06T17:10:00Z", from: "+15551234567")
    @herald.message(ANA, "Coming down", at: "2026-10-06T17:11:00Z")
    @herald.message(TEAM, "Who has the oranges?", at: "2026-10-06T17:12:00Z", from: "+15559876543")
    second = Texts.poll("cursor" => first["cursor"])
    assert_equal [ "Here now", "Who has the oranges?" ], second["messages"].map { |m| m["text"] }
    assert_equal({ "since" => "1003", "from_me" => "false", "limit" => "100" }, @herald.calls.last.query)
    assert_empty Texts.poll("cursor" => second["cursor"])["messages"]

    everything = Texts.poll("cursor" => first["cursor"], "include_sent" => true, "chat" => "jenner-messages:#{ANA}")
    assert_equal [ "Here now", "Coming down" ], everything["messages"].map { |m| m["text"] }
    assert_equal [ "Who has the oranges?" ], Texts.poll("cursor" => first["cursor"], "q" => "ORANGES")["messages"].map { |m| m["text"] }
    assert_equal [ "Here now" ], Texts.poll("cursor" => first["cursor"], "from" => "1234567")["messages"].map { |m| m["text"] }
    assert_match(/cursor is what text.poll last returned/, assert_raises(Texts::Invalid) { Texts.poll("cursor" => "nonsense!") }.message)
  end

  test "send: into a chat, or to a person; sent with the message, or pending" do
    text_backend
    sent = Texts.send_message("chat" => "jenner-messages:#{ANA}", "text" => "On my way")
    assert_equal [ "sent", "jenner-messages:#{ANA}", "On my way", true ], [ sent["status"], sent["chat_id"], sent.dig("message", "text"), sent.dig("message", "from_me") ]
    assert_equal({ "chat" => ANA, "text" => "On my way" }, @herald.sent.last)
    assert_equal [ "POST", "application/json" ], [ @herald.calls.last.verb, @herald.calls.last.headers["Content-Type"] ]

    @herald.pending = true
    pending = Texts.send_message("to" => " +1 (555) 123-4567 ", "text" => "Hi")
    assert_equal({ "status" => "pending", "chat_id" => "jenner-messages:any;-;+1 (555) 123-4567" }, pending)
    assert_equal({ "to" => "+1 (555) 123-4567", "text" => "Hi" }, @herald.sent.last)
  end

  test "send: what it refuses before asking herald" do
    text_backend
    text_backend("house-messages", realm: "household", read_only: true)
    assert_match(/not both/, assert_raises(Texts::Invalid) { Texts.send_message("chat" => "jenner-messages:#{ANA}", "to" => "+15551234567", "text" => "x") }.message)
    assert_match(/chat or to is required/, assert_raises(Texts::Invalid) { Texts.send_message("text" => "x") }.message)
    assert_match(/text is required/, assert_raises(Texts::Invalid) { Texts.send_message("chat" => "jenner-messages:#{ANA}", "text" => "  ") }.message)
    assert_match(/at most 20000/, assert_raises(Texts::Invalid) { Texts.send_message("chat" => "jenner-messages:#{ANA}", "text" => "x" * 20_001) }.message)
    assert_match(/which account/, assert_raises(Texts::Invalid) { Texts.send_message("to" => "+15551234567", "text" => "x") }.message)
    assert_match(/phone number/, assert_raises(Texts::Invalid) { Texts.send_message("backend" => "jenner-messages", "to" => "Ana", "text" => "x") }.message)
    assert_match(/read-only/, assert_raises(Texts::Invalid) { Texts.send_message("backend" => "house-messages", "to" => "ana@example.com", "text" => "x") }.message)
    assert_empty @herald.sent
  end

  test "herald's errors become ours" do
    text_backend
    { 404 => Texts::NotFound, 400 => Texts::Invalid, 409 => Texts::Invalid, 422 => Texts::Invalid, 401 => Texts::Forbidden,
      403 => Texts::Forbidden, 503 => Texts::Unavailable, 500 => Texts::Unavailable }.each do |status, error|
      @herald.respond(status, { "error" => { "code" => "x", "message" => "because" } })
      assert_raises(error, status.to_s) { Texts.chats("backend" => "jenner-messages") }
    end
    Texts::Backends::Herald.transport = ->(*) { raise Errno::ECONNREFUSED }
    assert_match(/herald unreachable at mini.test/, assert_raises(Texts::Unavailable) { Texts.chats("backend" => "jenner-messages") }.message)
    ENV.delete("HOB_TEST_HERALD_KEY")
    assert_match(/HOB_TEST_HERALD_KEY is not set/, assert_raises(Texts::Unavailable) { Texts.chats("backend" => "jenner-messages") }.message)
  end

  test "check: herald's status, the key's scope included" do
    status = text_backend.adapter.check
    assert_equal [ true, "0.1.0", "hob" ], [ status["reachable"], status["herald"], status.dig("herald_key", "name") ]
  end
end
