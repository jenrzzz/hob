module Texts
  # Where text messages are kept. A backend is a `text_backends` row; its
  # `kind` names one of the adapters here, and the adapter is the only code
  # that knows how that place talks. A new place (a Google Voice account, an
  # Android phone's bridge) is a class under Texts::Backends answering
  # Base's interface, plus its line in KINDS.
  module Backends
    KINDS = {
      "herald" => "Texts::Backends::Herald"
    }.freeze

    module_function

    def kinds
      KINDS.keys
    end

    def kind?(kind)
      KINDS.key?(kind.to_s)
    end

    def adapter_class(kind)
      KINDS.fetch(kind.to_s) { raise Texts::Invalid, "#{kind.inspect} is not a text backend kind (#{kinds.join(', ')})" }.constantize
    end

    def adapter_for(backend)
      adapter_class(backend.kind).new(backend)
    end
  end
end
