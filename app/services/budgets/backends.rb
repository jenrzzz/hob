module Budgets
  # Where budgets are kept. A backend is a `budget_backends` row; its `kind`
  # names one of the adapters here, and the adapter is the only code that
  # knows how that place talks. A new place (another budgeting app, a bank's
  # own API, a table of hob's own) is a class under Budgets::Backends
  # answering Base's interface, plus its line in KINDS.
  module Backends
    KINDS = {
      "ynab" => "Budgets::Backends::Ynab"
    }.freeze

    module_function

    def kinds
      KINDS.keys
    end

    def kind?(kind)
      KINDS.key?(kind.to_s)
    end

    def adapter_class(kind)
      KINDS.fetch(kind.to_s) { raise Budgets::Invalid, "#{kind.inspect} is not a budget backend kind (#{kinds.join(', ')})" }.constantize
    end

    def adapter_for(backend)
      adapter_class(backend.kind).new(backend)
    end
  end
end
