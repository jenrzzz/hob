module Mcp
  # hob as an MCP server for an *agent* (CLAUDE_CODE.md, "Agents"): Claude
  # Code, Codex, or musecode holding an agent's key rather than a person's,
  # so that what it writes (a board post, a message) is stamped with its own
  # name and it is gated like any other agent. Every tools/call is a
  # Sentinel.submit!: policy decides, the executor runs it, and the request
  # row is the ledger. Nothing here runs a handler directly.
  #
  # The tools are the enabled capabilities at the agent's clearance that
  # some policy lets it ask for (anything but deny), so a coding agent
  # granted `hob.board.*` sees the board and nothing else. Plus
  # `sentinel_request`, for a request a person has yet to confirm: an
  # agent may always read its own requests, as on GET /v1/sentinel/requests.
  module Agent
    # Why the agent is asking, for the reviewer and the ledger. Added to
    # every capability's schema and taken off again before the handler sees
    # the arguments.
    REASON = "reason"
    REASON_PROPERTY = {
      "type" => "string", "maxLength" => 1000,
      "description" => "Why you are asking, in a sentence. hob's sentinel reads it when it reviews the request."
    }.freeze

    # A claim that the person already said yes in chat (SENTINEL.md, "User-
    # authorization claims"), offered only to agents allowed to make one,
    # and taken off the arguments like REASON, to go to the sentinel as
    # Sentinel.submit!'s user_authorization.
    USER_AUTHORIZATION = "user_authorization"
    USER_AUTHORIZATION_PROPERTY = {
      "type" => "object",
      "description" => "Only when the person already authorized this exact action in chat: their message verbatim " \
                       "(quote), when they sent it (quoted_at, ISO 8601), what you proposed just before (context), what you " \
                       "take it to authorize (interpretation), and the action it supports (action_ref). It is logged, " \
                       "judged, and sometimes put back to the person to confirm; a made-up quote freezes you.",
      "required" => Sentinel::Claims::REQUIRED_FIELDS,
      "properties" => Sentinel::Claims::REQUIRED_FIELDS.index_with { { "type" => "string" } }
    }.freeze

    REQUEST_TOOL = {
      "name" => "sentinel_request",
      "description" => "Look up one of your own earlier requests by id: its status (pending, executing, completed, " \
                       "failed, denied), and its result once settled. Use it when a tool answered that a person must " \
                       "confirm, or that the work was queued. wait holds the call up to that many seconds for it to settle.",
      "inputSchema" => {
        "type" => "object",
        "required" => %w[id],
        "properties" => {
          "id" => { "type" => "string", "description" => "The request id a tool answered with." },
          "wait" => { "type" => "integer", "minimum" => 0, "maximum" => 25, "default" => 0 }
        },
        "additionalProperties" => false
      },
      "annotations" => { "readOnlyHint" => true, "destructiveHint" => false }
    }.freeze

    module_function

    # -> { tool name => Capability } the agent may ask for at `clearance`.
    def capabilities(agent, clearance)
      rank = Realm.rank_of(clearance)
      rules = SentinelPolicy.where(principal_id: [ agent.id, nil ]).to_a
      return {} if rules.empty?

      Capability.enabled.order(:name).select do |capability|
        next false if capability.realm_rank > rank

        rule = SentinelPolicy.resolve(principal: agent, capability: capability.name, rules: rules)
        rule && rule.effect != "deny"
      end.index_by { |capability| Mcp.tool_name(capability.name) }
    end

    def tools(agent, clearance)
      claimant = Sentinel::Claims::KNOWN_AGENTS.include?(agent.name)
      capabilities(agent, clearance).map { |name, capability| as_json(name, capability, claimant: claimant) } + [ REQUEST_TOOL ]
    end

    def as_json(name, capability, claimant: false)
      schema = capability.input_schema.presence || { "type" => "object" }
      unless schema.dig("properties", REASON)
        schema = schema.merge("properties" => (schema["properties"] || {}).merge(REASON => REASON_PROPERTY))
      end
      if claimant && !capability.input_schema&.dig("properties", USER_AUTHORIZATION)
        schema = schema.merge("properties" => schema["properties"].merge(USER_AUTHORIZATION => USER_AUTHORIZATION_PROPERTY))
      end
      {
        "name" => name, "title" => capability.name, "description" => capability.description, "inputSchema" => schema,
        "annotations" => { "readOnlyHint" => capability.kind == "read", "destructiveHint" => false }
      }
    end

    # -> [answer, is_error]. Raises UnknownTool for a tool the agent was not
    # offered, and Sentinel::Invalid for a request that could not be filed.
    def call(agent, clearance, name, arguments)
      arguments = (arguments || {}).to_h.deep_stringify_keys
      return request_status(agent, arguments) if name.to_s == REQUEST_TOOL["name"]

      capability = capabilities(agent, clearance)[name.to_s] or raise UnknownTool, "no tool named #{name.to_s.inspect}"
      reason = capability.input_schema&.dig("properties", REASON) ? nil : arguments.delete(REASON)
      claim = capability.input_schema&.dig("properties", USER_AUTHORIZATION) ? nil : arguments.delete(USER_AUTHORIZATION)
      request = Sentinel.submit!(agent: agent, capability: capability.name, arguments: arguments, reason: reason,
                                 user_authorization: claim)
      outcome(request)
    end

    # What a request came to, as the model should read it. Completed is the
    # handler's result, as it would be on the person's endpoint; denied and
    # failed are errors it can read; pending and executing are not errors,
    # but say how to find out.
    def outcome(request)
      case request.status
      when "completed" then [ request.result, false ]
      when "denied" then [ "denied (#{request.decided_by}): #{request.rationale}", true ]
      when "failed" then [ "failed: #{request.error}", true ]
      else
        note = request.pending? ? "a person must confirm this before it runs" : "queued for #{request.capability.name}'s worker"
        [ { "status" => request.status, "request" => request.id,
            "note" => "#{note}; check on it with sentinel_request, or carry on and check later" }, false ]
      end
    end

    def request_status(agent, arguments)
      id = arguments["id"]
      raise Sentinel::Invalid, "id is required" if id.blank?

      request = agent.sentinel_requests.find(id)
      wait = arguments["wait"].to_i.clamp(0, 25)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
      until request.settled? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 1
        request.reload
      end
      outcome(request)
    end
  end
end
