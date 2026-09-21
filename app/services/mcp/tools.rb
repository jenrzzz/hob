module Mcp
  # The tools that are not capabilities: what a person's key may do over
  # HTTP and no agent is offered (deleting a todo, deciding what a ward
  # finding means). A tool is a Sentinel::Native::Base with a TOOL where a
  # handler has a CAPABILITY, so moving one across is a rename. Adding one is
  # a class under mcp/tools/ and a line here.
  module Tools
    TOOLS = %w[
      Mcp::Tools::TodoDelete
      Mcp::Tools::WardFindings
      Mcp::Tools::WardAck
      Mcp::Tools::WardUnack
    ].freeze

    module_function

    def all
      TOOLS.map(&:constantize).map do |klass|
        Tool.new(name: Mcp.tool_name(klass::TOOL["name"]), spec: klass::TOOL, handler: klass)
      end
    end
  end
end
