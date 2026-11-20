# The gateway plane: surfaces ask for a model *role*; hob resolves it through
# the role's fallback chain to a concrete provider+model, always streams from
# the provider, normalizes the outcome, and meters every attempt.
#
# `complete` is the one model-facing primitive (EXTRACTION.md A1). Chat turns
# and one-shot completions both go through it; ruby_llm is the transport
# underneath (A2), reachable only via Gateway::Transport so tests can swap in
# Gateway::Fake.
module Gateway
  # Error hierarchy shared by the API and the client (A6).
  class Error < StandardError; end
  class Invalid < Error; end        # bad request: unknown role, bad schema, prompt shape
  class Unauthorized < Error; end   # the provider rejected hob's credentials
  class Unavailable < Error; end    # no configured provider, upstream 5xx/overload, network
  class RateLimited < Error         # upstream 429; retry_after in seconds when known
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end
  class Refused < Error; end        # the model declined: a metered, distinct outcome

  # Older names, kept for callers and rescue_from lists.
  NoProviderError = Class.new(Unavailable)
  UnknownRoleError = Class.new(Invalid)

  Request = Struct.new(:role, :system, :messages, :schema, :tools, :tool_choice, :params, :operation, :ref,
                       :metadata, :snapshot, :realm, keyword_init: true)

  class << self
    # The provider transport. Tests inject Gateway::Fake here.
    attr_writer :transport

    def transport
      @transport ||= Transport.new
    end

    # One-shot request, normalized outcome. Blocks until the reply is complete;
    # the optional block receives (:delta, text) as the reply streams and
    # (:retry, reason) if a structured reply had to be re-requested (A4).
    #
    # role:     model role slug
    # messages: [{ "role" => user|assistant|tool, "content" => String,
    #              "tool_calls" => [{ id, name, arguments }]?, "tool_call_id" => String? }, ...]
    # schema:   JSON schema Hash; the reply is parsed into Response#parsed
    # tools:    [{ name, description, input_schema }] the caller will execute (C);
    #           a reply carrying tool calls is returned unparsed with tool_calls set
    # tool_choice: auto (nil) | none | required | a tool name
    # params:   request-level provider params, deep-merged over the chain link's
    # operation/ref/metadata/snapshot: ledger fields
    # realm:    the realm the call's content belongs to; its audit payload
    #           (what the model said) is stored there. Defaults to the
    #           clearance in force.
    def complete(role:, messages:, system: nil, schema: nil, tools: nil, tool_choice: nil, params: {},
                 operation: nil, ref: nil, metadata: {}, snapshot: nil, realm: nil, &on_event)
      messages = normalize_messages(messages)
      unless %w[user tool].include?(messages.last&.dig("role"))
        raise Invalid, "messages must end with a user message or tool results"
      end

      tool_defs = ToolDef.normalize(tools)
      request = Request.new(role: role.to_s, system: system.presence, messages: messages, schema: schema,
                            tools: tool_defs, tool_choice: ToolDef.normalize_choice(tool_choice, tool_defs),
                            params: params.to_h.deep_stringify_keys, operation: operation, ref: ref,
                            metadata: metadata.to_h, snapshot: snapshot,
                            realm: realm.presence || UsageEvent.content_realm)
      candidates = ModelRole.find_role!(request.role).candidates
      raise NoProviderError, "no available provider for role #{role.inspect}" if candidates.empty?

      last_error = nil
      candidates.each do |resolution|
        return attempt(request, resolution, &on_event)
      rescue Unavailable, RateLimited => e
        raise if resolution.strict?

        last_error = e
      end
      raise last_error
    end

    # Embeddings for `texts` through `role`'s chain (MEMORY.md). Metered like
    # every call. -> [vectors, model]
    def embed(role:, texts:, operation: "embed", ref: nil)
      texts = Array(texts).map(&:to_s)
      raise Invalid, "nothing to embed" if texts.empty?

      request = Request.new(role: role.to_s, operation: operation, ref: ref, metadata: {}, params: {},
                            realm: UsageEvent.content_realm)
      candidates = ModelRole.find_role!(request.role).candidates
      raise NoProviderError, "no available provider for role #{role.inspect}" if candidates.empty?

      last_error = nil
      candidates.each do |resolution|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          result = transport.embed(resolution: resolution, texts: texts)
        rescue Unauthorized, Unavailable, RateLimited, Invalid => e
          meter(request, resolution, status: e.is_a?(RateLimited) ? "rate_limited" : "error",
                error: "#{e.class.name.demodulize}: #{e.message}", started: started)
          raise if resolution.strict? || !e.is_a?(Unavailable) && !e.is_a?(RateLimited)

          last_error = e
          next
        end
        UsageEvent.record(
          principal: Current.principal, surface: Current.surface, role: request.role,
          provider: resolution.provider.slug, model: result[:model] || resolution.model, operation: operation,
          status: "success", duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
          error: nil, metadata: { "texts" => texts.size }, snapshot_digest: nil, ref: ref, realm: request.realm,
          units: { "input_tokens" => result[:input_tokens].to_i }
        )
        return [ result[:vectors], resolution.model ]
      end
      raise last_error
    end

    private

    def attachments_of(message)
      Array(message["attachments"]).map do |a|
        a = a.to_h.stringify_keys
        raise Invalid, "attachments are { type: image, digest }" unless a["type"] == "image" && a["digest"].present?

        a.slice("type", "media_type", "digest")
      end
    end

    # One chain link: call, parse, meter. Retries exactly once when a schema
    # was given and the reply didn't parse; a second failure is a refusal.
    def attempt(request, resolution, &on_event)
      response = call_transport(request, resolution, &on_event)
      if response.refused? || response.tool_calls? || request.schema.nil?
        return metered(request, resolution, response)
      end

      begin
        response.parsed = Structured.parse(response.content)
      rescue Structured::ParseError => first
        meter(request, resolution, response: response, status: "error",
              error: "structured output did not parse: #{first.message}")
        on_event&.call(:retry, "unparseable structured output")

        response = call_transport(request, resolution, &on_event)
        return metered(request, resolution, response) if response.refused?

        begin
          response.parsed = Structured.parse(response.content)
        rescue Structured::ParseError => second
          meter(request, resolution, response: response, status: "refused",
                error: "structured output did not parse after retry: #{second.message}")
          raise Refused, "the model did not produce the requested structure"
        end
      end
      metered(request, resolution, response)
    end

    def metered(request, resolution, response)
      meter(request, resolution, response: response)
      response
    end

    # Calls the transport; meters only the failures it raises.
    def call_transport(request, resolution, &on_event)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = transport.call(
        resolution: resolution, system: request.system, messages: request.messages,
        schema: request.schema, tools: request.tools, tool_choice: request.tool_choice,
        params: resolution.params.deep_stringify_keys.deep_merge(request.params)
      ) { |text| on_event&.call(:delta, text) }
      Response.from_transport(result, resolution: resolution, started: started)
    rescue Unauthorized, Unavailable, RateLimited, Invalid => e
      meter(request, resolution, status: e.is_a?(RateLimited) ? "rate_limited" : "error",
            error: "#{e.class.name.demodulize}: #{e.message}", started: started)
      raise
    end

    def meter(request, resolution, response: nil, status: nil, error: nil, started: nil)
      status ||= if response&.empty? then "empty"
      elsif response&.refused? then "refused"
      else "success"
      end
      duration = response&.duration_ms ||
                 (started && ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      UsageEvent.record(
        principal: Current.principal, surface: Current.surface,
        role: request.role, provider: resolution.provider.slug, model: response&.model || resolution.model,
        operation: request.operation, status: status, duration_ms: duration, error: error,
        metadata: request.metadata, snapshot_digest: request.snapshot, ref: request.ref,
        units: response&.units || {}, realm: request.realm, stop_reason: response&.stop_reason,
        tool_names: Array(response&.tool_calls).map { |tc| tc["name"].to_s },
        payload: response && audit_payload(request, response)
      )
    end

    # What the audit trail keeps of a call (UsagePayload). The request only
    # when no prompt snapshot already holds it; attachments by digest only.
    def audit_payload(request, response)
      {
        response: { "content" => response.content.presence, "reasoning" => response.reasoning,
                    "tool_calls" => response.tool_calls.presence }.compact.presence,
        request: request.snapshot.present? ? nil : {
          "system" => request.system, "messages" => request.messages,
          "tools" => Array(request.tools).map { |t| t.respond_to?(:name) ? t.name : t.to_h["name"] }.presence,
          "schema" => request.schema
        }.compact
      }
    end

    def normalize_messages(messages)
      Array(messages).map do |m|
        m = m.to_h.deep_stringify_keys
        role = m["role"].to_s
        normalized = case role
        when "user"
          { "role" => role, "content" => m["content"].to_s, "attachments" => attachments_of(m) }
        when "assistant"
          calls = Array(m["tool_calls"]).map { |tc| tc.to_h.stringify_keys.slice("id", "name", "arguments") }
          calls.each { |tc| raise Invalid, "tool_calls need id and name" if tc["id"].blank? || tc["name"].blank? }
          { "role" => role, "content" => m["content"].to_s, "tool_calls" => calls, "reasoning" => m["reasoning"].presence }
            .tap { |h| h.delete("tool_calls") if calls.empty? }
        when "tool"
          raise Invalid, "tool messages need a tool_call_id" if m["tool_call_id"].blank?

          { "role" => role, "content" => m["content"].to_s, "tool_call_id" => m["tool_call_id"],
            "attachments" => attachments_of(m), "error" => m["error"] ? true : nil }
        else
          raise Invalid, "message role must be user, assistant, or tool, got #{role.inspect}"
        end
        # attachments: [{ type: image, media_type, digest }] (bytes in Blob);
        # reasoning: a provider's thinking blocks to replay; cache: the
        # stable prefix ends here (Transport sets the provider breakpoint).
        normalized["cache"] = true if m["cache"]
        normalized.compact.reject { |k, v| k == "attachments" && v.empty? }
      end
    end
  end
end
