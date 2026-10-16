require "test_helper"
require_relative "../../support/fake_jmap"

# hob.mail.send_attachment (petition 01M51PFF6736AC9F0HGQ453H5R): a send or
# reply carrying files already in household mail, referenced by message id
# and attachment id, confirmed by a person exactly like mail.send and
# mail.reply. One test per acceptance line in the forge spec, numbered to
# match; error paths after.
class MailSendAttachmentTest < ActiveSupport::TestCase
  REASON = "Lemonade renters policy PDF for Allsafe Self-Storage, as Jenner asked on Oct 16".freeze
  ATTACHMENT = { "message_id" => "house-mail:m-policy", "attachment_id" => "b-policy" }.freeze

  setup do
    ENV["HOB_TEST_JMAP_TOKEN"] = FakeJmap::TOKEN
    native_capabilities!
    @skipsy, = agent("skipsy", clearance: "personal")
    policy!(@skipsy, "hob.mail.send_attachment", "confirm")
    Email::Backends::Base.transport = (@server = FakeJmap.new).to_proc
    @server.mailbox("mb-household", "Household")
    mail_backend("house-mail", realm: "household", mailboxes: [ "Household" ])
    @server.email("m-policy", subject: "Your renewed policy", from: "Lemonade <noreply@lemonade.test>", folders: %w[mb-household],
      attachments: [ { "blobId" => "b-policy", "name" => "Lemonade-renters-policy-2026.pdf", "type" => "application/pdf", "size" => 184_233 } ])
  end

  teardown do
    Email::Backends::Base.transport = nil
    ENV.delete("HOB_TEST_JMAP_TOKEN")
  end

  def submit(arguments = {}, agent: @skipsy, realm: "personal")
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: "hob.mail.send_attachment", arguments: arguments, reason: REASON) }
  end

  # requires_person makes every rule escalate: nothing here ever runs the
  # handler without going through this.
  def confirmed(arguments = {})
    request = submit(arguments)
    assert_equal [ "pending", "escalate" ], [ request.status, request.decision ]
    Sentinel.decide!(request, decision: "allow", decider: @principal, rationale: "go on")
    request.reload
  end

  SEND = { "to" => [ "office@allsafe.example" ], "subject" => "Proof of insurance", "body" => "Attached, as requested." }.freeze

  test "1. nothing is sent without a person's confirmation; a declined confirmation sends nothing" do
    request = submit(SEND.merge("attachments" => [ ATTACHMENT ]))
    assert_equal [ "pending", "escalate" ], [ request.status, request.decision ]
    assert_empty @server.submissions

    Sentinel.decide!(request, decision: "deny", decider: @principal, rationale: "not yet")
    assert_equal "denied", request.reload.status
    assert_empty @server.submissions
  end

  test "2. the result shows every attachment's filename, mime type, size, and source message" do
    request = confirmed(SEND.merge("attachments" => [ ATTACHMENT ]))
    assert_equal "completed", request.status, request.error.to_s
    assert_equal [ { "size" => 184_233, "filename" => "Lemonade-renters-policy-2026.pdf", "mime_type" => "application/pdf",
                     "attachment_id" => "b-policy", "source_message_id" => "house-mail:m-policy" } ],
                 request.result["attachments"]
  end

  test "3. an attachment above the agent's clearance, or on a nonexistent message, fails and nothing is sent" do
    @server.email("m-hidden", subject: "Private", folders: %w[mb-inbox]) # not in Household: invisible to house-mail

    hidden = confirmed(SEND.merge("attachments" => [ { "message_id" => "house-mail:m-hidden", "attachment_id" => "whatever" } ]))
    assert_equal "failed", hidden.status
    assert_match(/NotFound/, hidden.error)

    missing = confirmed(SEND.merge("attachments" => [ { "message_id" => "house-mail:never-existed", "attachment_id" => "whatever" } ]))
    assert_equal "failed", missing.status
    assert_match(/NotFound/, missing.error)
    assert_empty @server.submissions
  end

  test "4. more than 5 attachments, or a total above 20 MB, is rejected" do
    too_many = confirmed(SEND.merge("attachments" => [ ATTACHMENT ] * 6))
    assert_equal "failed", too_many.status
    assert_match(/at most 5 attachments/, too_many.error)

    @server.email("m-huge", subject: "Huge", folders: %w[mb-household],
      attachments: [ { "blobId" => "b-huge", "name" => "huge.pdf", "type" => "application/pdf", "size" => 21.megabytes } ])
    too_big = confirmed(SEND.merge("attachments" => [ { "message_id" => "house-mail:m-huge", "attachment_id" => "b-huge" } ]))
    assert_equal "failed", too_big.status
    assert_match(/over the 20971520 byte limit/, too_big.error)
    assert_empty @server.submissions
  end

  test "5. there is no argument that accepts raw or base64 file content" do
    cap = Capability.find_by!(name: "hob.mail.send_attachment")
    refute cap.input_schema.to_s.match?(/base64|content/i), "the schema has no bytes-carrying argument"
    assert_equal %w[attachment_id filename message_id], cap.input_schema.dig("properties", "attachments", "items", "properties").keys.sort

    request = confirmed(SEND.merge("attachments" => [ ATTACHMENT ], "content_base64" => "not allowed"))
    assert_equal "failed", request.status
    assert_match(/unknown argument content_base64/, request.error)
  end

  test "6. the sent message carries byte-identical attachments with the original mime type, never downloaded" do
    request = confirmed(SEND.merge("attachments" => [ ATTACHMENT ]))
    assert_equal "completed", request.status, request.error.to_s

    # The exact Email object handed to Email/set create: Fastmail refuses
    # this create outright (invalidProperties) if it carries hasAttachment
    # or any other server-set property alongside the attachment.
    draft = @server.api_calls.find { |c| c.methods.include?("Email/set") }.arguments("Email/set").dig("create", "draft")
    assert_equal [ { "blobId" => "b-policy", "type" => "application/pdf", "name" => "Lemonade-renters-policy-2026.pdf",
                    "disposition" => "attachment" } ], draft["attachments"]
    refute draft.key?("hasAttachment"), "hasAttachment is server-set: Fastmail refuses a create that sets it"

    sent = @server.submissions.last["email"]
    assert_equal draft["attachments"], sent["attachments"]
    refute @server.calls.any? { |c| c.verb == "GET" && c.url.include?("/jmap/download/") }, "attachment bytes were never fetched"
  end

  test "7. reply_to_message_id threads the reply, and marks the original answered" do
    request = confirmed("reply_to_message_id" => "house-mail:m-policy", "body" => "Here is the proof you asked for.",
                        "attachments" => [ ATTACHMENT ])
    assert_equal "completed", request.status, request.error.to_s

    draft = @server.api_calls.find { |c| c.methods.include?("Email/set") }.arguments("Email/set").dig("create", "draft")
    assert_equal [ { "blobId" => "b-policy", "type" => "application/pdf", "name" => "Lemonade-renters-policy-2026.pdf",
                    "disposition" => "attachment" } ], draft["attachments"]
    refute draft.key?("hasAttachment"), "hasAttachment is server-set: Fastmail refuses a create that sets it"

    sent = @server.submissions.last["email"]
    assert_equal "Re: Your renewed policy", sent["subject"]
    assert_equal [ "m-policy@example.test" ], sent["inReplyTo"]
    assert_equal [ "m-policy@example.test" ], sent["references"]
    assert @server.emails["m-policy"]["keywords"]["$answered"]
  end

  test "8. recipients over the limit are rejected" do
    request = confirmed(SEND.merge("to" => Array.new(21) { |i| "person#{i}@example.test" }, "attachments" => [ ATTACHMENT ]))
    assert_equal "failed", request.status
    assert_match(/at most 20 addresses/, request.error)
    assert_empty @server.submissions
  end

  test "9. the result matches the mail.send shape plus the attachments list" do
    request = confirmed(SEND.merge("attachments" => [ ATTACHMENT ]))
    assert_equal "completed", request.status, request.error.to_s
    assert_equal %w[attachments message notice sent], request.result.keys.sort
    assert request.result["sent"]
    assert_equal Email::NOTICE, request.result["notice"]
    assert request.result["message"]["has_attachment"]
    assert_equal %w[answered backend cc draft flagged from has_attachment id mailboxes preview received_at reply_to sent_at size subject thread_id to unread],
                 request.result["message"].keys.sort
  end

  # --- error paths ---

  test "a send needs either reply_to_message_id, or to and subject" do
    neither = confirmed({ "body" => "x", "attachments" => [ ATTACHMENT ] })
    assert_equal "failed", neither.status
    assert_match(/give reply_to_message_id, or to and subject/, neither.error)

    both = confirmed(SEND.merge("reply_to_message_id" => "house-mail:m-policy", "attachments" => [ ATTACHMENT ]))
    assert_equal "failed", both.status
    assert_match(/don't also give to or subject/, both.error)
  end

  test "attachments is required: at least one, at most five, each with message_id and attachment_id" do
    assert_match(/attachments is required/, confirmed(SEND.merge("attachments" => [])).error)
    assert_match(/message_id is required/, confirmed(SEND.merge("attachments" => [ { "attachment_id" => "b-policy" } ])).error)
    assert_match(/attachment_id is required/, confirmed(SEND.merge("attachments" => [ { "message_id" => "house-mail:m-policy" } ])).error)
    assert_match(/unknown key bogus/, confirmed(SEND.merge("attachments" => [ ATTACHMENT.merge("bogus" => 1) ])).error)
  end

  test "an attachment on a message from a different account than the one sending from is refused" do
    mail_backend("other-mail", realm: "household")
    request = confirmed(SEND.merge("from_account" => "house-mail",
                                   "attachments" => [ { "message_id" => "other-mail:m-policy", "attachment_id" => "b-policy" } ]))
    assert_equal "failed", request.status
    assert_match(/is on other-mail, not house-mail/, request.error)
  end

  test "an attachment id not on an otherwise-visible message is refused" do
    request = confirmed(SEND.merge("attachments" => [ { "message_id" => "house-mail:m-policy", "attachment_id" => "b-nope" } ]))
    assert_equal "failed", request.status
    assert_match(/has no attachment "b-nope"/, request.error)
  end

  test "a rename keeps the original mime type" do
    request = confirmed(SEND.merge("attachments" => [ ATTACHMENT.merge("filename" => "Proof-of-insurance.pdf") ]))
    assert_equal "completed", request.status, request.error.to_s
    attachment = request.result["attachments"].first
    assert_equal "Proof-of-insurance.pdf", attachment["filename"]
    assert_equal "application/pdf", attachment["mime_type"]
    assert_equal "Proof-of-insurance.pdf", @server.submissions.last["email"]["attachments"].first["name"]
  end

  test "body is required; an unknown top-level argument is refused" do
    assert_match(/body is required/, confirmed(SEND.merge("body" => "", "attachments" => [ ATTACHMENT ])).error)
    assert_match(/unknown argument bogus/, confirmed(SEND.merge("attachments" => [ ATTACHMENT ], "bogus" => 1)).error)
  end

  test "more than one visible backend needs from_account, like mail.send needs backend" do
    mail_backend("other-mail", realm: "household")
    request = confirmed(SEND.merge("attachments" => [ ATTACHMENT ]))
    assert_equal "failed", request.status
    assert_match(/name a backend/, request.error)
  end

  test "a policy may not allow it outright: it needs its own confirm (or deny) rule" do
    error = assert_raises(ActiveRecord::RecordInvalid) { policy!(@skipsy, "hob.mail.send_attachment", "allow") }
    assert_match(/only a person may approve hob.mail.send_attachment/, error.message)
  end

  test "capability: act, personal realm, only a person may approve it, closed schema" do
    cap = Capability.find_by!(name: "hob.mail.send_attachment")
    assert cap.native?
    assert_equal [ "act", "personal", false ], [ cap.kind, cap.realm, cap.input_schema["additionalProperties"] ]
    assert cap.requires_person?
    assert_equal %w[attachments body], cap.input_schema["required"].sort
  end

  test "registered at personal realm: a person's assistant sees it only above household" do
    refute_includes Mcp.tools("household").keys, "hob_mail_send_attachment"
    assert_includes Mcp.tools("personal").keys, "hob_mail_send_attachment"
  end
end
