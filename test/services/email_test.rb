require "test_helper"
require_relative "../support/fake_jmap"

# Email (MAIL.md) over the fastmail adapter, with the server faked at the
# transport: what hob sends (the token, the JMAP calls and filters), what
# the façade merges and trims, what a confined or read-only row may reach,
# how sending and replying are put together, and what each failure becomes.
class EmailTest < ActiveSupport::TestCase
  setup do
    ENV["HOB_TEST_JMAP_TOKEN"] = FakeJmap::TOKEN
    ENV["HOB_TIME_ZONE"] = "America/Los_Angeles"
    Email::Backends::Base.transport = (@server = FakeJmap.new).to_proc
    @server.mailbox("mb-household", "Household")
    @server.mailbox("mb-school", "School", parent: "mb-household")
    @server.mailbox("mb-receipts", "Receipts")
    @server.email("m-recital", subject: "Recital on Friday", from: "Ms. Park <park@school.test>", folders: [ "mb-inbox", "mb-school" ],
                               received: "2026-10-05T16:00:00Z", body: "The recital starts at 6.\nBring a snack.")
    @server.email("m-dinner", subject: "Dinner reservation confirmed", from: "OpenTable <noreply@opentable.test>", folders: [ "mb-archive" ],
                              received: "2026-10-03T02:00:00Z", body: "Saturday at 7pm, party of 4.", keywords: { "$seen" => true })
    @server.email("m-spam", subject: "You won a reservation", folders: [ "mb-junk" ], received: "2026-10-05T20:00:00Z")
    @server.email("m-receipt", subject: "Your receipt", from: "Hardware Store <store@example.test>", folders: [ "mb-receipts" ],
                               received: "2026-10-04T18:00:00Z", body: "<p>Thanks!</p><p>Total: <b>$12.00</b></p>", html: true,
                               attachments: [ { "name" => "receipt.pdf", "type" => "application/pdf", "size" => 2048 } ])
  end

  teardown do
    Email::Backends::Base.transport = nil
    ENV.delete("HOB_TEST_JMAP_TOKEN")
    ENV.delete("HOB_TIME_ZONE")
  end

  test "mailboxes: every folder with its path and role, the token sent as a bearer" do
    mail_backend
    mailboxes = Email.mailboxes["mailboxes"]
    assert_includes mailboxes.map { |m| m["path"] }, "Household/School"
    school = mailboxes.find { |m| m["name"] == "School" }
    assert_equal({ "id" => "jenner-fastmail:mb-school", "backend" => "jenner-fastmail", "name" => "School", "path" => "Household/School",
                   "role" => nil, "parent" => "jenner-fastmail:mb-household", "total" => 0, "unread" => 0, "may_add" => true }, school)
    assert_equal "inbox", mailboxes.find { |m| m["name"] == "Inbox" }["role"]
    assert_equal [ "GET", FakeJmap::SESSION, "Bearer api-token" ], @server.calls.first.to_a.values_at(0, 1).push(@server.calls.first.headers["Authorization"])
  end

  test "search: inbox and archive, not trash or junk; newest first; times in the household's zone" do
    mail_backend
    result = Email.search("q" => "reservation")
    assert_equal [ "Dinner reservation confirmed" ], result["messages"].map { |m| m["subject"] }, "the junk one is not searched"
    assert_equal [ 1, false, [] ], result.values_at("total", "truncated", "unavailable")
    query = @server.last("Email/query")
    assert_equal({ "operator" => "AND", "conditions" => [ { "inMailboxOtherThan" => %w[mb-trash mb-junk] }, { "text" => "reservation" } ] }, query["filter"])

    dinner = result["messages"].first
    assert_equal({ "id" => "jenner-fastmail:m-dinner", "backend" => "jenner-fastmail", "thread_id" => "jenner-fastmail:t-m-dinner",
                   "mailboxes" => [ { "id" => "jenner-fastmail:mb-archive", "name" => "Archive", "role" => "archive" } ],
                   "from" => [ { "name" => "OpenTable", "email" => "noreply@opentable.test" } ], "to" => [ FakeJmap::ME ], "cc" => [],
                   "reply_to" => [], "subject" => "Dinner reservation confirmed", "preview" => "Saturday at 7pm, party of 4.",
                   "received_at" => "2026-10-02T19:00:00-07:00", "sent_at" => "2026-10-02T19:00:00-07:00", "unread" => false,
                   "flagged" => false, "answered" => false, "draft" => false, "has_attachment" => false, "size" => 1028 }, dinner)

    assert_equal [ "You won a reservation" ], Email.search("mailbox" => "junk", "q" => "reservation")["messages"].map { |m| m["subject"] }
    newest = Email.search({})["messages"].map { |m| m["id"].split(":").last }
    assert_equal %w[m-recital m-receipt m-dinner], newest
  end

  test "search: each filter becomes a JMAP condition; mailboxes by role, name, or path; limit and truncation" do
    mail_backend
    assert_equal [ "Recital on Friday" ], Email.search("mailbox" => "Household/School")["messages"].map { |m| m["subject"] }
    assert_equal [ "Recital on Friday" ], Email.search("mailbox" => "jenner-fastmail:mb-school")["messages"].map { |m| m["subject"] }
    assert_equal [ "Recital on Friday" ], Email.search("from" => "park", "unread" => true, "after" => "2026-10-05")["messages"].map { |m| m["subject"] }
    conditions = @server.last("Email/query").dig("filter", "conditions")
    assert_includes conditions, { "from" => "park" }
    assert_includes conditions, { "notKeyword" => "$seen" }
    assert_includes conditions, { "after" => "2026-10-05T07:00:00Z" }, "a bare date is midnight where the household is"

    Email.search("flagged" => false, "has_attachment" => true, "before" => "2026-10-06T00:00:00-07:00", "to" => "jenner", "subject" => "x")
    conditions = @server.last("Email/query").dig("filter", "conditions")
    assert_includes conditions, { "notKeyword" => "$flagged" }
    assert_includes conditions, { "hasAttachment" => true }
    assert_includes conditions, { "before" => "2026-10-06T07:00:00Z" }

    limited = Email.search("limit" => 2)
    assert_equal [ 2, 3, true ], [ limited["messages"].size, limited["total"], limited["truncated"] ]
    assert_raises(Email::NotFound) { Email.search("mailbox" => "Nonsense") }
    assert_raises(Email::Invalid) { Email.search("after" => "2026-10-05T10:00:00") }
    assert_raises(Email::Invalid) { Email.search("folder" => "inbox") }
  end

  test "message: the text, an HTML-only body as text, the attachments named" do
    mail_backend
    recital = Email.message("jenner-fastmail:m-recital")["message"]
    assert_equal "The recital starts at 6.\nBring a snack.", recital["body"]
    assert_equal [ "m-recital@example.test", false ], recital.values_at("message_id", "body_truncated")
    receipt = Email.message("jenner-fastmail:m-receipt")["message"]
    assert_equal "Thanks!\nTotal: $12.00", receipt["body"]
    assert_equal [ { "name" => "receipt.pdf", "type" => "application/pdf", "size" => 2048 } ], receipt["attachments"]
    assert @server.last("Email/get")["fetchTextBodyValues"]
    assert_raises(Email::NotFound) { Email.message("jenner-fastmail:m-nope") }
    assert_raises(Email::Invalid) { Email.message("m-recital") }
    assert_raises(Email::NotFound) { Email.message("someone-else:m-recital") }
    refute recital.key?("headers"), "no headers unless asked"
    refute_includes @server.last("Email/get")["properties"], "headers"
  end

  test "message: headers by name, or all of them, raw but unfolded" do
    mail_backend
    @server.email("m-news", subject: "Weekly deals", from: "Shop <deals@shop.test>", headers: [
      { "name" => "List-Unsubscribe", "value" => " <https://shop.test/unsub?u=1>,\r\n <mailto:unsub@shop.test>" },
      { "name" => "List-Unsubscribe-Post", "value" => " List-Unsubscribe=One-Click" },
      { "name" => "Received", "value" => " from mx2.example.test" }
    ])
    one = Email.message("id" => "jenner-fastmail:m-news", "headers" => "list-unsubscribe")["message"]
    assert_equal [ { "name" => "List-Unsubscribe", "value" => "<https://shop.test/unsub?u=1>, <mailto:unsub@shop.test>" } ], one["headers"]
    assert_equal false, one["headers_truncated"]
    assert_includes @server.last("Email/get")["properties"], "headers"

    two = Email.message("id" => "jenner-fastmail:m-news", "headers" => %w[List-Unsubscribe-Post Received])["message"]
    assert_equal [ "Received", "List-Unsubscribe-Post", "Received" ], two["headers"].map { |h| h["name"] }, "in order, repeats kept"
    assert_equal 5, Email.message("id" => "jenner-fastmail:m-news", "headers" => true)["message"]["headers"].size
    assert_equal [], Email.message("id" => "jenner-fastmail:m-news", "headers" => "X-Nope")["message"]["headers"]
    refute Email.message("id" => "jenner-fastmail:m-news", "headers" => false)["message"].key?("headers")

    long = "x" * 3_000
    @server.email("m-long", subject: "Long", headers: [ { "name" => "X-Long", "value" => long } ])
    capped = Email.message("id" => "jenner-fastmail:m-long", "headers" => "x-long")["message"]
    assert_equal [ 2_000, true ], [ capped.dig("headers", 0, "value").size, capped["headers_truncated"] ]

    assert_raises(Email::Invalid) { Email.message("id" => "jenner-fastmail:m-news", "headers" => "List-Unsubscribe: x") }
    assert_raises(Email::Invalid) { Email.message("id" => "jenner-fastmail:m-news", "headers" => []) }
    assert_raises(Email::Invalid) { Email.message("id" => "jenner-fastmail:m-news", "headers" => [ 1 ]) }
    assert_raises(Email::Invalid) { Email.message("id" => "jenner-fastmail:m-news", "header" => "x") }
  end

  test "poll: a first look is a cursor; then what arrived, filtered, and never drafts or what was sent" do
    mail_backend
    first = Email.poll
    assert_equal [ [], false, [] ], first.values_at("messages", "more", "reset")
    assert_equal "Email/get", @server.api_calls.last.methods.first, "a first look reads the state and nothing else"

    @server.email("m-new", subject: "Field trip form", from: "Ms. Park <park@school.test>", received: "2026-10-06T15:00:00Z")
    @server.email("m-sent", subject: "Re: hello", folders: [ "mb-sent" ], received: "2026-10-06T15:01:00Z")
    @server.email("m-draft", subject: "half-written", folders: [ "mb-drafts" ], keywords: { "$draft" => true })
    @server.email("m-ad", subject: "Big sale", from: "Shop <deals@shop.test>", received: "2026-10-06T15:02:00Z")

    second = Email.poll("cursor" => first["cursor"])
    assert_equal [ "Field trip form", "Big sale" ], second["messages"].map { |m| m["subject"] }, "oldest first"
    assert_equal 2, second["count"]
    assert_equal [], Email.poll("cursor" => second["cursor"])["messages"], "nothing new since"
    assert_equal [ "Field trip form" ], Email.poll("cursor" => first["cursor"], "from" => "school.test")["messages"].map { |m| m["subject"] }
    assert_equal [ "Big sale" ], Email.poll("cursor" => first["cursor"], "q" => "sale shop")["messages"].map { |m| m["subject"] }
    assert_equal [], Email.poll("cursor" => first["cursor"], "mailbox" => "archive")["messages"]
    assert_equal [], Email.poll("cursor" => first["cursor"], "unread" => false)["messages"]
  end

  test "poll: more when the server has more than one page; reset when it has lost the place; a bad cursor is refused" do
    mail_backend
    cursor = Email.poll["cursor"]
    105.times { |i| @server.email("m-bulk-#{i}", subject: "bulk #{i}", received: "2026-10-06T16:00:00Z") }
    page = Email.poll("cursor" => cursor)
    assert_equal [ 100, true ], [ page["messages"].size, page["more"] ]
    assert_equal 5, Email.poll("cursor" => page["cursor"])["messages"].size

    @server.forgotten = 1_000
    lost = Email.poll("cursor" => page["cursor"])
    assert_equal [ [], [ "jenner-fastmail" ] ], lost.values_at("messages", "reset")
    refute_equal page["cursor"], lost["cursor"], "a fresh place to start from"

    assert_raises(Email::Invalid) { Email.poll("cursor" => "not a cursor") }
  end

  test "create_mailbox: under a parent, with the server's refusal as the reason" do
    mail_backend
    created = Email.create_mailbox("name" => "Field trips", "parent" => "Household/School")["mailbox"]
    assert_equal [ "Field trips", "Household/School/Field trips", "jenner-fastmail:mb-school" ], created.values_at("name", "path", "parent")
    assert_equal({ "new" => { "name" => "Field trips", "parentId" => "mb-school" } }, @server.last("Mailbox/set")["create"])
    error = assert_raises(Email::Invalid) { Email.create_mailbox("name" => "Receipts") }
    assert_match(/alreadyExists/, error.message)
    assert_raises(Email::Invalid) { Email.create_mailbox("name" => "two\nlines") }
  end

  test "move: `to` moves out of every mailbox; add and remove label; a message is never left in none" do
    mail_backend
    moved = Email.move("id" => "jenner-fastmail:m-recital", "to" => "archive")
    assert_equal [ [ "Archive" ] ], moved["messages"].map { |m| m["mailboxes"].map { |b| b["name"] } }
    assert_equal({ "mb-archive" => true }, @server.emails["m-recital"]["mailboxIds"])

    Email.move("id" => [ "jenner-fastmail:m-recital", "jenner-fastmail:m-dinner" ], "add" => "Household")
    assert_equal %w[mb-archive mb-household], @server.emails["m-dinner"]["mailboxIds"].keys

    result = Email.move("id" => %w[jenner-fastmail:m-receipt jenner-fastmail:m-gone], "remove" => "Receipts")
    assert_equal [], result["messages"]
    assert_equal [ "jenner-fastmail:m-receipt", "jenner-fastmail:m-gone" ], result["failed"].map { |f| f["id"] }
    assert_match(/no mailbox/, result["failed"].first["error"])
    assert @server.emails["m-receipt"]["mailboxIds"]["mb-receipts"]

    assert_raises(Email::Invalid) { Email.move("id" => "jenner-fastmail:m-recital", "to" => "archive", "add" => "Household") }
    assert_raises(Email::Invalid) { Email.move("id" => "jenner-fastmail:m-recital") }
  end

  test "send: a draft written and submitted in one request, as the main identity, and filed in Sent" do
    mail_backend
    result = Email.send_message("to" => "Ana Ruiz <ana@example.test>, ", "cc" => "bo@example.test; cy@example.test", "subject" => "Saturday",
                                "body" => "Dinner at 7?")
    assert result["sent"]
    request = @server.api_calls.last
    assert_equal [ "Email/set", "EmailSubmission/set", "Email/get" ], request.methods
    assert_includes request.json["using"], FakeJmap::SUBMISSION
    draft = request.arguments("Email/set").dig("create", "draft")
    assert_equal [ { "name" => "Ana Ruiz", "email" => "ana@example.test" } ], draft["to"]
    assert_equal %w[bo@example.test cy@example.test], draft["cc"].map { |a| a["email"] }
    assert_equal [ [ { "name" => "Jenner", "email" => "jenner@fastmail.test" } ], "Saturday" ], draft.values_at("from", "subject")
    assert_equal({ "body" => { "value" => "Dinner at 7?" } }, draft["bodyValues"])

    sent = @server.submissions.last
    assert_equal "i-main", sent["identity"]
    assert_equal({ "mb-sent" => true }, @server.emails[result["message"]["id"].split(":").last]["mailboxIds"])
    refute result["message"]["draft"]
    assert_equal [ "Sent" ], result["message"]["mailboxes"].map { |m| m["name"] }
  end

  test "send: from a wildcard identity, and the refusals" do
    mail_backend
    Email.send_message("to" => "ana@example.test", "subject" => "Hi", "body" => "x", "from" => "house@lafave.test")
    assert_equal [ "i-domain", [ { "name" => "Jenner La Fave", "email" => "house@lafave.test" } ] ],
                 [ @server.submissions.last["identity"], @server.submissions.last.dig("email", "from") ]

    assert_match(/not one of jenner-fastmail's identities/, assert_raises(Email::Invalid) {
      Email.send_message("to" => "ana@example.test", "subject" => "Hi", "body" => "x", "from" => "someone@else.test")
    }.message)
    assert_raises(Email::Invalid) { Email.send_message("to" => "not an address", "subject" => "Hi", "body" => "x") }
    assert_raises(Email::Invalid) { Email.send_message("to" => "ana@example.test", "subject" => "Hi", "body" => " ") }
    assert_raises(Email::Invalid) { Email.send_message("to" => "ana@example.test", "subject" => "Hi\r\nBcc: eve@evil.test", "body" => "x") }
    assert_raises(Email::Invalid) { Email.send_message("to" => (1..51).map { |i| "p#{i}@example.test" }, "subject" => "Hi", "body" => "x") }
    assert_raises(Email::Invalid) { Email.send_message("subject" => "Hi", "body" => "x") }
  end

  test "send: a refused submission takes its draft with it; a token that cannot send says so" do
    mail_backend
    before = @server.emails.keys
    @server.refuse_send = "forbiddenToSend"
    assert_match(/refused to send the message: forbiddenToSend/, assert_raises(Email::Forbidden) {
      Email.send_message("to" => "ana@example.test", "subject" => "Hi", "body" => "x")
    }.message)
    assert_equal before, @server.emails.keys, "no draft left behind"

    @server.refuse_send = nil
    @server.can_send = false
    assert_match(/cannot send: give it Email submission access/, assert_raises(Email::Forbidden) {
      Email.send_message("to" => "ana@example.test", "subject" => "Hi", "body" => "x")
    }.message)
  end

  test "reply: to the sender, in the conversation, quoted, from the address it came to; the original marked answered" do
    mail_backend
    @server.email("m-ask", subject: "Carpool?", from: "Bo <bo@example.test>", to: [ "house@lafave.test" ], cc: [ "Cy <cy@example.test>" ],
                           body: "Can you drive Thursday?\n\nThanks", references: [ "older@example.test" ], received: "2026-10-06T01:30:00Z")
    result = Email.reply("id" => "jenner-fastmail:m-ask", "body" => "Yes, I can.")
    assert_equal [ true, "jenner-fastmail:m-ask" ], result.values_at("sent", "in_reply_to")

    draft = @server.api_calls.select { |c| c.methods.include?("EmailSubmission/set") }.last.arguments("Email/set").dig("create", "draft")
    assert_equal [ [ "bo@example.test" ], nil, "Re: Carpool?" ], [ draft["to"].map { |a| a["email"] }, draft["cc"], draft["subject"] ]
    assert_equal [ [ "m-ask@example.test" ], %w[older@example.test m-ask@example.test] ], draft.values_at("inReplyTo", "references")
    assert_equal "house@lafave.test", draft.dig("from", 0, "email"), "from the address it was sent to"
    assert_equal "Yes, I can.\n\nOn Mon, Oct 5, 2026 at 6:30 PM, Bo wrote:\n> Can you drive Thursday?\n>\n> Thanks\n",
                 draft.dig("bodyValues", "body", "value")
    assert @server.emails["m-ask"]["keywords"]["$answered"]
  end

  test "reply: reply_all copies everyone but us; Reply-To wins; no quote when asked; Re: is not doubled" do
    mail_backend
    @server.email("m-group", subject: "Re: Potluck", from: "Bo <bo@example.test>", reply_to: [ "list@example.test" ],
                             to: [ FakeJmap::ME, "Cy <cy@example.test>" ], cc: [ "bo@example.test", "dee@example.test" ], body: "Bring chips")
    Email.reply("id" => "jenner-fastmail:m-group", "body" => "Salsa from me.", "reply_all" => true, "quote" => false, "cc" => "eve@example.test")
    draft = @server.api_calls.select { |c| c.methods.include?("EmailSubmission/set") }.last.arguments("Email/set").dig("create", "draft")
    assert_equal [ "list@example.test" ], draft["to"].map { |a| a["email"] }
    assert_equal %w[cy@example.test bo@example.test dee@example.test eve@example.test], draft["cc"].map { |a| a["email"] }
    assert_equal [ "Re: Potluck", "Salsa from me." ], [ draft["subject"], draft.dig("bodyValues", "body", "value") ]
  end

  test "a confined row: only its mailboxes and what is under them, and it never touches the rest" do
    mail_backend("house-mail", realm: "household", mailboxes: [ "Household" ])
    assert_equal %w[Household Household/School], Email.mailboxes["mailboxes"].map { |m| m["path"] }
    found = Email.search({})["messages"]
    assert_equal [ "Recital on Friday" ], found.map { |m| m["subject"] }
    assert_equal [ "School" ], found.first["mailboxes"].map { |m| m["name"] }, "the inbox it is also in is not shown"
    assert_equal({ "operator" => "OR", "conditions" => [ { "inMailbox" => "mb-household" }, { "inMailbox" => "mb-school" } ] },
                 @server.last("Email/query")["filter"])

    assert_raises(Email::NotFound) { Email.message("house-mail:m-dinner") }
    assert_raises(Email::NotFound) { Email.search("mailbox" => "inbox") }
    assert_raises(Email::NotFound) { Email.move("id" => "house-mail:m-recital", "to" => "archive") }
    assert_equal [ "house-mail:m-dinner" ], Email.move("id" => "house-mail:m-dinner", "to" => "Household")["failed"].map { |f| f["id"] }

    Email.move("id" => "house-mail:m-recital", "to" => "Household")
    assert_equal({ "mb-inbox" => true, "mb-household" => true }, @server.emails["m-recital"]["mailboxIds"], "the inbox it cannot see stays")
    assert_match(/give a parent/, assert_raises(Email::Invalid) { Email.create_mailbox("name" => "Loose") }.message)
    assert Email.create_mailbox("name" => "Sports", "parent" => "Household")["mailbox"]
  end

  test "a read-only row, or a read-only token, files and sends nothing" do
    mail_backend(read_only: true)
    assert_match(/read-only in hob/, assert_raises(Email::Invalid) { Email.move("id" => "jenner-fastmail:m-recital", "to" => "archive") }.message)
    assert_raises(Email::Invalid) { Email.send_message("to" => "ana@example.test", "subject" => "Hi", "body" => "x") }
    assert_equal 3, Email.search({})["total"], "it still reads"

    MailBackend.find_by!(name: "jenner-fastmail").update!(config: { "key_env" => "HOB_TEST_JMAP_TOKEN" })
    @server.read_only = true
    assert_match(/token is read-only/, assert_raises(Email::Forbidden) { Email.create_mailbox("name" => "X") }.message)
  end

  test "failures: a refused token, an account away from a merged read, and one named by itself" do
    mail_backend
    mail_backend("work-mail", kind: "jmap")
    result = Email.search({})
    assert_equal [ "work-mail" ], result["unavailable"].map { |u| u["backend"] }
    assert_match(/found nothing there \(HTTP 404\)/, result["unavailable"].first["error"])
    assert_equal 3, result["messages"].size, "the one that answered still did"
    assert_raises(Email::Unavailable) { Email.search("backend" => "work-mail") }

    ENV["HOB_TEST_JMAP_TOKEN"] = "wrong"
    assert_match(/refused jenner-fastmail's API token \(HTTP 401\)/, assert_raises(Email::Forbidden) { Email.mailboxes("backend" => "jenner-fastmail") }.message)
    ENV.delete("HOB_TEST_JMAP_TOKEN")
    assert_match(/HOB_TEST_JMAP_TOKEN is not set/, assert_raises(Email::Unavailable) { Email.mailboxes("backend" => "jenner-fastmail") }.message)
  end

  test "the realm is the row's: an account above the clearance does not exist" do
    mail_backend
    mail_backend("house-mail", realm: "household", mailboxes: [ "Household" ])
    clearance!("household")
    assert_equal [ "house-mail" ], Email.mailboxes["mailboxes"].map { |m| m["backend"] }.uniq
    assert_raises(Email::NotFound) { Email.message("jenner-fastmail:m-dinner") }
    assert_raises(Email::NotFound) { Email.send_message("backend" => "jenner-fastmail", "to" => "ana@example.test", "subject" => "Hi", "body" => "x") }
    assert_empty @server.submissions
  ensure
    clearance!("intimate")
  end
end
