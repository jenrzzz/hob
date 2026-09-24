require "test_helper"

# hob.board.read (SENTINEL.md): the household message board skipsy and
# Marley share. RLS on board_posts (realm column) is what actually keeps
# personal/intimate threads out of sight; the handler adds no filtering of
# its own and performs no writes.
class BoardReadTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @skipsy, _ = agent("skipsy")
    @marley, _ = agent("marley")
    @jenner = @principal
    @tessa = Principal.create!(name: "tessa", kind: "human", max_clearance: "intimate")
    policy!(nil, "hob.board.read", "allow")
  end

  def read(arguments = {}, agent: @skipsy, realm: "household")
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: "hob.board.read", arguments: arguments) }
  end

  def post!(thread:, slug:, topic:, body: "hi", sender: @marley, principal: @tessa, links: [], realm: "household", created_at: Time.current)
    BoardPost.create!(thread_id: thread, thread_slug: slug, thread_topic: topic, realm: realm, body: body, links: links,
                      sender_agent: sender, sender_principal: principal, created_at: created_at)
  end

  test "sync! registers the capability as a native read at household, with the spec's schema" do
    cap = Capability.find_by!(name: "hob.board.read")
    assert cap.native?
    assert_equal Sentinel::Native::BoardRead, cap.handler
    assert_equal "board_read", cap.config["handler"]
    assert_equal "read", cap.kind
    assert_equal "household", cap.realm
    assert_equal false, cap.input_schema["additionalProperties"]
    assert_equal %w[limit since thread].sort, cap.input_schema["properties"].keys.sort
    assert_nil cap.input_schema["required"]
  end

  # 1. With no arguments, returns the thread index ordered by last_post_at descending, with no post bodies included.
  test "no thread argument returns the thread index, newest activity first, with no post bodies" do
    post!(thread: "t1", slug: "birthday-gifts", topic: "Birthday gifts", body: "shortlist", created_at: 2.days.ago)
    post!(thread: "t1", slug: "birthday-gifts", topic: "Birthday gifts", body: "teapot it is", created_at: 1.day.ago)
    post!(thread: "t2", slug: "dinner-plans", topic: "Dinner plans", body: "tacos?", created_at: 3.days.ago)

    request = read
    assert_equal "completed", request.status, request.error.to_s
    threads = request.result["threads"]
    assert_equal %w[birthday-gifts dinner-plans], threads.map { |t| t["slug"] }, "most recently active thread first"
    assert_equal [ "t1", "birthday-gifts", "Birthday gifts", 2 ], threads.first.values_at("id", "slug", "topic", "post_count")
    assert_equal 1, threads.last["post_count"]
    assert threads.all? { |t| t.keys.sort == %w[id last_post_at post_count slug topic] }, "no post bodies in the index"
  end

  # 2. With a valid thread slug, returns that thread's posts in ascending created_at order, each carrying sender_agent and sender_principal.
  test "a valid thread slug returns its posts in ascending order, stamped with sender agent and principal" do
    post!(thread: "t1", slug: "birthday-gifts", topic: "Birthday gifts", body: "shortlist", sender: @marley, principal: @tessa,
          links: [ "https://example.com/teapot" ], created_at: 2.days.ago)
    post!(thread: "t1", slug: "birthday-gifts", topic: "Birthday gifts", body: "teapot it is", sender: @skipsy, principal: @jenner,
          created_at: 1.day.ago)

    request = read({ "thread" => "birthday-gifts" })
    assert_equal "completed", request.status, request.error.to_s
    posts = request.result["posts"]
    assert_equal [ "shortlist", "teapot it is" ], posts.map { |p| p["body"] }, "ascending by created_at"
    assert_equal [ "marley", "tessa" ], posts.first.values_at("sender_agent", "sender_principal")
    assert_equal [ "skipsy", @jenner.name ], posts.last.values_at("sender_agent", "sender_principal")
    assert_equal [ "https://example.com/teapot" ], posts.first["links"]
    assert_equal [], posts.last["links"]

    thread = request.result["thread"]
    assert_equal [ "t1", "birthday-gifts", "Birthday gifts", 2 ], thread.values_at("id", "slug", "topic", "post_count")

    # Resolving by the opaque thread id works the same as the slug.
    by_id = read({ "thread" => "t1" })
    assert_equal posts, by_id.result["posts"]
  end

  # 3. `since` excludes posts at or before that instant and next_since equals the newest returned post's created_at.
  test "since excludes posts at or before that instant, and next_since tracks the newest returned post" do
    t1 = post!(thread: "t1", slug: "birthday-gifts", topic: "Birthday gifts", body: "first", created_at: 3.days.ago.change(usec: 0))
    post!(thread: "t1", slug: "birthday-gifts", topic: "Birthday gifts", body: "second", created_at: 2.days.ago.change(usec: 0))
    t3 = post!(thread: "t1", slug: "birthday-gifts", topic: "Birthday gifts", body: "third", created_at: 1.day.ago.change(usec: 0))

    request = read({ "thread" => "birthday-gifts", "since" => t1.created_at.iso8601 })
    assert_equal "completed", request.status, request.error.to_s
    assert_equal [ "second", "third" ], request.result["posts"].map { |p| p["body"] }, "excludes the post at the since instant"
    assert_equal t3.created_at.utc.iso8601, request.result["next_since"], "the newest post in the returned set, not the since bound"

    # since exactly at the newest post excludes everything and next_since is absent.
    exhausted = read({ "thread" => "birthday-gifts", "since" => 1.hour.ago.iso8601 })
    assert_equal [], exhausted.result["posts"]
    assert_nil exhausted.result["next_since"]
  end

  # 4. `limit` is honoured and values above 200 are rejected or clamped to 200.
  test "limit is honoured, defaults sanely, and values above 200 are clamped" do
    5.times { |i| post!(thread: "t1", slug: "birthday-gifts", topic: "Birthday gifts", body: "post #{i}", created_at: i.days.ago) }

    limited = read({ "thread" => "birthday-gifts", "limit" => 2 })
    assert_equal 2, limited.result["posts"].size

    over = read({ "thread" => "birthday-gifts", "limit" => 500 })
    assert_equal "completed", over.status, over.error.to_s
    assert_equal 5, over.result["posts"].size, "clamped to 200, well above the 5 that exist"

    zero = read({ "thread" => "birthday-gifts", "limit" => 0 })
    assert_equal "failed", zero.status
    assert_match(/limit must be at least 1/, zero.error)

    bad_type = read({ "limit" => "lots" })
    assert_equal "failed", bad_type.status
    assert_match(/limit must be an integer/, bad_type.error)
  end

  # 5. A thread stored above household realm, and a nonexistent thread, both return the same not_found error with no leaked metadata.
  test "a thread above household realm and an unknown thread give the identical error, leaking nothing" do
    post!(thread: "secret", slug: "pregnancy-news", topic: "Big news", realm: "intimate")

    hidden = read({ "thread" => "pregnancy-news" })
    assert_equal "failed", hidden.status
    unknown = read({ "thread" => "does-not-exist" })
    assert_equal "failed", unknown.status

    not_found = /no thread ".+"/
    assert_match not_found, hidden.error
    assert_match not_found, unknown.error
    refute_match(/Big news/, hidden.error, "the thread's topic never leaks into the error, only what the caller already typed")

    # Also true by id: the same shape of error, not a different one that would
    # confirm the id exists.
    by_id = read({ "thread" => "secret" })
    assert_match not_found, by_id.error
  end

  # 6. The handler performs no writes and makes no outbound network or model calls.
  test "performs no writes and makes no model calls" do
    post!(thread: "t1", slug: "birthday-gifts", topic: "Birthday gifts")
    before = BoardPost.count

    index = read
    assert_equal "completed", index.status, index.error.to_s
    thread = read({ "thread" => "birthday-gifts" })
    assert_equal "completed", thread.status, thread.error.to_s

    assert_equal before, BoardPost.count
    assert_empty @fake.calls
  end

  test "a thread argument that is not a string is refused" do
    request = read({ "thread" => [ "birthday-gifts" ] })
    assert_equal "failed", request.status
    assert_match(/thread must be a string/, request.error)
  end

  test "a since that is not a valid ISO8601 date-time is refused" do
    post!(thread: "t1", slug: "birthday-gifts", topic: "Birthday gifts")
    request = read({ "thread" => "birthday-gifts", "since" => "soonish" })
    assert_equal "failed", request.status
    assert_match(/since must be an ISO8601 date-time, got "soonish"/, request.error)
  end

  test "an empty board returns an empty thread index, not an error" do
    request = read
    assert_equal "completed", request.status, request.error.to_s
    assert_equal [], request.result["threads"]
  end
end
