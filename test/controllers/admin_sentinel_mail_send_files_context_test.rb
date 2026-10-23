require "test_helper"

# The hob.mail.send_files confirmation card (PR #67's implementer notes
# flagged it as missing): what a pending request shows before anyone
# approves it, built from the request's own arguments and never the raw
# base64 the generic JSON fallback would otherwise dump.
class AdminSentinelMailSendFilesContextTest < ActionDispatch::IntegrationTest
  REASON = "BAGSMART warranty claim, order 113-9818114-5507413".freeze
  SEND = { "to" => [ "service@bagsmart.com" ], "subject" => "Warranty claim",
           "body" => "Photos of the damage are attached." }.freeze

  setup do
    admin_signing_in!
    native_capabilities!
    @skipsy, = agent("skipsy", clearance: "personal")
    policy!(@skipsy, "hob.mail.send_files", "confirm")
    Notify.transport = ->(*) { }
    admin_sign_in
  end

  teardown do
    admin_signed_out!
    Notify.transport = nil
  end

  def submit(attachments)
    as(@skipsy, realm: "personal") do
      Sentinel.submit!(agent: @skipsy, capability: "hob.mail.send_files", arguments: SEND.merge("attachments" => attachments), reason: REASON)
    end
  end

  test "a pending send with 3 JPEG uploads shows all 3 thumbnails, with sizes and hashes, and sends nothing before approval" do
    jpegs = (1..3).map { |n| ("\xFF\xD8\xFF\xE0img#{n}" + "x" * 40).b }
    uploads = jpegs.each_with_index.map do |bytes, i|
      { "filename" => "damage#{i + 1}.jpg", "mime_type" => "image/jpeg", "content_base64" => Base64.strict_encode64(bytes) }
    end
    request = submit(uploads)
    assert_equal [ "pending", "escalate" ], [ request.status, request.decision ]

    get "/admin/sentinel"
    assert_response :ok
    assert_select "#request-#{request.id} img", count: 3

    jpegs.each_with_index do |bytes, i|
      base64 = Base64.strict_encode64(bytes)
      assert_select "#request-#{request.id} img[src=?]", "data:image/jpeg;base64,#{base64}"
      assert_select "#request-#{request.id}", /damage#{i + 1}\.jpg/
      assert_select "#request-#{request.id}", Regexp.new(Digest::SHA256.hexdigest(bytes))
      assert_select "#request-#{request.id}", Regexp.new(Regexp.escape(bytes.bytesize.to_s))
      # the base64 appears exactly once per image: inside its own thumbnail, never dumped a second time as raw JSON
      assert_equal 1, response.body.scan(base64).size
    end

    assert_equal "pending", request.reload.status, "viewing the card must not run the handler"
  end

  test "raw base64 never appears in the rendered card for non-image uploads" do
    text_bytes = "line one\nline two\n"
    pdf_bytes = ("%PDF-1.4\n" + "x" * 40).b
    heic_bytes = ("\x00\x00\x00\x18ftypheic" + "x" * 40).b
    upload = { "filename" => "notes.txt", "mime_type" => "text/plain", "content_base64" => Base64.strict_encode64(text_bytes) }
    pdf = { "filename" => "policy.pdf", "mime_type" => "application/pdf", "content_base64" => Base64.strict_encode64(pdf_bytes) }
    heic = { "filename" => "photo.heic", "mime_type" => "image/heic", "content_base64" => Base64.strict_encode64(heic_bytes) }
    request = submit([ upload, pdf, heic ])

    get "/admin/sentinel"
    assert_response :ok
    refute_includes response.body, Base64.strict_encode64(text_bytes)
    refute_includes response.body, Base64.strict_encode64(pdf_bytes)
    refute_includes response.body, Base64.strict_encode64(heic_bytes)
    assert_select "#request-#{request.id} img", count: 0
    assert_select "#request-#{request.id}", /notes\.txt/
    assert_select "#request-#{request.id}", /policy\.pdf/
    assert_select "#request-#{request.id}", /photo\.heic/
    assert_select "#request-#{request.id}", /line one/
  end

  test "malformed base64 on a pending upload shows a notice instead of crashing or leaking the value" do
    bad = { "filename" => "broken.jpg", "mime_type" => "image/jpeg", "content_base64" => "not-base64!!!" }
    request = submit([ bad ])

    get "/admin/sentinel"
    assert_response :ok
    assert_select "#request-#{request.id} img", count: 0
    refute_includes response.body, "not-base64!!!"
    assert_select "#request-#{request.id}", /broken\.jpg/
    assert_select "#request-#{request.id}", /invalid base64/
  end

  test "a reference attachment, carrying no bytes, renders only its identifiers" do
    ref = { "message_id" => "house-mail:m-policy", "attachment_id" => "b-policy" }
    request = submit([ ref ])

    get "/admin/sentinel"
    assert_response :ok
    assert_select "#request-#{request.id} img", count: 0
    assert_select "#request-#{request.id}", /house-mail:m-policy/
    assert_select "#request-#{request.id}", /b-policy/
  end

  test "filenames are escaped, never rendered as raw HTML" do
    upload = { "filename" => "<img src=x onerror=alert(1)>.jpg", "mime_type" => "image/jpeg",
              "content_base64" => Base64.strict_encode64(("\xFF\xD8\xFF\xE0" + "x" * 40).b) }
    request = submit([ upload ])

    get "/admin/sentinel"
    assert_response :ok
    refute_includes response.body, "<img src=x onerror=alert(1)>.jpg"
    assert_includes response.body, "&lt;img src=x onerror=alert(1)&gt;.jpg"
  end
end
