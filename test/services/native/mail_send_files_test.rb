require "test_helper"
require_relative "../../support/fake_jmap"

# hob.mail.send_files (petition 01M5K1P1ECDDJR13ANSE98YDM6): a new message
# carrying up to 5 attachments, each a new upload (filename, mime type,
# base64 bytes) or a reference resolved the same way hob.mail.send_attachment
# resolves one, confirmed by a person exactly like it. One test per
# acceptance line in the forge spec, numbered to match; error paths after.
class MailSendFilesTest < ActiveSupport::TestCase
  REASON = "BAGSMART warranty claim, order 113-9818114-5507413, as Jenner asked Skipsy to send".freeze
  JPEG = ("\xFF\xD8\xFF\xE0" + "x" * 40).b.freeze
  PNG = ("\x89PNG\r\n\x1A\n" + "x" * 40).b.freeze
  PDF = ("%PDF-1.4\n" + "x" * 40).b.freeze
  DOCX = ("PK\x03\x04" + "x" * 40).b.freeze
  UPLOAD = { "filename" => "damage1.jpg", "mime_type" => "image/jpeg", "content_base64" => Base64.strict_encode64(JPEG) }.freeze
  REF = { "message_id" => "house-mail:m-policy", "attachment_id" => "b-policy" }.freeze

  setup do
    ENV["HOB_TEST_JMAP_TOKEN"] = FakeJmap::TOKEN
    native_capabilities!
    @skipsy, = agent("skipsy", clearance: "personal")
    policy!(@skipsy, "hob.mail.send_files", "confirm")
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
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: "hob.mail.send_files", arguments: arguments, reason: REASON) }
  end

  # requires_person makes every rule escalate: nothing here ever runs the
  # handler without going through this.
  def confirmed(arguments = {})
    request = submit(arguments)
    assert_equal [ "pending", "escalate" ], [ request.status, request.decision ]
    Sentinel.decide!(request, decision: "allow", decider: @principal, rationale: "go on")
    request.reload
  end

  SEND = { "to" => [ "service@bagsmart.com" ], "subject" => "Warranty claim - order 113-9818114-5507413",
           "body" => "Photos of the damage are attached." }.freeze

  test "1. a valid send with 3 JPEG uploads holds pending, with every file's bytes in the request, until a person decides" do
    uploads = (1..3).map { |n| { "filename" => "damage#{n}.jpg", "mime_type" => "image/jpeg", "content_base64" => Base64.strict_encode64(JPEG) } }
    request = submit(SEND.merge("attachments" => uploads))
    assert_equal [ "pending", "escalate" ], [ request.status, request.decision ]
    assert_equal uploads, request.arguments["attachments"], "the approver can see every file's own bytes, not only its name"
    assert_empty @server.submissions
    assert_empty @server.calls.select { |c| c.verb == "POST" && c.url.include?("/jmap/upload/") }, "nothing uploaded before a decision"
  end

  test "2. after approval the message arrives with 3 attachments whose bytes match the uploads, and it appears in Sent" do
    uploads = (1..3).map { |n| { "filename" => "damage#{n}.jpg", "mime_type" => "image/jpeg", "content_base64" => Base64.strict_encode64(JPEG) } }
    request = confirmed(SEND.merge("attachments" => uploads))
    assert_equal "completed", request.status, request.error.to_s

    draft = @server.api_calls.find { |c| c.methods.include?("Email/set") }.arguments("Email/set").dig("create", "draft")
    assert_equal 3, draft["attachments"].size
    refute draft.key?("hasAttachment"), "hasAttachment is server-set: Fastmail refuses a create that sets it"

    draft["attachments"].each { |part| assert_equal JPEG, @server.blobs[part["blobId"]] }
    assert_equal draft["attachments"], @server.submissions.last["email"]["attachments"]
    assert request.result["message"]["has_attachment"]
    native_id = request.result["message"]["id"].split(":").last
    assert_equal({ "mb-sent" => true }, @server.emails[native_id]["mailboxIds"])

    assert_equal 3, request.result["attachments"].size
    request.result["attachments"].each_with_index do |summary, i|
      assert_equal({ "filename" => "damage#{i + 1}.jpg", "mime_type" => "image/jpeg", "bytes" => JPEG.bytesize,
                     "sha256" => Digest::SHA256.hexdigest(JPEG) }, summary)
    end
  end

  test "3. more than 5 attachments, or more than 10 MB decoded in total, is rejected before any blob is uploaded" do
    too_many = confirmed(SEND.merge("attachments" => [ REF ] * 6))
    assert_equal "failed", too_many.status
    assert_match(/at most 5 attachments/, too_many.error)

    @server.email("m-huge", subject: "Huge", folders: %w[mb-household],
      attachments: [ { "blobId" => "b-huge", "name" => "huge.pdf", "type" => "application/pdf", "size" => 11.megabytes } ])
    too_big = confirmed(SEND.merge("attachments" => [ { "message_id" => "house-mail:m-huge", "attachment_id" => "b-huge" } ]))
    assert_equal "failed", too_big.status
    assert_match(/over the 10485760 byte limit/, too_big.error)
    assert_empty @server.submissions
    assert_empty @server.calls.select { |c| c.verb == "POST" && c.url.include?("/jmap/upload/") }
  end

  test "4. a file declared image/jpeg whose bytes are a ZIP is rejected" do
    bad = { "filename" => "damage1.jpg", "mime_type" => "image/jpeg", "content_base64" => Base64.strict_encode64(DOCX) }
    request = confirmed(SEND.merge("attachments" => [ bad ]))
    assert_equal "failed", request.status
    assert_match(/damage1.jpg is declared image\/jpeg but its bytes are not image\/jpeg/, request.error)
    assert_empty @server.submissions
  end

  test "5. malformed base64 is rejected" do
    bad = { "filename" => "damage1.jpg", "mime_type" => "image/jpeg", "content_base64" => "not-base64!!!" }
    request = confirmed(SEND.merge("attachments" => [ bad ]))
    assert_equal "failed", request.status
    assert_match(/content_base64 is not valid base64/, request.error)
  end

  test "6. a filename containing a path separator is rejected" do
    slash = UPLOAD.merge("filename" => "../damage1.jpg")
    request = confirmed(SEND.merge("attachments" => [ slash ]))
    assert_equal "failed", request.status
    assert_match(/path separator/, request.error)

    backslash = UPLOAD.merge("filename" => 'damage\\1.jpg')
    request = confirmed(SEND.merge("attachments" => [ backslash ]))
    assert_equal "failed", request.status
    assert_match(/path separator/, request.error)
  end

  test "7. a reference entry the agent cannot see at its clearance is rejected, and an existing one is attached correctly" do
    @server.email("m-hidden", subject: "Private", folders: %w[mb-inbox]) # not in Household: invisible to house-mail

    hidden = confirmed(SEND.merge("attachments" => [ { "message_id" => "house-mail:m-hidden", "attachment_id" => "whatever" } ]))
    assert_equal "failed", hidden.status
    assert_match(/NotFound/, hidden.error)
    assert_empty @server.submissions

    ok = confirmed(SEND.merge("attachments" => [ REF ]))
    assert_equal "completed", ok.status, ok.error.to_s
    draft = @server.api_calls.find { |c| c.methods.include?("Email/set") }.arguments("Email/set").dig("create", "draft")
    assert_equal [ { "blobId" => "b-policy", "type" => "application/pdf", "name" => "Lemonade-renters-policy-2026.pdf",
                    "disposition" => "attachment" } ], draft["attachments"]
    assert_equal [ { "size" => 184_233, "filename" => "Lemonade-renters-policy-2026.pdf", "mime_type" => "application/pdf",
                     "attachment_id" => "b-policy", "source_message_id" => "house-mail:m-policy" } ], ok.result["attachments"]
    refute @server.calls.any? { |c| c.verb == "GET" && c.url.include?("/jmap/download/") }, "a reference's bytes are never fetched"
  end

  test "8. a rejected confirmation sends nothing and never uploads a blob to delete" do
    request = submit(SEND.merge("attachments" => [ UPLOAD ]))
    assert_equal [ "pending", "escalate" ], [ request.status, request.decision ]

    Sentinel.decide!(request, decision: "deny", decider: @principal, rationale: "not this one")
    assert_equal "denied", request.reload.status
    assert_empty @server.submissions
    assert_empty @server.calls.select { |c| c.verb == "POST" && c.url.include?("/jmap/upload/") }, "nothing is uploaded for a send that never ran"
  end

  test "9. an unavailable failure after submission tells the caller to check Sent before retrying" do
    @server.refuse_send = "serverFail"
    request = confirmed(SEND.merge("attachments" => [ UPLOAD ]))
    assert_equal "failed", request.status
    assert_match(/Unavailable/, request.error)
    assert_match(/look in the sent mailbox with mail\.search before sending again/, Capability.find_by!(name: "hob.mail.send_files").description)
  end

  # --- error paths ---

  test "attachments mixing an upload's and a reference's keys, or neither, is refused" do
    neither = confirmed(SEND.merge("attachments" => [ { "filename" => "x" } ]))
    assert_match(/mime_type must be one of/, neither.error)

    nothing = confirmed(SEND.merge("attachments" => [ {} ]))
    assert_match(/each one is an upload .* or a reference/, nothing.error)

    bogus = confirmed(SEND.merge("attachments" => [ UPLOAD.merge("bogus" => 1) ]))
    assert_match(/unknown key bogus/, bogus.error)
  end

  test "mime_type must be one of the allowed types" do
    request = confirmed(SEND.merge("attachments" => [ UPLOAD.merge("mime_type" => "application/zip") ]))
    assert_equal "failed", request.status
    assert_match(/mime_type must be one of image\/jpeg/, request.error)
  end

  test "attachments is required: at least one, at most five, each a valid upload or reference" do
    assert_match(/attachments is required/, confirmed(SEND.merge("attachments" => [])).error)
    assert_match(/message_id is required/, confirmed(SEND.merge("attachments" => [ { "attachment_id" => "b-policy" } ])).error)
    assert_match(/attachment_id is required/, confirmed(SEND.merge("attachments" => [ { "message_id" => "house-mail:m-policy" } ])).error)
    assert_match(/filename is required/, confirmed(SEND.merge("attachments" => [ { "mime_type" => "image/jpeg", "content_base64" => "eA==" } ])).error)
    assert_match(/content_base64 is required/, confirmed(SEND.merge("attachments" => [ { "filename" => "x.jpg", "mime_type" => "image/jpeg" } ])).error)
  end

  test "recipients over the limit are rejected" do
    request = confirmed(SEND.merge("to" => Array.new(51) { |i| "person#{i}@example.test" }, "attachments" => [ UPLOAD ]))
    assert_equal "failed", request.status
    assert_match(/at most 50 recipients/, request.error)
    assert_empty @server.submissions
  end

  test "to, subject, and body are required; an unknown top-level argument is refused" do
    assert_match(/to is required/, confirmed(SEND.merge("to" => []).merge("attachments" => [ UPLOAD ])).error)
    assert_match(/subject is required/, confirmed(SEND.merge("subject" => "", "attachments" => [ UPLOAD ])).error)
    assert_match(/body is required/, confirmed(SEND.merge("body" => "", "attachments" => [ UPLOAD ])).error)
    assert_match(/unknown argument bogus/, confirmed(SEND.merge("attachments" => [ UPLOAD ], "bogus" => 1)).error)
  end

  test "more than one visible backend needs account, like mail.send needs backend" do
    mail_backend("other-mail", realm: "household")
    request = confirmed(SEND.merge("attachments" => [ UPLOAD ]))
    assert_equal "failed", request.status
    assert_match(/name a backend/, request.error)
  end

  test "an attachment on a message from a different account than the one sending from is refused" do
    mail_backend("other-mail", realm: "household")
    request = confirmed(SEND.merge("account" => "house-mail", "attachments" => [ { "message_id" => "other-mail:m-policy", "attachment_id" => "b-policy" } ]))
    assert_equal "failed", request.status
    assert_match(/is on other-mail, not house-mail/, request.error)
  end

  test "a mix of an upload and a reference keeps each entry's own shape, in order" do
    request = confirmed(SEND.merge("attachments" => [ UPLOAD, REF ]))
    assert_equal "completed", request.status, request.error.to_s
    filenames = request.result["attachments"].map { |a| a["filename"] }
    assert_equal [ "damage1.jpg", "Lemonade-renters-policy-2026.pdf" ], filenames
  end

  test "a policy may not allow it outright: it needs its own confirm (or deny) rule" do
    error = assert_raises(ActiveRecord::RecordInvalid) { policy!(@skipsy, "hob.mail.send_files", "allow") }
    assert_match(/only a person may approve hob.mail.send_files/, error.message)
  end

  test "capability: act, personal realm, only a person may approve it, closed schema" do
    cap = Capability.find_by!(name: "hob.mail.send_files")
    assert cap.native?
    assert_equal [ "act", "personal", false ], [ cap.kind, cap.realm, cap.input_schema["additionalProperties"] ]
    assert cap.requires_person?
    assert_equal %w[attachments body subject to], cap.input_schema["required"].sort
  end

  test "registered at personal realm: a person's assistant sees it only above household" do
    refute_includes Mcp.tools("household").keys, "hob_mail_send_files"
    assert_includes Mcp.tools("personal").keys, "hob_mail_send_files"
  end
end
