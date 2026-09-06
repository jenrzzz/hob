module Hob
  # GET /v1/usage: the ledger summary for a ref, role, operation, or window.
  class UsageSummary < Record
    attribute :calls, :by_status, :input_tokens, :output_tokens, :cache_read_tokens, :cost, :priced,
              :by_role, :by_operation, :recent
  end
end
