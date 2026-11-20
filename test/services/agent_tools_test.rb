require "test_helper"

# A persona that is also an agent (MELUZINA.md, "Her agent"): the agent's
# sentinel tools in her own turns, gated and written down under its name.
class AgentToolsTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @agent, _token = agent("meluzina", clearance: "personal")
    @mel = persona("mel")
    @mel.update!(tools: { "agent" => "meluzina" })
  end

  def turn(content, convo: conversation(realm: "personal"), tools: nil)
    ChatTurn.new(conversation: convo, branch: convo.branch, persona: @mel, content: content, tools: tools).call
  end

  def offered
    @fake.calls.first.tools.map { |t| t["name"] }
  end

  test "an agent with nothing to ask for offers nothing" do
    @fake.reply("hi")
    turn("hello")
    assert_empty Array(@fake.calls.first.tools)
  end

  test "her granted capabilities are tools in her turn, asked for under the agent's name" do
    policy!(@agent, "hob.capability.search", "allow")
    @fake.call_tools([ { id: "s1", name: "hob_capability_search", arguments: { query: "board", reason: "curious" } } ])
    @fake.reply("there's a board")
    result = turn("what can you do?")

    assert_equal "success", result.status
    assert_equal %w[hob_capability_search sentinel_request], offered.sort
    refute result.native.first["error"], result.native.first["content"]
    assert JSON.parse(result.native.first["content"])["results"]

    request = @agent.sentinel_requests.sole
    assert_equal "hob.capability.search", request.capability.name
    assert_equal "curious", request.reason
    assert_equal "test", request.surface, "the ledger says where she was asked from"
    assert_equal "personal", request.realm
  end

  test "she petitions in her turn; at intimate she still asks at her own clearance" do
    policy!(@agent, "sentinel.petition", "confirm")
    @fake.call_tools([ { id: "p1", name: "sentinel_petition",
                         arguments: { want: "read his todo list", capability: "todo.list", reason: "he asked" } } ])
    @fake.reply({ "action" => "grant", "rationale" => "fine", "capability" => "todo.list", "effect" => "allow",
                  "constraints_json" => "{}", "limits_json" => "{}", "guidance" => "", "spec" => nil }.to_json)
    @fake.reply("I asked")
    result = turn("can you see my todos?", convo: conversation(realm: "intimate"))

    assert_includes offered, "sentinel_petition"
    answer = JSON.parse(result.native.first["content"])
    assert_equal "pending", answer["status"], "a confirm charter refers it to a person"
    petition = @agent.petitions.sole
    assert_equal "personal", petition.realm
    assert_equal "he asked", petition.reason
  end

  test "a household conversation lowers what she is offered" do
    policy!(@agent, "hob.board.*", "allow")
    Capability.find_by!(name: "hob.board.read").update!(realm: "personal")
    @fake.reply("ok")
    turn("hi", convo: conversation(realm: "household"))
    refute_includes offered, "hob_board_read", "a personal capability is not offered in a household conversation"
    assert_includes offered, "hob_board_post"
  end

  test "a caller's tool by the same name wins, and the turn goes on" do
    policy!(@agent, "hob.capability.search", "allow")
    @fake.reply("ok")
    mine = [ { "name" => "hob_capability_search", "description" => "mine", "input_schema" => { "type" => "object" } } ]
    result = turn("hi", tools: mine)
    assert_equal "success", result.status
    assert_equal [ "mine" ], @fake.calls.first.tools.select { |t| t["name"] == "hob_capability_search" }.map { |t| t["description"] }
  end

  test "the link names an agent, not a person or nobody" do
    assert_not @mel.update(tools: { "agent" => "jenner" })
    assert_not @mel.update(tools: { "agent" => "nobody" })
    assert_not @mel.update(tools: { "agent" => 3 })
    assert @mel.update(tools: { "agent" => "meluzina" })
  end
end
