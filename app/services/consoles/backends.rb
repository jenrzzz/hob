module Consoles
  # Where a console is reached. A console is a `consoles` row; its `kind`
  # names one of the adapters here, and the adapter is the only code that
  # knows how that console talks. A new kind is a class under
  # Consoles::Backends answering Base's interface, plus its line in KINDS.
  module Backends
    KINDS = {
      "jetkvm" => "Consoles::Backends::Jetkvm"
    }.freeze

    # Kinds registered at runtime: the in-memory Fake, in the test
    # environment only, so no production row can be pointed at it.
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
      registry.fetch(kind.to_s) { raise Consoles::Invalid, "#{kind.inspect} is not a console kind (#{kinds.join(', ')})" }.constantize
    end

    def adapter_for(console)
      adapter_class(console.kind).new(console)
    end

    register("fake", "Consoles::Backends::Fake") if Rails.env.test?
  end
end
