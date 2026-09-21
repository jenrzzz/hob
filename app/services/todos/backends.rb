module Todos
  # Where todos live. A backend is a `todo_backends` row; its `kind` names
  # one of the adapters here, and the adapter is the only code that knows
  # how that place talks. A new place (Reminders, Things, a table of hob's
  # own) is a class under Todos::Backends answering Base's interface, plus
  # its line in KINDS.
  module Backends
    KINDS = {
      "omnifocus" => "Todos::Backends::Omnifocus"
    }.freeze

    # Kinds registered at runtime. The in-memory Fake gets in this way and
    # only in the test environment, so no production row can be pointed at
    # it; `register` is the hook for anything else that must not be built in.
    @registered = {}

    module_function

    def register(kind, class_name)
      @registered[kind.to_s] = class_name.to_s
    end

    def registry
      KINDS.merge(@registered)
    end

    def kinds
      registry.keys
    end

    def kind?(kind)
      registry.key?(kind.to_s)
    end

    def adapter_class(kind)
      registry.fetch(kind.to_s) { raise Todos::Invalid, "#{kind.inspect} is not a todo backend kind (#{kinds.join(', ')})" }.constantize
    end

    def adapter_for(backend)
      adapter_class(backend.kind).new(backend)
    end

    register("fake", "Todos::Backends::Fake") if Rails.env.test?
  end
end
