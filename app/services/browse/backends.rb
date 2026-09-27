module Browse
  # Where browsing happens. A browser is a `browsers` row; its `kind` names
  # one of the adapters here, and the adapter is the only code that knows
  # how that browser talks. A new kind (a headless browser in a container,
  # say) is a class under Browse::Backends answering Base's interface, plus
  # its line in KINDS.
  module Backends
    KINDS = {
      "gofer" => "Browse::Backends::Gofer"
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
      registry.fetch(kind.to_s) { raise Browse::Invalid, "#{kind.inspect} is not a browser kind (#{kinds.join(', ')})" }.constantize
    end

    def adapter_for(browser)
      adapter_class(browser.kind).new(browser)
    end

    register("fake", "Browse::Backends::Fake") if Rails.env.test?
  end
end
