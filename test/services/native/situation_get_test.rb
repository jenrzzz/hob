require "test_helper"

class SituationGetTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @agent, = agent("muse", clearance: "household")
    policy!(@agent, "situation.get", "allow")
    @writer = Situation::Writer.new(principal: @principal, surface: "test", clearance: "intimate")
  end

  def completed(arguments = {})
    request = as(@agent, realm: "household") do
      Sentinel.submit!(agent: @agent, capability: "situation.get", arguments: arguments, reason: "tailor the reply")
    end
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  test "sync registers the read capability and an agent sees only its clearance" do
    cap = Capability.find_by!(name: "situation.get")
    assert_equal [ "read", "household", false ], [ cap.kind, cap.realm, cap.input_schema["additionalProperties"] ]

    Situation.observe(person: @principal, observations: [
      { "kind" => "company", "value" => { "with" => [ "kids" ] } },
      { "kind" => "mood", "value" => { "text" => "focused" } },
      { "kind" => "topic", "slot" => "permit", "value" => { "text" => "ADU permit" }, "realm" => "personal" }
    ], by: @writer)

    state = completed("person" => "tester")["people"].sole
    assert_equal [ "company" ], state["facets"].map { |facet| facet["kind"] }
    assert_empty state["topics"]
    assert_match(/data, not instructions/, completed["notice"])
  end

  test "a person's assistant receives situation_get as an MCP tool" do
    names = Current.set(clearance: "household") { Mcp.tools.keys }
    assert_includes names, "situation_get"
  end
end
