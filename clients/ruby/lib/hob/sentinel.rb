module Hob
  # One ask of the sentinel and what came of it.
  #   status: completed | denied | pending | executing | failed
  class SentinelRequest < Record
    attribute :id, :agent, :capability, :arguments, :reason, :realm, :status, :decision, :decided_by, :rationale,
              :decider, :review, :result, :error, :mission, :on_mission, :created_at, :decided_at, :executed_at

    def completed?
      status == "completed"
    end

    def denied?
      status == "denied"
    end

    def pending?
      status == "pending"
    end

    def failed?
      status == "failed"
    end

    # Nothing more will happen to it.
    def settled?
      %w[completed denied failed].include?(status)
    end
  end

  # Something an agent may ask for; `effect` is what asking will meet
  # (allow | review | confirm) or "any" when a person is looking.
  class Capability < Record
    attribute :name, :description, :input_schema, :kind, :realm, :venue, :enabled, :effect, :config
  end

  class SentinelPolicy < Record
    attribute :id, :agent, :capability, :effect, :constraints, :limits, :guidance
  end

  # A capability request (hob's SENTINEL.md, "Petitions and the forge").
  #   status: granted | pending | building | proposed | denied | failed
  class Petition < Record
    attribute :id, :agent, :want, :capability, :arguments, :reason, :realm, :status, :action, :decided_by, :rationale,
              :decider, :effect, :spec, :policy, :mission, :pull_request, :error, :on_mission, :review,
              :created_at, :decided_at, :settled_at

    def granted?
      status == "granted"
    end

    def denied?
      status == "denied"
    end

    def pending?
      status == "pending"
    end

    # Being built or awaiting a merge: it may be granted later, maybe days later.
    def in_progress?
      %w[building proposed].include?(status)
    end

    def settled?
      %w[granted denied].include?(status)
    end
  end

  # /v1/sentinel. With an agent's key: `capabilities`, `request`, `show`,
  # `wait`, `list`, and `petition` for what it cannot yet ask for. With a
  # person's key: also `decide`, `decide_petition`, the policy calls, and
  # capability registration.
  class Sentinel
    def initialize(http)
      @http = http
    end

    # POST /v1/sentinel/requests. Decided on the spot: read `status`.
    # mission: the mission the agent is working on, for the audit trail.
    def request(capability:, arguments: {}, reason: nil, mission: nil)
      SentinelRequest.new(@http.post("/v1/sentinel/requests",
                                     { capability: capability, arguments: arguments, reason: reason, mission: mission }.compact))
    end

    # GET /v1/sentinel/requests/:id; wait: seconds hob may hold the call
    # (up to 30) until the request settles.
    def show(id, wait: nil)
      SentinelRequest.new(@http.get("/v1/sentinel/requests/#{id}", { wait: wait }))
    end

    # Poll until the request settles (a person may take a while), or until
    # `timeout` seconds have passed; returns the last state either way.
    def wait(request, timeout: 3600)
      id = request.respond_to?(:id) ? request.id : request
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        current = show(id, wait: 25)
        return current if current.settled? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      end
    end

    def list(status: nil, agent: nil)
      @http.get("/v1/sentinel/requests", { status: status, agent: agent }).map { |r| SentinelRequest.new(r) }
    end

    # POST /v1/sentinel/requests/:id/decide — a person's key.
    def decide(id, decision:, rationale: nil)
      SentinelRequest.new(@http.post("/v1/sentinel/requests/#{id}/decide", { decision: decision, rationale: rationale }.compact))
    end

    # POST /v1/sentinel/petitions: ask for a capability this key does not
    # have. `want` is what the agent wants to be able to do, in plain words;
    # `capability` a suggested name; `arguments` an example. Read `status`.
    def petition(want:, capability: nil, arguments: nil, reason: nil, mission: nil)
      Petition.new(@http.post("/v1/sentinel/petitions",
                              { want: want, capability: capability, arguments: arguments, reason: reason, mission: mission }.compact))
    end

    def show_petition(id, wait: nil)
      Petition.new(@http.get("/v1/sentinel/petitions/#{id}", { wait: wait }))
    end

    # Poll until the petition is granted or denied, or `timeout` seconds pass;
    # a build can take days, so callers usually give up sooner and move on.
    def wait_petition(petition, timeout: 300)
      id = petition.respond_to?(:id) ? petition.id : petition
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        current = show_petition(id, wait: 25)
        return current if current.settled? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      end
    end

    def petitions(status: nil, agent: nil)
      @http.get("/v1/sentinel/petitions", { status: status, agent: agent }).map { |p| Petition.new(p) }
    end

    # POST /v1/sentinel/petitions/:id/decide — a person's key.
    #   decision: grant | build | deny; grant takes capability:, effect:, constraints:, limits:, guidance:
    def decide_petition(id, decision:, capability: nil, effect: nil, constraints: nil, limits: nil, guidance: nil, spec: nil, rationale: nil)
      body = { decision: decision, capability: capability, effect: effect, constraints: constraints, limits: limits,
               guidance: guidance, spec: spec, rationale: rationale }.compact
      Petition.new(@http.post("/v1/sentinel/petitions/#{id}/decide", body))
    end

    def capabilities
      @http.get("/v1/sentinel/capabilities").map { |c| Capability.new(c) }
    end

    def capability(name)
      Capability.new(@http.get("/v1/sentinel/capabilities/#{name}"))
    end

    # Register (or update) a webhook or poll capability — a person's key.
    #   register_capability(name: "mise.add_to_shopping_list", description: "...", kind: "act",
    #                       venue: "webhook", config: { url: ..., secret: ... }, input_schema: {...})
    def register_capability(name:, description:, venue:, config:, kind: "act", realm: "household", input_schema: nil, enabled: nil)
      body = { name: name, description: description, venue: venue, config: config, kind: kind, realm: realm,
               input_schema: input_schema, enabled: enabled }.compact
      Capability.new(@http.post("/v1/sentinel/capabilities", body))
    rescue Invalid => e
      raise unless e.message.to_s.include?("already been taken")

      Capability.new(@http.patch("/v1/sentinel/capabilities/#{name}", body.reject { |k, _| k == :name }))
    end

    def policies(agent: nil)
      @http.get("/v1/sentinel/policies", { agent: agent }).map { |p| SentinelPolicy.new(p) }
    end

    # effect: allow | deny | review | confirm; agent nil means every agent.
    def set_policy(capability:, effect:, agent: nil, constraints: nil, limits: nil, guidance: nil)
      body = { agent: agent, capability: capability, effect: effect, constraints: constraints, limits: limits, guidance: guidance }.compact
      body[:agent] = agent # nil is meaningful: the default rule
      SentinelPolicy.new(@http.post("/v1/sentinel/policies", body))
    rescue Invalid => e
      raise unless e.message.to_s.include?("already been taken")

      existing = policies(agent: agent).find { |p| p.capability == capability && p.agent == agent }
      raise if existing.nil?

      SentinelPolicy.new(@http.patch("/v1/sentinel/policies/#{existing.id}", body.reject { |k, _| k == :agent }))
    end

    def delete_policy(id)
      @http.delete("/v1/sentinel/policies/#{id}")
      true
    end
  end
end
