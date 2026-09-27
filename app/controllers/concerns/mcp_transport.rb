# MCP's streamable HTTP transport as hob speaks it (CLAUDE_CODE.md): no
# session and no stream. Each POST is one JSON-RPC message and its answer is
# one JSON body.
#
#   POST   initialize · ping · tools/list · tools/call   → 200, a JSON-RPC response
#          a notification, or a response                  → 202
#   GET, DELETE    405: there is no stream to open and no session to end
#
# The including controller says what its tools are and how one runs:
#
#   mcp_tools              → [ { "name", "description", "inputSchema", ... } ]
#   mcp_call(name, args)   → [ a JSON-able answer, is_error ]; raises
#                            Mcp::UnknownTool for a name it lacks
#   mcp_instructions       → what the model is told on initialize
#   mcp_answers            → exception classes that are answers, not faults
#
# A tool that fails is an answer (`isError`), not a JSON-RPC error: the
# model reads it and tries something else. A tool that does not exist, or a
# fault in hob, is an error.
module McpTransport
  extend ActiveSupport::Concern

  PROTOCOLS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze

  PARSE_ERROR = -32_700
  INVALID_REQUEST = -32_600
  METHOD_NOT_FOUND = -32_601
  INVALID_PARAMS = -32_602
  INTERNAL_ERROR = -32_603

  included do
    before_action :known_clearance!

    # The body is a JSON-RPC message, not a resource's attributes.
    wrap_parameters false
  end

  def create
    message = JSON.parse(request.raw_post)
    return render_error(nil, INVALID_REQUEST, "one message per request: batches are not supported") unless message.is_a?(Hash)
    return head :accepted unless message.key?("method") && message.key?("id")

    answer(message)
  rescue JSON::ParserError
    render_error(nil, PARSE_ERROR, "the body is not JSON")
  end

  def unsupported
    response.headers["Allow"] = "POST"
    head :method_not_allowed
  end

  private

  # Elsewhere an X-Hob-Clearance that names no realm is ignored, and the
  # request runs at the key's own clearance. Here the cap is how a person
  # keeps an assistant out of a realm, so a misspelt one must not quietly
  # mean "everything": it is refused.
  def known_clearance!
    cap = request.headers["X-Hob-Clearance"]
    return if cap.blank?

    Realm.rank_of(cap)
  rescue ArgumentError
    render json: { error: "X-Hob-Clearance names no realm: #{cap.inspect}" }, status: :bad_request
  end

  def answer(message)
    id, params = message["id"], message["params"] || {}
    case message["method"]
    when "initialize" then render_result(id, handshake(params))
    when "ping" then render_result(id, {})
    when "tools/list" then render_result(id, "tools" => mcp_tools)
    when "tools/call" then call_tool(id, params)
    else render_error(id, METHOD_NOT_FOUND, "hob does not answer #{message['method'].inspect}")
    end
  end

  def handshake(params)
    requested = params["protocolVersion"]
    {
      "protocolVersion" => PROTOCOLS.include?(requested) ? requested : PROTOCOLS.first,
      "capabilities" => { "tools" => { "listChanged" => false } },
      "serverInfo" => { "name" => "hob", "version" => ENV["SOURCE_COMMIT"].presence&.first(12) || "dev" },
      "instructions" => mcp_instructions
    }
  end

  def call_tool(id, params)
    result, is_error = mcp_call(params["name"], params["arguments"])
    text = result.is_a?(String) ? result : result.to_json
    render_result(id, "content" => [ { "type" => "text", "text" => text } ], "isError" => is_error)
  rescue Mcp::UnknownTool => e
    render_error(id, INVALID_PARAMS, e.message)
  rescue *mcp_answers => e
    render_result(id, "content" => [ { "type" => "text", "text" => "#{e.class.name.demodulize}: #{e.message}" } ], "isError" => true)
  rescue StandardError => e
    Rails.error.report(e, handled: true, severity: :error, source: "hob.mcp", context: { tool: params["name"] })
    render_error(id, INTERNAL_ERROR, "hob failed running #{params['name']}")
  end

  def render_result(id, result)
    render json: { "jsonrpc" => "2.0", "id" => id, "result" => result }
  end

  def render_error(id, code, message)
    render json: { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }
  end
end
