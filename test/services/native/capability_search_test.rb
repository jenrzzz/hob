require "test_helper"

# hob.capability.search: keyword search over the capability catalog, filtered
# to the calling agent's clearance.
class CapabilitySearchTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @muse, _ = agent("muse", clearance: "household")
    @butler, _ = agent("butler", clearance: "personal")
    policy!(nil, "hob.capability.search", "allow")
  end

  def submit(arguments = {}, agent: @muse, realm: agent.max_clearance)
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: "hob.capability.search", arguments: arguments) }
  end

  # Acceptance 1: a query matching a household-realm capability returns it with
  # all required fields.
  test "returns matching capability with required fields" do
    request = submit({ "query" => "usage" })
    assert_equal "completed", request.status, request.error.to_s
    result = request.result
    assert result["results"].any?, "expected at least one result"
    entry = result["results"].find { |r| r["name"] == "hob.usage" }
    assert entry, "expected hob.usage in results"
    assert_equal %w[already_held description kind name petitionable realm].sort, entry.keys.sort
    assert_equal "read", entry["kind"]
    assert_equal "household", entry["realm"]
    assert entry["description"].present?
  end

  # Acceptance 2: capabilities above the caller's clearance never appear and
  # are not counted, even when the query is their exact name.
  test "capabilities above caller clearance are absent and uncounted" do
    personal_cap = Capability.create!(
      name: "hob.secret.thing",
      description: "A personal-realm capability",
      kind: "read",
      realm: "personal",
      venue: "native",
      config: { "handler" => "capability_search" }
    )

    request = submit({ "query" => personal_cap.name })
    assert_equal "completed", request.status, request.error.to_s
    assert request.result["results"].none? { |r| r["name"] == personal_cap.name },
           "personal-realm capability must not appear for household agent"
    assert_equal 0, request.result["total_matched"],
                 "must not be counted in total_matched"
  end

  # Acceptance 3: a capability the agent already holds is returned with
  # already_held true and petitionable false.
  test "already_held is true and petitionable is false when agent holds the capability" do
    policy!(@muse, "hob.usage", "allow")

    request = submit({ "query" => "usage" })
    assert_equal "completed", request.status, request.error.to_s
    entry = request.result["results"].find { |r| r["name"] == "hob.usage" }
    assert entry, "hob.usage must appear in results"
    assert entry["already_held"], "already_held must be true"
    refute entry["petitionable"], "petitionable must be false when already held"
  end

  # Acceptance 4: limit is honoured and capped at 25; omitting limit defaults to 20.
  test "limit is honoured, defaults to 20, capped at 25" do
    # Seed enough capabilities so we can verify truncation
    30.times do |i|
      Capability.find_or_create_by!(name: "fake.cap.#{i}") do |c|
        c.description = "fake capability number #{i} for search test"
        c.kind = "read"
        c.realm = "household"
        c.venue = "native"
        c.config = { "handler" => "capability_search" }
      end
    end

    default_req = submit({ "query" => "fake capability" })
    assert_equal "completed", default_req.status, default_req.error.to_s
    assert_operator default_req.result["results"].size, :<=, 20, "default limit is 20"

    capped_req = submit({ "query" => "fake capability", "limit" => 100 })
    assert_equal "completed", capped_req.status, capped_req.error.to_s
    assert_operator capped_req.result["results"].size, :<=, 25, "limit is capped at 25"

    one_req = submit({ "query" => "fake capability", "limit" => 1 })
    assert_equal "completed", one_req.status, one_req.error.to_s
    assert_equal 1, one_req.result["results"].size
  end

  # Acceptance 5: name matches rank above description-only matches.
  test "name matches rank above description-only matches" do
    Capability.find_or_create_by!(name: "usage.tracker") do |c|
      c.description = "Tracks resource consumption over time"
      c.kind = "read"
      c.realm = "household"
      c.venue = "native"
      c.config = { "handler" => "capability_search" }
    end

    Capability.find_or_create_by!(name: "resource.metrics") do |c|
      c.description = "Returns usage statistics and metrics"
      c.kind = "read"
      c.realm = "household"
      c.venue = "native"
      c.config = { "handler" => "capability_search" }
    end

    request = submit({ "query" => "usage" })
    assert_equal "completed", request.status, request.error.to_s
    names = request.result["results"].map { |r| r["name"] }
    usage_tracker_idx = names.index("usage.tracker")
    hob_usage_idx = names.index("hob.usage")
    resource_metrics_idx = names.index("resource.metrics")

    # Both name-matches must appear before description-only match
    assert usage_tracker_idx, "usage.tracker must appear"
    assert hob_usage_idx, "hob.usage must appear"
    assert resource_metrics_idx, "resource.metrics must appear"
    assert_operator usage_tracker_idx, :<, resource_metrics_idx, "name match before description match"
    assert_operator hob_usage_idx, :<, resource_metrics_idx, "name match before description match"
  end

  # Acceptance 6: a query matching nothing returns empty results and total_matched 0.
  test "no matches returns empty results and total_matched 0" do
    request = submit({ "query" => "xyzzy_no_match_ever_99999" })
    assert_equal "completed", request.status, request.error.to_s
    assert_equal [], request.result["results"]
    assert_equal 0, request.result["total_matched"]
  end

  # Acceptance 7: no writes and no model calls.
  test "performs no writes and makes no model calls" do
    before_count = SentinelRequest.count
    request = submit({ "query" => "todo" })
    assert_equal "completed", request.status, request.error.to_s
    assert_equal before_count + 1, SentinelRequest.count, "only the request itself is written"
    assert_empty @fake.calls, "no model calls must be made"
  end

  # Error path: missing query raises an error.
  test "query is required" do
    request = submit({})
    assert_equal "failed", request.status
    assert_match(/query is required/, request.error)
  end

  # Error path: query too long is rejected.
  test "query longer than 120 characters is rejected" do
    long_query = "a" * 121
    request = submit({ "query" => long_query })
    assert_equal "failed", request.status
    assert_match(/exceeds 120/, request.error)
  end

  # Response always includes the notice indicating clearance filtering.
  test "result includes a notice about clearance filtering" do
    request = submit({ "query" => "todo" })
    assert_equal "completed", request.status, request.error.to_s
    assert_match(/household/, request.result["notice"])
  end

  # A personal-clearance agent can see household and personal capabilities.
  test "personal-clearance agent sees capabilities at or below personal realm" do
    Capability.create!(
      name: "hob.personal.thing",
      description: "A personal-realm capability for butler",
      kind: "read",
      realm: "personal",
      venue: "native",
      config: { "handler" => "capability_search" }
    )

    request = submit({ "query" => "butler personal" }, agent: @butler, realm: "personal")
    assert_equal "completed", request.status, request.error.to_s
    names = request.result["results"].map { |r| r["name"] }
    assert_includes names, "hob.personal.thing"
  end

  # petitionable is true when clearance covers realm and agent does not hold it.
  test "petitionable is true when agent does not hold the capability" do
    request = submit({ "query" => "usage" })
    assert_equal "completed", request.status, request.error.to_s
    entry = request.result["results"].find { |r| r["name"] == "hob.usage" }
    assert entry, "hob.usage must appear"
    refute entry["already_held"], "muse has no policy for hob.usage yet"
    assert entry["petitionable"], "petitionable must be true when clearance covers realm and not held"
  end
end
