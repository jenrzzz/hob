module Hob
  # Mirrors hob's Gateway hierarchy (EXTRACTION.md A6) on the client side.
  class Error < StandardError
    attr_reader :status, :body

    def initialize(message = nil, status: nil, body: nil)
      super(message)
      @status = status
      @body = body
    end
  end

  class Invalid < Error; end        # 422: bad role, schema, prompt shape, tool definitions
  class Unauthorized < Error; end   # 401: bad hob key; 502: the provider rejected hob's credentials
  class NotFound < Error; end       # 404
  class Unavailable < Error; end    # 503 / network: no provider, upstream down

  # 503 with status rate_limited (upstream 429); retry_after in seconds when known.
  class RateLimited < Error
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil, **rest)
      super(message, **rest)
      @retry_after = retry_after
    end
  end

  # HTTP 200 with status: refused — the call happened and was metered; the
  # completion (id, usage) rides along.
  class Refused < Error
    attr_reader :completion

    def initialize(message = "the model declined", completion: nil, **rest)
      super(message, **rest)
      @completion = completion
    end
  end
end
