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

  Request = Struct.new(:role, :system, :messages, :schema, :params, :operation, :ref, :metadata, :snapshot,
                       keyword_init: true)

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
    # messages: [{ "role" => user|assistant, "content" => String }, ...]
    # schema:   JSON schema Hash; the reply is parsed into Response#parsed
    # params:   request-level provider params, deep-merged over the chain link's
    # operation/ref/metadata/snapshot: ledger fields
    def complete(role:, messages:, system: nil, schema: nil, params: {}, operation: nil, ref: nil,
                 metadata: {}, snapshot: nil, &on_event)
      messages = normalize_messages(messages)
      raise Invalid, "messages must end with a user message" unless messages.last&.dig("role") == "user"

      request = Request.new(role: role.to_s, system: system.presence, messages: messages, schema: schema,
                            params: params.to_h.deep_stringify_keys, operation: operation, ref: ref,
                            metadata: metadata.to_h, snapshot: snapshot)
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

    private

    # One chain link: call, parse, meter. Retries exactly once when a schema
    # was given and the reply didn't parse; a second failure is a refusal.
    def attempt(request, resolution, &on_event)
      response = call_transport(request, resolution, &on_event)
      return metered(request, resolution, response) if response.refused? || request.schema.nil?

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
        schema: request.schema, params: RubyLLM::Utils.deep_merge(resolution.params.deep_stringify_keys, request.params)
      ) { |text| on_event&.call(:delta, text) }
      Response.from_transport(result, resolution: resolution, started: started)
    rescue Unauthorized, Unavailable, RateLimited, Invalid => e
      meter(request, resolution, status: e.is_a?(RateLimited) ? "rate_limited" : "error",
            error: "#{e.class.name.demodulize}: #{e.message}", started: started)
      raise
    end

    def meter(request, resolution, response: nil, status: nil, error: nil, started: nil)
      status ||= response&.refused? ? "refused" : "success"
      duration = response&.duration_ms ||
                 (started && ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      UsageEvent.record(
        principal: Current.principal, surface: Current.surface,
        role: request.role, provider: resolution.provider.slug, model: response&.model || resolution.model,
        operation: request.operation, status: status, duration_ms: duration, error: error,
        metadata: request.metadata, snapshot_digest: request.snapshot, ref: request.ref,
        units: response&.units || {}
      )
    end

    def normalize_messages(messages)
      Array(messages).map do |m|
        m = m.to_h.stringify_keys
        role = m["role"].to_s
        raise Invalid, "message role must be user or assistant, got #{role.inspect}" unless %w[user assistant].include?(role)

        { "role" => role, "content" => m["content"].to_s }
      end
    end
  end
end
