# A persona that is also an agent (MELUZINA.md, "Her agent"): what the
# sentinel lets that agent ask for, as native tools in the persona's turns.
# `personas.tools`:
#
#   { "agent" => "meluzina" }
#
# The tools are the agent's on hob's MCP endpoint (Mcp::Agent): the
# capabilities its rules offer, sentinel_request, and, when its charter
# allows, sentinel_petition and sentinel_petition_status. Every call is
# Sentinel.submit! or Sentinel.petition! under the agent's name, gated and
# written down like any agent's; the turn's surface is kept, so the ledger
# says where she was asked from.
#
# The agent acts at the lowest of the caller's clearance, the conversation's
# realm, and its own grant: what comes back lands in the conversation's
# nodes, which anyone cleared for the conversation can read.
class AgentTools
  Outcome = Memory::Tools::Outcome

  # Checks a persona's `tools` config. -> problems, empty when it reads.
  def self.problems(config)
    name = config.to_h.stringify_keys["agent"]
    return [] if name.nil?
    return [ "agent must be an agent's name" ] unless name.is_a?(String) && name.present?

    principal = Principal.find_by(name: name)
    return [ "agent #{name} is not a principal" ] if principal.nil?
    return [ "agent #{name} is a #{principal.kind}, not an agent" ] unless principal.agent?

    []
  end

  # -> an AgentTools, or nil when the turn has no single persona with an
  # agent, or the agent has nothing to ask for. `taken` are names other
  # native venues already answer; a capability tool by one of those names is
  # not offered.
  def self.build(personas:, conversation:, taken: [])
    personas = Array(personas).compact
    return nil unless personas.one?

    name = personas.first.tools.to_h.stringify_keys["agent"].presence or return nil
    agent = Principal.find_by(name: name, kind: "agent") or return nil

    realm = [ Clearance.current, conversation.realm, agent.max_clearance ].compact.min_by { |r| Realm.rank_of(r) }
    tools = Mcp::Agent.tools(agent, realm).reject { |t| taken.include?(t["name"]) }
    return nil if tools.map { |t| t["name"] } == [ Mcp::Agent::REQUEST_TOOL["name"] ]

    new(agent: agent, realm: realm, tools: tools)
  end

  def initialize(agent:, realm:, tools:)
    @agent = agent
    @realm = realm
    @tools = tools.index_by { |t| t["name"] }
  end

  def names
    @tools.keys
  end

  def native?(name)
    @tools.key?(name.to_s)
  end

  # A capability tool whose name the caller's own tool already uses steps
  # aside instead of failing the turn: the caller cannot know what the
  # agent will be granted next.
  def yield_to!(names)
    @tools.except!(*names)
  end

  def defs
    @tools.values.map do |tool|
      { "name" => tool["name"], "description" => tool["description"], "input_schema" => tool["inputSchema"] }
    end
  end

  # -> Outcome
  def execute(call, node: nil)
    args = (call["arguments"] || {}).to_h
    answer, error, images = Clearance.with(@realm) do
      Current.set(principal: @agent, clearance: @realm) { Mcp::Agent.call(@agent, @realm, call["name"], args) }
    end
    Outcome.new(call: call, content: content(answer, images), error: error)
  rescue Mcp::Agent::UnknownTool, Sentinel::Invalid, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid => e
    Outcome.new(call: call, content: JSON.generate("error" => e.message), error: true)
  end

  private

  def content(answer, images)
    text = answer.is_a?(String) ? answer : JSON.generate(answer)
    return text if images.blank?

    [ { "type" => "text", "text" => text } ] +
      images.map { |i| { "type" => "image", "media_type" => i["mimeType"], "data" => i["data"] } }
  end
end
