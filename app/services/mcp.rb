# hob as an MCP server (CLAUDE_CODE.md): what a person's own assistant, Claude
# Code first, is handed as tools. The list is not written here. It is the
# native capabilities (Sentinel::Native) and the webhook ones surfaces
# registered (mise's, say) visible at the request's clearance, so a
# capability built for outside agents is a tool the day it lands, plus the
# few things only a person may do (Mcp::Tools).
#
# A person's key is not an agent's: nothing here passes the sentinel's gate,
# and nothing is written to its ledger. The call runs as the person, at the
# request's clearance, the way /v1/todos would; RLS decides what it can see.
# A webhook tool is delivered to its surface signed as the sentinel would
# deliver it, naming the person as the caller and `decided_by: person`.
module Mcp
  class Error < StandardError; end
  class UnknownTool < Error; end

  # Capabilities that only mean something between agents.
  AGENTS_ONLY = %w[hob.agent.message].freeze

  # What a tool's failure may say to the caller: the same answers the
  # sentinel's executor gives an agent. Anything else is a fault in hob.
  ANSWERS = [ *Sentinel::Executor::ANSWERS, Sentinel::Native::Error, Ward::Error ].freeze

  # What a handler is given where the sentinel would hand it a request: the
  # arguments, and who is asking. There is no request row, so no id, no
  # reason, and no mission; the decision was the person's own.
  Call = Struct.new(:arguments, :principal, :surface, :realm, :capability, keyword_init: true) do
    def id = nil
    def ref = nil
    def reason = nil
    def decided_by = "person"
    def on_mission_id = nil
  end

  # The handler for a webhook capability: the same signed delivery the
  # executor makes for an agent, with the person as its caller.
  class WebhookHandler
    def initialize(call)
      @call = call
    end

    def call
      Sentinel::Webhook.deliver(@call.capability, @call)
    end
  end

  Tool = Struct.new(:name, :spec, :handler, :capability, keyword_init: true) do
    def as_json(*)
      {
        "name" => name, "title" => spec["name"], "description" => spec["description"], "inputSchema" => spec["input_schema"],
        "annotations" => { "readOnlyHint" => spec["kind"] == "read", "destructiveHint" => spec["destructive"] == true }
      }
    end
  end

  module_function

  # The tools visible at `clearance`, by name. A capability's row says its
  # realm and whether it is enabled, so a household's tuning holds here too.
  def tools(clearance = Current.clearance)
    rank = Realm.rank_of(clearance)
    (capability_tools + Tools.all).select { |tool| Realm.rank_of(tool.spec["realm"]) <= rank }.index_by(&:name)
  end

  # -> the handler's result, a JSON-able Hash. Raises UnknownTool, or one of
  # ANSWERS for the caller to read.
  def call(name, arguments)
    tool = tools[name.to_s] or raise UnknownTool, "no tool named #{name.to_s.inspect}"
    call = Call.new(arguments: (arguments || {}).to_h.deep_stringify_keys, principal: Current.principal,
                    surface: Current.surface, realm: Current.clearance, capability: tool.capability)
    tool.handler.new(call).call
  end

  # MCP tool names have no dots: todo.list is todo_list.
  def tool_name(capability_name)
    capability_name.tr(".", "_")
  end

  def capability_tools
    Capability.enabled.where(venue: %w[native webhook]).where.not(name: AGENTS_ONLY).order(:name).filter_map do |capability|
      handler = capability.native? ? capability.handler : WebhookHandler
      next if handler.nil?

      spec = (capability.native? ? handler::CAPABILITY : {}).merge(
        "name" => capability.name, "description" => capability.description, "input_schema" => capability.input_schema,
        "kind" => capability.kind, "realm" => capability.realm
      )
      Tool.new(name: tool_name(capability.name), spec: spec, handler: handler, capability: capability)
    end
  end
end
