module Budgets
  module Backends
    # What an adapter answers, and the helpers every adapter wants. Budgets
    # (the façade) has already validated and normalized what arrives here:
    # filters and attributes are string-keyed, dates are "YYYY-MM-DD", amounts
    # are BigDecimals, tags are bare words, ids are the backend's own (native)
    # ids with hob's "<backend>:" prefix taken off. What goes back is the
    # normalized shape in BUDGET.md, string-keyed, amounts as plain numbers,
    # with the prefix put back on (`prefixed`).
    #
    #   accounts               → [account]
    #   categories(month)      → { "month" => {...}, "categories" => [category] }; month is "current" or "YYYY-MM-01"
    #   transactions(filters)  → [transaction], at least everything from `since` to `until`; it may
    #                            narrow by the other filters, and the façade applies them all regardless
    #   find(id)               → transaction
    #   create(attrs)          → transaction     update(id, attrs) → transaction
    #   check                  → { "reachable" => true, ... } or raises
    #
    # `account` and `category` on a write are an id of this backend's or an
    # exact name (`reference`). An adapter raises Budgets::NotFound, Invalid,
    # Forbidden, or Unavailable and nothing else.
    class Base
      attr_reader :backend

      # Problems with a row's config, as sentences; none by default.
      def self.config_errors(_config)
        []
      end

      def initialize(backend)
        @backend = backend
      end

      %i[accounts categories transactions find create update check].each do |operation|
        define_method(operation) { |*| raise NotImplementedError, "#{self.class.name} does not implement #{operation}" }
      end

      private

      def prefixed(native)
        native.presence && "#{backend.name}:#{native}"
      end

      # An id only when it carries this backend's prefix; "Auto: Gas" is a name.
      # -> [:id, native] | [:name, string]
      def reference(value)
        prefix, native = value.to_s.split(":", 2)
        prefix == backend.name && native.present? ? [ :id, native ] : [ :name, value.to_s ]
      end
    end
  end
end
