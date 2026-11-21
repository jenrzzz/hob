module Shells
  # How a host is reached. A host is a `shell_hosts` row; its `kind` names
  # one of the adapters here, and the adapter is the only code that knows
  # how that machine is spoken to. A new kind is a class under
  # Shells::Backends answering Base's interface, plus its line in KINDS.
  module Backends
    KINDS = {
      "ssh" => "Shells::Backends::Ssh"
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
      registry.fetch(kind.to_s) { raise Shells::Invalid, "#{kind.inspect} is not a shell host kind (#{kinds.join(', ')})" }.constantize
    end

    def adapter_for(host)
      adapter_class(host.kind).new(host)
    end

    register("fake", "Shells::Backends::Fake") if Rails.env.test?
  end
end
