module Hob
  # GET /v1/usage: the ledger summary for a ref, role, operation, or window.
  class UsageSummary < Record
    attribute :calls, :by_status, :input_tokens, :output_tokens, :cache_read_tokens, :cost, :priced,
              :by_role, :by_operation, :recent
  end

  # /v1/prices: USD per million tokens for a model id or id prefix.
  class ModelPrice < Record
    attribute :model, :input, :output, :cache_read, :cache_write, :note, :effective_from, :repriced, :matched, :updated_at
  end
end
