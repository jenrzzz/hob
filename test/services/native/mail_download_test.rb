require "test_helper"
require_relative "../../support/fake_jmap"
require "digest"

# hob.mail.download (petition 01M51PDT4X0SQRTGSS4T5NV2RF): one attachment's
# raw bytes, base64-encoded, for an agent that needs to hand a real file
# (not just extracted text) to an upload step. Reuses mail.message.get's
# clearance and visibility exactly, the same as mail.attachment.get. One
# test per acceptance line in the forge spec, numbered to match.
class MailDownloadTest < ActiveSupport::TestCase
  setup do
    ENV["HOB_TEST_JMAP_TOKEN"] = FakeJmap::TOKEN
    native_capabilities!
    @skipsy, = agent("skipsy", clearance: "personal")
    policy!(@skipsy, "hob.mail.download", "allow")
    Email::Backends::Base.transport = (@server = FakeJmap.new).to_proc
    @server.mailbox("mb-household", "Household")
    mail_backend("house-mail", realm: "household", mailboxes: [ "Household" ])
  end

  teardown do
    Email::Backends::Base.transport = nil
    ENV.delete("HOB_TEST_JMAP_TOKEN")
  end

  def submit(arguments = {}, agent: @skipsy, realm: "personal")
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: "hob.mail.download", arguments: arguments) }
  end

  def completed(arguments = {})
    request = submit(arguments)
    assert_equal "completed", request.status, request.error.to_s
    request
  end

  REASON = "Lemonade renters policy PDF for Allsafe Self-Storage, as Jenner asked on Oct 16".freeze

  test "1. a PDF attachment under the cap comes back base64, byte-identical, with a matching sha256" do
    pdf = "%PDF-1.4\n#{'A' * 500}\n%%EOF\n".b
    @server.email("m-policy", subject: "Your renewed policy", folders: %w[mb-household],
      attachments: [ { "blobId" => "b-policy", "name" => "Lemonade_Renters_Policy_2026.pdf", "type" => "application/pdf", "size" => pdf.bytesize } ])
    @server.blob("b-policy", pdf)

    result = completed({ "message_id" => "house-mail:m-policy", "attachment_id" => "b-policy", "reason" => REASON }).result
    assert_equal "house-mail:m-policy", result["message_id"]
    assert_equal "b-policy", result["attachment_id"]
    assert_equal "Lemonade_Renters_Policy_2026.pdf", result["filename"]
    assert_equal "application/pdf", result["mime_type"]
    assert_equal pdf.bytesize, result["size"]
    assert_equal Digest::SHA256.hexdigest(pdf), result["sha256"]
    assert_equal pdf, Base64.strict_decode64(result["content_base64"])
    assert_equal "Attachment bytes from private mail: send them only where the household asked.", result["notice"]
  end

  test "2. over max_bytes, or over the 10 MB hard ceiling, fails with the size and no content" do
    @server.email("m-small-cap", subject: "Small", folders: %w[mb-household],
      attachments: [ { "blobId" => "b-small", "name" => "small.pdf", "type" => "application/pdf", "size" => 200 } ])

    under_requested_cap = submit({ "message_id" => "house-mail:m-small-cap", "attachment_id" => "b-small", "reason" => REASON, "max_bytes" => 100 })
    assert_equal "failed", under_requested_cap.status
    assert_match(/is 200 bytes, over the 100 byte limit/, under_requested_cap.error)
    assert_nil under_requested_cap.result

    @server.email("m-huge", subject: "Huge", folders: %w[mb-household],
      attachments: [ { "blobId" => "b-huge", "name" => "huge.pdf", "type" => "application/pdf", "size" => 11.megabytes } ])
    # No blob registered for b-huge: a download attempt would 404, proving it is never fetched.

    over_hard_ceiling = submit({ "message_id" => "house-mail:m-huge", "attachment_id" => "b-huge", "reason" => REASON, "max_bytes" => 50_000_000 })
    assert_equal "failed", over_hard_ceiling.status
    assert_match(/is \d+ bytes, over the 10485760 byte limit/, over_hard_ceiling.error, "max_bytes is clamped to the 10 MB hard ceiling")
    refute @server.calls.any? { |c| c.verb == "GET" && c.url.include?("/jmap/download/") }, "never downloaded"
  end

  test "3. an unknown message_id, or an attachment_id not on the message, is rejected the same way" do
    @server.email("m-policy", subject: "Policy", folders: %w[mb-household],
      attachments: [ { "blobId" => "b-policy", "name" => "Policy.pdf", "type" => "application/pdf", "size" => 10 } ])

    unknown_message = submit({ "message_id" => "house-mail:never-existed", "attachment_id" => "b-policy", "reason" => REASON })
    wrong_attachment = submit({ "message_id" => "house-mail:m-policy", "attachment_id" => "b-nope", "reason" => REASON })
    assert_equal "failed", unknown_message.status
    assert_equal "failed", wrong_attachment.status
    assert_match(/NotFound: .*has no message/, unknown_message.error)
    assert_match(/Invalid: .*has no attachment "b-nope"/, wrong_attachment.error)
  end

  test "4. a message outside the caller's clearance fails indistinguishably from one that does not exist" do
    @server.email("m-hidden", subject: "Private", folders: %w[mb-inbox]) # not in Household: invisible to house-mail

    hidden = submit({ "message_id" => "house-mail:m-hidden", "attachment_id" => "b-anything", "reason" => REASON })
    missing = submit({ "message_id" => "house-mail:never-existed", "attachment_id" => "b-anything", "reason" => REASON })
    assert_equal "failed", hidden.status
    assert_equal "failed", missing.status
    assert_match(/NotFound: .*has no message/, hidden.error)
    assert_match(/NotFound: .*has no message/, missing.error)
    assert_equal hidden.error.sub(/m-hidden|never-existed/, "X"), missing.error.sub(/m-hidden|never-existed/, "X")
  end

  test "5. every successful call's request carries the reason given, and its result the filename, size, and sha256" do
    pdf = "%PDF-1.4\nhello\n%%EOF\n".b
    @server.email("m-policy", subject: "Policy", folders: %w[mb-household],
      attachments: [ { "blobId" => "b-policy", "name" => "Policy.pdf", "type" => "application/pdf", "size" => pdf.bytesize } ])
    @server.blob("b-policy", pdf)

    request = completed({ "message_id" => "house-mail:m-policy", "attachment_id" => "b-policy", "reason" => REASON })
    assert_equal REASON, request.arguments["reason"]
    assert_equal "house-mail:m-policy", request.arguments["message_id"]
    assert_equal "b-policy", request.arguments["attachment_id"]
    assert_equal "Policy.pdf", request.result["filename"]
    assert_equal pdf.bytesize, request.result["size"]
    assert_equal Digest::SHA256.hexdigest(pdf), request.result["sha256"]
  end

  test "6. the handler only reads: it never modifies, moves, or flags the message" do
    pdf = "%PDF-1.4\nhello\n%%EOF\n".b
    @server.email("m-policy", subject: "Policy", folders: %w[mb-household],
      attachments: [ { "blobId" => "b-policy", "name" => "Policy.pdf", "type" => "application/pdf", "size" => pdf.bytesize } ])
    @server.blob("b-policy", pdf)

    completed({ "message_id" => "house-mail:m-policy", "attachment_id" => "b-policy", "reason" => REASON })
    refute @server.calls.any? { |c| c.methods.include?("Email/set") }
    assert_equal({ "mb-household" => true }, @server.emails["m-policy"]["mailboxIds"])
    assert_equal({}, @server.emails["m-policy"]["keywords"])
  end

  test "7. a request without a reason is rejected by schema validation" do
    @server.email("m-policy", subject: "Policy", folders: %w[mb-household],
      attachments: [ { "blobId" => "b-policy", "name" => "Policy.pdf", "type" => "application/pdf", "size" => 10 } ])

    request = submit({ "message_id" => "house-mail:m-policy", "attachment_id" => "b-policy" })
    assert_equal "failed", request.status
    assert_match(/reason is required/, request.error)
  end

  test "message_id and attachment_id are required; an unknown argument is refused" do
    assert_match(/message_id is required/, submit({ "attachment_id" => "b-x", "reason" => REASON }).error)
    assert_match(/attachment_id is required/, submit({ "message_id" => "house-mail:m-x", "reason" => REASON }).error)
    assert_match(/unknown argument bogus/,
                 submit({ "message_id" => "house-mail:m-x", "attachment_id" => "b-x", "reason" => REASON, "bogus" => 1 }).error)
  end

  test "max_bytes must be a positive integer" do
    @server.email("m-policy", subject: "Policy", folders: %w[mb-household],
      attachments: [ { "blobId" => "b-policy", "name" => "Policy.pdf", "type" => "application/pdf", "size" => 10 } ])
    request = submit({ "message_id" => "house-mail:m-policy", "attachment_id" => "b-policy", "reason" => REASON, "max_bytes" => "lots" })
    assert_match(/max_bytes must be a positive integer/, request.error)
  end

  test "capability: read, personal realm, closed schema, requires message_id, attachment_id, and reason" do
    cap = Capability.find_by!(name: "hob.mail.download")
    assert cap.native?
    assert_equal [ "read", "personal", false ], [ cap.kind, cap.realm, cap.input_schema["additionalProperties"] ]
    assert cap.description.length > 40
    assert_equal %w[attachment_id max_bytes message_id reason], cap.input_schema["properties"].keys.sort
    assert_equal %w[attachment_id message_id reason], cap.input_schema["required"].sort
    refute cap.requires_person?
  end

  test "registered at personal realm: a person's assistant sees it only above household" do
    refute_includes Mcp.tools("household").keys, "hob_mail_download"
    assert_includes Mcp.tools("personal").keys, "hob_mail_download"
  end
end
