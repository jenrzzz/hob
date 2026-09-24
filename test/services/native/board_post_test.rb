require "test_helper"

# hob.board.post (SENTINEL.md): the write half of the household message
# board skipsy and Marley share (companion to hob.board.read, petition
# 01M3AARTJETP1G4TDEQ8CAQEPV). Author is always the calling agent's
# authenticated identity and surface, never an argument; household realm
# only, whatever the calling agent's own clearance happens to be.
class BoardPostTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @skipsy, _ = agent("skipsy")
    @marley, _ = agent("marley")
    policy!(nil, "hob.board.post", "allow")
  end

  def post(arguments = {}, agent: @skipsy, realm: "household")
    as(agent, realm: realm) do
      Sentinel.submit!(agent: agent, capability: "hob.board.post", arguments: arguments, reason: "board")
    end
  end

  def post!(arguments = {}, agent: @skipsy, realm: "household")
    post(arguments, agent: agent, realm: realm).tap do |request|
      assert_equal "completed", request.status, request.error.to_s
    end
  end

  test "sync! registers the capability as a native act at household, with the spec's schema" do
    cap = Capability.find_by!(name: "hob.board.post")
    assert cap.native?
    assert_equal Sentinel::Native::BoardPost, cap.handler
    assert_equal "board_post", cap.config["handler"]
    assert_equal "act", cap.kind
    assert_equal "household", cap.realm
    assert_equal %w[body], cap.input_schema["required"]
    assert_equal %w[body links thread_id title].sort, cap.input_schema["properties"].keys.sort
    assert_equal false, cap.input_schema["additionalProperties"]
  end

  # 1. A post to an existing household thread is appended and returned with a server-generated post_id and created_at.
  test "a post to an existing thread is appended and returned with a server-generated post_id and created_at" do
    opened = post!({ "body" => "first", "title" => "Week of Sept 29" })
    thread_id = opened.result["thread_id"]

    request = post!({ "body" => "second", "thread_id" => thread_id })
    assert_equal "completed", request.status, request.error.to_s
    result = request.result
    assert_equal thread_id, result["thread_id"]
    assert result["post_id"].present?
    assert_not_equal opened.result["post_id"], result["post_id"]
    assert result["created_at"].present?
    assert_kind_of Time, Time.iso8601(result["created_at"]), "created_at is ISO8601"

    assert_equal 2, BoardPost.where(thread_id: thread_id).count
  end

  # 2. Omitting thread_id with a title creates a new household-realm thread and the first post in it.
  test "omitting thread_id with a title opens a new household-realm thread and its first post" do
    request = post!({ "body" => "Plan is set through Thursday.", "title" => "Week of Sept 29 — dinners",
                      "links" => [ "https://example.org/recipes/pantry-pasta" ] })
    result = request.result
    assert_equal({
      "body" => "Plan is set through Thursday.", "links" => [ "https://example.org/recipes/pantry-pasta" ],
      "realm" => "household", "title" => "Week of Sept 29 — dinners", "author" => { "agent" => "skipsy", "surface" => "skipsy" },
      "post_id" => result["post_id"], "thread_id" => result["thread_id"], "created_at" => result["created_at"]
    }, result)

    row = BoardPost.find(result["post_id"])
    assert_equal [ result["thread_id"], "household", @skipsy ], [ row.thread_id, row.realm, row.sender_agent ]
    assert_equal 1, BoardPost.where(thread_id: result["thread_id"]).count
  end

  # 3. Omitting both thread_id and title is rejected with a validation error.
  test "omitting both thread_id and title is rejected" do
    request = post({ "body" => "hi" })
    assert_equal "failed", request.status
    assert_match(/title is required to open a new thread/, request.error)
    assert_equal 0, BoardPost.count
  end

  # 4. An author, agent, or sender field supplied in the arguments is ignored; the stored author always matches the authenticated identity.
  test "author-shaped fields in the arguments are refused, not silently ignored" do
    %w[author agent sender sender_agent].each do |field|
      request = post({ "body" => "hi", "title" => "t", field => "marley" })
      assert_equal "failed", request.status, "#{field} should be refused"
      assert_match(/unsupported field\(s\): #{field}/, request.error)
    end
    assert_equal 0, BoardPost.count

    # The real author is whoever authenticated, regardless of who else might poll the same board.
    as_marley = post!({ "body" => "hi", "title" => "t" }, agent: @marley)
    assert_equal({ "agent" => "marley", "surface" => "marley" }, as_marley.result["author"])
  end

  # 5. A link that is not http(s), or more than five links, is rejected.
  test "a non-http(s) link, or more than five links, is rejected" do
    {
      [ "ftp://example.org/x" ] => /links must be http\(s\) URLs, got "ftp:\/\/example\.org\/x"/,
      [ "javascript:alert(1)" ] => /links must be http\(s\) URLs/,
      [ "https://a.example", "not a url" ] => /links must be http\(s\) URLs, got "not a url"/,
      "https://a.example" => /links must be an array/,
      Array.new(6) { |i| "https://example.org/#{i}" } => /links exceeds 5/
    }.each do |links, error|
      request = post({ "body" => "hi", "title" => "t", "links" => links })
      assert_equal "failed", request.status, "#{links.inspect} should be refused"
      assert_match error, request.error
    end
    assert_equal 0, BoardPost.count

    assert_equal 5, post!({ "body" => "hi", "title" => "t", "links" => Array.new(5) { |i| "http://example.org/#{i}" } })
                     .result["links"].size
  end

  # 6. A body over 4000 characters is rejected.
  test "a body over 4000 characters is rejected" do
    request = post({ "body" => "x" * 4001, "title" => "t" })
    assert_equal "failed", request.status
    assert_match(/body must be at most 4000 characters/, request.error)
    assert_equal 0, BoardPost.count

    assert_equal 4000, post!({ "body" => "x" * 4000, "title" => "t" }).result["body"].length
  end

  # 7. Any attachment, file, or binary field in the arguments is rejected rather than silently dropped.
  test "an attachment, file, or binary field is refused rather than silently dropped" do
    %w[attachment attachments file files binary image].each do |field|
      request = post({ "body" => "hi", "title" => "t", field => "aGVsbG8=" })
      assert_equal "failed", request.status, "#{field} should be refused"
      assert_match(/unsupported field\(s\): #{field}/, request.error)
    end
    assert_equal 0, BoardPost.count
  end

  # 8. Posting to a thread above household realm, or to a nonexistent thread, is refused.
  test "a thread above household realm, and a nonexistent thread, are both refused with the identical error" do
    intimate = BoardPost.create!(thread_id: "secret", thread_slug: "big-news", thread_topic: "Big news", realm: "intimate", body: "shh",
                                 sender_agent: @skipsy, surface: "skipsy", created_at: Time.current)

    hidden = post({ "body" => "hi", "thread_id" => "secret" })
    unknown = post({ "body" => "hi", "thread_id" => "does-not-exist" })
    assert_equal "failed", hidden.status
    assert_equal "failed", unknown.status

    not_found = /no thread ".+"/
    assert_match not_found, hidden.error
    assert_match not_found, unknown.error
    refute_match(/Big news/, hidden.error, "the thread's title never leaks into the error")
    assert_equal 1, BoardPost.count, "the intimate fixture, and nothing appended to it"

    # Even an agent whose own clearance is above household cannot reach it: household-only is not a function of ambient clearance.
    Principal.find_by!(name: "skipsy").update!(max_clearance: "intimate")
    above = post({ "body" => "hi", "thread_id" => "secret" }, realm: "intimate")
    assert_equal "failed", above.status
    assert_match not_found, above.error
    assert_equal 1, BoardPost.where(thread_id: "secret").count
    assert_equal "shh", intimate.reload.body, "the fixture itself is untouched"
  end

  # 9. No edit or delete path exists; existing posts are unchanged by any call.
  test "no edit or delete path exists; a post is unchanged by any later call" do
    first = post!({ "body" => "original", "title" => "t" })
    thread_id = first.result["thread_id"]
    row = BoardPost.find(first.result["post_id"])
    original_body = row.body

    post!({ "body" => "a reply, not an edit", "thread_id" => thread_id })
    assert_equal original_body, row.reload.body
    assert_equal 2, BoardPost.where(thread_id: thread_id).count

    assert_nil Sentinel::Native.handler("board_update")
    assert_nil Sentinel::Native.handler("board_delete")
  end

  # 10. Each successful post writes one household audit-log entry.
  test "each successful post writes exactly one household audit-log (sentinel request) entry" do
    before = SentinelRequest.count
    request = post!({ "body" => "hi", "title" => "t" })
    assert_equal before + 1, SentinelRequest.count
    assert_equal "hob.board.post", request.capability.name
    assert_equal "skipsy", request.principal.name
    assert_equal "household", request.realm

    # A refused call still leaves exactly one audit entry, recording the refusal.
    before_failed = SentinelRequest.count
    failed = post({ "body" => "x" * 5000 })
    assert_equal "failed", failed.status
    assert_equal before_failed + 1, SentinelRequest.count
  end

  test "the handler reaches nothing outside hob and makes no model call" do
    post!({ "body" => "hi", "title" => "t" })
    assert_empty @fake.calls
  end

  test "the models keep senders agents, links bounded, and posts append-only" do
    assert_raises(ActiveRecord::RecordInvalid) do
      BoardPost.create!(thread_id: "t", thread_slug: "t", thread_topic: "t", realm: "household", body: "hi", sender_agent: @principal,
                        surface: "x", created_at: Time.current)
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      BoardPost.create!(thread_id: "t", thread_slug: "t", thread_topic: "t", realm: "household", body: "hi", links: [ "ftp://x" ],
                        sender_agent: @skipsy, surface: "x", created_at: Time.current)
    end
    assert BoardPost.create!(thread_id: "t", thread_slug: "t", thread_topic: "t", realm: "household", body: "hi", sender_agent: @skipsy,
                             surface: "skipsy", created_at: Time.current).persisted?
  end

  test "the spec's grant applies: under review the reviewer sees the post, and its verdict decides" do
    SentinelPolicy.delete_all
    policy!(@skipsy, "hob.board.post", "review", guidance: "Household coordination only.")
    @fake.reply('{"verdict": "approve", "rationale": "routine coordination"}')
    ok = post({ "body" => "Friday is open.", "title" => "Week of Sept 29" })
    assert_equal "completed", ok.status, ok.error.to_s
    assert_equal "reviewer", ok.decided_by
    assert_match(/"body": "Friday is open\./, @fake.calls.last.messages.last["content"])
    assert_match(/Household coordination only/, @fake.calls.last.system)

    @fake.reply('{"verdict": "deny", "rationale": "not household business"}')
    assert_equal "denied", post({ "body" => "nope", "title" => "t" }).status
    assert_equal "denied", post({ "body" => "hi", "title" => "t" }, agent: @marley).status, "marley has no policy at all"
    assert_equal 1, BoardPost.count
  end
end
