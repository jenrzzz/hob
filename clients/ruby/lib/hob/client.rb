module Hob
  # The hob client. One object per surface, built once:
  #
  #   hob = Hob::Client.new(base: ENV["HOB_URL"], key: ENV["HOB_KEY"])
  #
  # Every model call goes through `complete` (one-shot, usually structured)
  # or `chat` (a turn on a conversation branch). Both raise Hob::Refused when
  # the model declines, Hob::RateLimited / Hob::Unavailable when hob or its
  # provider can't serve the call, and Hob::Invalid for a bad request.
  class Client
    attr_reader :http

    # clearance: cap this client's realm below the key's default (X-Hob-Clearance).
    # ipaddr:    connect to this address (HOB_ADDR) while keeping base's host
    #            for Host, SNI and the certificate check — hob's public name
    #            reached over the tailnet.
    def initialize(base: ENV["HOB_URL"], key: ENV["HOB_KEY"], ipaddr: ENV["HOB_ADDR"], timeout: 120, clearance: nil, http: nil)
      raise ArgumentError, "Hob::Client needs base: (or HOB_URL)" if http.nil? && (base.nil? || base.empty?)
      raise ArgumentError, "Hob::Client needs key: (or HOB_KEY)" if http.nil? && (key.nil? || key.empty?)

      @http = http || HTTP.new(base: base, key: key, timeout: timeout, clearance: clearance, ipaddr: ipaddr)
    end

    # POST /v1/completions → Hob::Completion.
    #
    # role:      hob model role ("extractor", "narrator", ...)
    # messages:  [{ role: user|assistant|system, content: }]
    # system:    system prompt; or persona: a persona key that supplies it
    # schema:    JSON schema; the reply is parsed into Completion#parsed
    # tools:     [{ name, description, input_schema }] — when the model calls
    #            one the completion returns with tool_calls? and the caller
    #            comes back with id: and tool_results: [{ id, content }]
    # operation / metadata / ref: ledger fields (GET /v1/usage groups on them)
    # A block streams events (delta, retry, tool_call, usage, done).
    def complete(role: nil, messages: nil, system: nil, persona: nil, schema: nil, tools: nil, tool_choice: nil,
                 max_iterations: nil, operation: nil, metadata: {}, params: {}, ref: nil, realm: nil,
                 id: nil, tool_results: nil, &on_event)
      body = {
        role: role, messages: messages, system: system, persona: persona, schema: schema, tools: tools,
        tool_choice: tool_choice, max_iterations: max_iterations, operation: operation,
        metadata: presence(metadata), params: presence(params), ref: ref, realm: realm,
        id: id, tool_results: tool_results
      }.compact
      raise ArgumentError, "complete needs role: and messages:, or id: and tool_results:" unless body[:role] || body[:id]

      data = on_event ? @http.stream("/v1/completions", body, &on_event) : @http.post("/v1/completions", body)
      completion = Completion.new(data)
      raise Refused.new(data["error"] || "the model declined", completion: completion) if completion.refused?

      completion
    end

    # GET /v1/completions/:id — a stored completion (status, content, parsed,
    # pending tool_calls).
    def completion(id)
      Completion.new(@http.get("/v1/completions/#{id}"))
    end

    # POST /v1/conversations/:id/chat → Hob::Turn. With a block, streams
    # (delta events carry the text as it arrives).
    def chat(conversation:, branch: "main", content: nil, persona: nil, personas: nil, context: nil,
             instruction: nil, preset: nil, role: nil, regenerate_at: nil, tools: nil, tool_choice: nil,
             tool_results: nil, max_iterations: nil, &on_event)
      id = conversation.respond_to?(:id) ? conversation.id : conversation
      body = {
        branch: branch, content: content, persona: persona, personas: personas, context: context,
        instruction: instruction, preset: preset, role: role, regenerate_at: regenerate_at,
        tools: tools, tool_choice: tool_choice, tool_results: tool_results, max_iterations: max_iterations
      }.compact
      path = "/v1/conversations/#{id}/chat"
      data = on_event ? @http.stream(path, body, &on_event) : @http.post(path, body)
      raise Refused.new(data["error"] || "the model declined") if data["status"] == "refused"

      Turn.new(data)
    end

    def conversations
      @conversations ||= Conversations.new(@http)
    end

    # GET /v1/usage → Hob::UsageSummary. since: a Time or ISO8601 string;
    # surface: "all" for the whole household (default: this key's surface).
    def usage(ref: nil, role: nil, operation: nil, since: nil, surface: nil)
      since = since.iso8601 if since.respond_to?(:iso8601)
      UsageSummary.new(@http.get("/v1/usage", { ref: ref, role: role, operation: operation, since: since, surface: surface }))
    end

    private

    def presence(hash)
      hash.nil? || hash.empty? ? nil : hash
    end
  end
end
