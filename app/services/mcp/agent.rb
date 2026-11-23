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
  # And, for an agent whose charter lets it petition (SENTINEL.md,
  # "Petitions and the forge"), `sentinel_petition` and
  # `sentinel_petition_status`: POST and GET /v1/sentinel/petitions.
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

    PETITION_TOOL = {
      "name" => "sentinel_petition",
      "description" => "Ask hob for a capability you do not have, or for a grant you hold to cover more (a wider " \
                       "constraint, a broader scope). Petition only when no tool you have does what you need; search " \
                       "with hob_capability_search first when you have it. Say what you want to be able to do and why. " \
                       "The steward grants, builds, refers it to a person, or denies it. A denial is final: do not " \
                       "petition again for the same thing in other words. Petitions are limited per day.",
      "inputSchema" => {
        "type" => "object",
        "required" => %w[want reason],
        "properties" => {
          "want" => { "type" => "string", "minLength" => 1, "maxLength" => 4000,
                      "description" => "What you want to be able to do, in plain words." },
          "capability" => { "type" => "string", "maxLength" => 120,
                            "description" => "The capability's name (dotted, e.g. note.search) when you know it." },
          "arguments" => { "type" => "object",
                           "description" => "Example arguments you would call it with, so the grant can be scoped to them." },
          "reason" => { "type" => "string", "maxLength" => 1000,
                        "description" => "Why you need it: what you are doing and for whom." }
        },
        "additionalProperties" => false
      },
      "annotations" => { "readOnlyHint" => false, "destructiveHint" => false }
    }.freeze

    PETITION_STATUS_TOOL = {
      "name" => "sentinel_petition_status",
      "description" => "Look up one of your own petitions by id: pending (the steward is still deciding, or a person will), granted, building " \
                       "(the forge is making it; this takes days), proposed (built, awaiting merge), denied, or failed. " \
                       "wait holds the call up to that many seconds for it to be decided.",
      "inputSchema" => {
        "type" => "object",
        "required" => %w[id],
        "properties" => {
          "id" => { "type" => "string", "description" => "The petition id sentinel_petition answered with." },
          "wait" => { "type" => "integer", "minimum" => 0, "maximum" => 25, "default" => 0 }
        },
        "additionalProperties" => false
      },
      "annotations" => { "readOnlyHint" => true, "destructiveHint" => false }
    }.freeze

    PETITION_DECIDING = "filed, and the steward is still deciding: do not petition again. Ask " \
                        "sentinel_petition_status with this id and wait: 25".freeze

    PETITION_NOTES = {
      "granted" => "granted: you may ask for it now. If it is not among your tools yet, your client has to list " \
                   "tools again (reconnect) before it appears",
      "pending" => "a person will decide; check with sentinel_petition_status, or carry on without it for now",
      "building" => "the forge is building it, which takes hours to days; finish without it and check another day",
      "proposed" => "built and awaiting a person's merge; finish without it and check another day",
      "failed" => "the build failed; a person will look. Do without it for now"
    }.freeze

    module_function

    # Whether the agent's charter lets it petition at all: the rule the
    # steward reads (Sentinel::Steward::CHARTER), resolved the same way.
    def petitions?(agent)
      rule = SentinelPolicy.resolve(principal: agent, capability: Sentinel::Steward::CHARTER)
      rule.present? && rule.effect != "deny"
    end

    # -> { tool name => Capability } the agent may ask for at `clearance`.
    def capabilities(agent, clearance)
      rank = Realm.rank_of(clearance)
      rules = SentinelPolicy.where(principal_id: [ agent.id, nil ]).to_a
      return {} if rules.empty?

      Capability.offered_to(agent).order(:name).select do |capability|
        next false if capability.realm_rank > rank

        rule = SentinelPolicy.resolve(principal: agent, capability: capability.name, rules: rules)
        rule && rule.effect != "deny"
      end.index_by { |capability| Mcp.tool_name(capability.name) }
    end

    def tools(agent, clearance)
      claimant = Sentinel::Claims::KNOWN_AGENTS.include?(agent.name)
      rules = SentinelPolicy.where(principal_id: [ agent.id, nil ]).to_a
      tools = capabilities(agent, clearance).map do |name, capability|
        rule = SentinelPolicy.resolve(principal: agent, capability: capability.name, rules: rules)
        as_json(name, capability, claimant: claimant, bounds: rule&.bounds)
      end
      tools << REQUEST_TOOL
      tools += [ PETITION_TOOL, PETITION_STATUS_TOOL ] if petitions?(agent)
      tools
    end

    # `bounds` is the agent's own grant in words (SentinelPolicy#bounds): said
    # with the tool, so a call outside it is not how the agent finds out
    # (skipsy, 2026-11-19: 146 denials of `approved: true` in 82 seconds).
    def as_json(name, capability, claimant: false, bounds: nil)
      schema = capability.input_schema.presence || { "type" => "object" }
      unless schema.dig("properties", REASON)
        schema = schema.merge("properties" => (schema["properties"] || {}).merge(REASON => REASON_PROPERTY))
      end
      if claimant && !capability.input_schema&.dig("properties", USER_AUTHORIZATION)
        schema = schema.merge("properties" => schema["properties"].merge(USER_AUTHORIZATION => USER_AUTHORIZATION_PROPERTY))
      end
      {
        "name" => name, "title" => capability.name, "inputSchema" => schema,
        "description" => [ capability.description,
                           ("Your grant covers only: #{bounds}. A call outside that is denied; petition to widen it." if bounds) ].compact.join(" "),
        "annotations" => { "readOnlyHint" => capability.kind == "read", "destructiveHint" => false }
      }
    end

    # -> [answer, is_error, images]. Raises UnknownTool for a tool the agent was not
    # offered, and Sentinel::Invalid for a request that could not be filed.
    def call(agent, clearance, name, arguments)
      arguments = (arguments || {}).to_h.deep_stringify_keys
      return request_status(agent, arguments) if name.to_s == REQUEST_TOOL["name"]
      if [ PETITION_TOOL["name"], PETITION_STATUS_TOOL["name"] ].include?(name.to_s)
        raise UnknownTool, "no tool named #{name.to_s.inspect}" unless petitions?(agent)
        return name.to_s == PETITION_TOOL["name"] ? petition(agent, arguments) : petition_status(agent, arguments)
      end

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
      when "completed" then [ request.result, false, request.images ]
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

    def petition(agent, arguments)
      petition = Sentinel.petition!(agent: agent, want: arguments["want"], capability: arguments["capability"].presence,
                                    arguments: arguments["arguments"].is_a?(Hash) ? arguments["arguments"] : {},
                                    reason: arguments["reason"].presence)
      petition_outcome(petition)
    end

    def petition_status(agent, arguments)
      id = arguments["id"]
      raise Sentinel::Invalid, "id is required" if id.blank?

      petition = agent.petitions.find(id)
      wait = arguments["wait"].to_i.clamp(0, 25)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
      deciding = petition.deciding?
      until petition.settled? || (deciding && !petition.deciding?) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 1
        petition.reload
      end
      petition_outcome(petition)
    end

    # A denial is an error the model can read, like a denied request; every
    # other status is an answer, with what to do next.
    def petition_outcome(petition)
      return [ "petition denied (#{petition.decided_by}): #{petition.rationale}", true ] if petition.status == "denied"

      [ { "petition" => petition.id, "status" => petition.status, "capability" => petition.capability_name,
          "effect" => petition.effect, "rationale" => petition.rationale,
          "note" => petition.deciding? ? PETITION_DECIDING : PETITION_NOTES[petition.status] }.compact, false ]
    end
  end
end
