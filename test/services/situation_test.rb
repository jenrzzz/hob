require "test_helper"

class SituationTest < ActiveSupport::TestCase
  setup do
    @writer = Situation::Writer.new(principal: @principal, surface: "claude-code", clearance: "intimate")
  end

  def observe(*items, person: @principal, by: @writer)
    Situation.observe(person: person, observations: items, by: by)
  end

  test "facets and topics keep provenance, typed values, realms, and derived context" do
    travel_to Time.iso8601("2026-10-25T21:05:00Z") do
      rows = observe(
        { "kind" => "location", "value" => { "place" => "home", "time_zone" => "America/Los_Angeles" } },
        { "kind" => "location", "value" => { "place" => "the office" }, "realm" => "personal" },
        { "kind" => "company", "value" => { "with" => [ "Tessa", "kids", "kids" ] } },
        { "kind" => "topic", "slot" => "adu-permit",
          "value" => { "text" => "the ADU permit", "detail" => "county says two more weeks" }, "realm" => "personal" }
      )
      assert_equal %w[household personal household personal], rows.map(&:realm)
      assert_equal %w[stated stated stated stated], rows.map(&:basis)
      assert_equal [ "person", "tester", "claude-code" ], rows.first.source.values_at("kind", "by", "surface")
      assert_equal [ "Tessa", "kids" ], rows.third.value["with"]

      state = Situation.get({ "person" => "tester" }, surface: "claude-code")["people"].sole
      assert_equal %w[company location location], state["facets"].map { |facet| facet["kind"] }
      assert_equal [ "adu-permit", "county says two more weeks" ],
                   state["topics"].sole.values_at("slot", "detail")
      assert_equal [ "Sunday afternoon", "desk" ], state["derived"].values_at("day_part", "device")
      assert_equal "2026-10-25T14:05:00-07:00", state.dig("derived", "local_time")
    end
  end

  test "an app write defaults to sensed and cannot put a named place at household" do
    app = Situation::Writer.new(principal: @principal, surface: "app:Jenner's iPhone", clearance: "intimate")
    row = observe({ "kind" => "activity", "value" => { "doing" => "driving" } }, by: app).sole
    assert_equal [ "sensed", "device", "personal" ], [ row.basis, row.source["kind"], row.realm ]

    error = assert_raises(Situation::Invalid) do
      observe({ "kind" => "location", "value" => { "place" => "dentist" }, "realm" => "household" }, by: app)
    end
    assert_match(/below personal/, error.message)
  end

  test "a facet is marked stale for one more TTL, then disappears; a topic expires without stale time" do
    travel_to Time.iso8601("2026-10-25T12:00:00Z") do
      observe({ "kind" => "activity", "value" => { "doing" => "working" }, "ttl" => 3600 },
              { "kind" => "topic", "slot" => "build", "value" => { "text" => "shipping hob" }, "ttl" => 3600 })
    end

    travel_to Time.iso8601("2026-10-25T13:30:00Z") do
      state = Situation.get({ "person" => "tester" })["people"].sole
      assert state["facets"].sole["stale"]
      assert_empty state["topics"]
    end
    travel_to Time.iso8601("2026-10-25T14:00:01Z") do
      assert_empty Situation.get({ "person" => "tester" })["people"].sole["facets"]
    end
  end

  test "an ended or expired newest row never uncovers the older value" do
    travel_to Time.iso8601("2026-10-25T12:00:00Z") do
      observe({ "kind" => "location", "value" => { "place" => "home" }, "ttl" => 10_800 })
    end
    travel_to Time.iso8601("2026-10-25T12:30:00Z") do
      observe({ "kind" => "location", "value" => { "place" => "away" }, "ttl" => 60 })
    end
    travel_to Time.iso8601("2026-10-25T12:32:01Z") do
      assert_empty Situation.get({ "person" => "tester" })["people"].sole["facets"],
                   "the still-live home row must not resurface behind expired away"
    end

    travel_to Time.iso8601("2026-10-25T12:40:00Z") do
      observe({ "kind" => "sleep", "value" => { "state" => "awake" } })
      ended = Situation.end_observation(person: @principal, kind: "sleep", by: @writer)
      assert ended.sole.tombstone?
      assert_empty Situation.get({ "person" => "tester" })["people"].sole["facets"]
    end
  end

  test "ending a facet ends each visible realm and ending again is idempotent" do
    observe(
      { "kind" => "location", "value" => { "place" => "away" } },
      { "kind" => "location", "value" => { "place" => "the office" }, "realm" => "personal" }
    )
    assert_equal %w[household personal], Situation.end_observation(person: @principal, kind: "location", by: @writer).map(&:realm).sort
    assert_empty Situation.end_observation(person: @principal, kind: "location", by: @writer)
  end

  test "topic refresh keeps first_seen while continuous and an ending starts it over" do
    travel_to Time.iso8601("2026-10-20T12:00:00Z") do
      observe({ "kind" => "topic", "slot" => "permit", "value" => { "text" => "waiting on county" } })
    end
    travel_to Time.iso8601("2026-10-21T12:00:00Z") do
      observe({ "kind" => "topic", "slot" => "permit", "value" => { "text" => "county replied" } })
      topic = Situation.get({ "person" => "tester" })["people"].sole["topics"].sole
      assert_equal "2026-10-20T12:00:00Z", topic["first_seen"]
      Situation.end_observation(person: @principal, kind: "topic", slot: "permit", by: @writer)
    end
    travel_to Time.iso8601("2026-10-22T12:00:00Z") do
      observe({ "kind" => "topic", "slot" => "permit", "value" => { "text" => "new filing" } })
      assert_equal "2026-10-22T12:00:00Z",
                   Situation.get({ "person" => "tester" })["people"].sole["topics"].sole["first_seen"]
    end
  end

  test "writes reject unknown fields, malformed values, inference feedback, and realms above clearance" do
    assert_match(/unknown observation field/, assert_raises(Situation::Invalid) {
      observe({ "kind" => "mood", "value" => { "text" => "fine" }, "claim" => "fact" })
    }.message)
    assert_match(/mood.text/, assert_raises(Situation::Invalid) {
      observe({ "kind" => "mood", "value" => { "text" => "" } })
    }.message)
    assert_match(/cannot cite/, assert_raises(Situation::Invalid) {
      observe({ "kind" => "topic", "slot" => "permit", "value" => { "text" => "worried" },
                "basis" => "inferred", "ref" => "situation:abc" })
    }.message)

    household = Situation::Writer.new(principal: @principal, surface: "test", clearance: "household")
    assert_match(/above this request/, assert_raises(Situation::Invalid) {
      observe({ "kind" => "mood", "value" => { "text" => "fine" } }, by: household)
    }.message)
  end

  test "RLS hides higher-realm observations, and an all-people read withholds topics" do
    other = Principal.create!(name: "tessa", kind: "human", max_clearance: "personal")
    observe({ "kind" => "company", "value" => { "with" => [ "kids" ] } }, person: other)
    observe({ "kind" => "mood", "value" => { "text" => "tired" } }, person: other)
    observe({ "kind" => "topic", "slot" => "week", "value" => { "text" => "planning Tuesday" }, "realm" => "personal" }, person: other)

    agent, = agent("marley", clearance: "household")
    as(agent, realm: "household") do
      all = Situation.get({}, requester: agent)["people"].index_by { |state| state["person"] }
      assert_equal [ "company" ], all.fetch("tessa")["facets"].map { |facet| facet["kind"] }
      assert_empty all.fetch("tessa")["topics"]

      one = Situation.get({ "person" => "tessa" }, requester: agent)["people"].sole
      assert_equal [ "company" ], one["facets"].map { |facet| facet["kind"] }
      assert_empty one["topics"], "the personal topic is filtered by RLS"
    end
  end

  test "the retention sweep deletes old rows only" do
    old = nil
    travel_to 31.days.ago do
      old = observe({ "kind" => "mood", "value" => { "text" => "old" } }).sole
    end
    recent = observe({ "kind" => "mood", "value" => { "text" => "now" } }).sole
    assert_operator old.observed_at, :<, Situation::RETENTION.ago
    assert SituationObservation.exists?(old.id)
    assert_equal 1, Situation.sweep!
    assert_not SituationObservation.exists?(old.id)
    assert SituationObservation.exists?(recent.id)
  end

  test "observations are append-only and reads cap topics at twelve per realm" do
    row = observe({ "kind" => "energy", "value" => { "level" => "ok" } }).sole
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(value: { "level" => "high" }) }

    topics = 13.times.map do |index|
      { "kind" => "topic", "slot" => "topic-#{index}", "value" => { "text" => "Topic #{index}" }, "realm" => "personal" }
    end
    observe(*topics)
    returned = Situation.get({ "person" => "tester" })["people"].sole["topics"]
    assert_equal 12, returned.size
    assert_equal (1..12).map { |index| "topic-#{index}" }.sort, returned.map { |topic| topic["slot"] }.sort
  end
end
