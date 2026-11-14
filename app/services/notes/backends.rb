module Notes
  # Where notes are kept. A backend is a `note_backends` row; its `kind`
  # names one of the adapters here, and the adapter is the only code that
  # knows how that place talks. A new place (an Obsidian vault, a Google Keep
  # account) is a class under Notes::Backends answering Base's interface,
  # plus its line in KINDS.
  module Backends
    KINDS = {
      "quire" => "Notes::Backends::Quire"
    }.freeze

    module_function

    def kinds
      KINDS.keys
    end

    def kind?(kind)
      KINDS.key?(kind.to_s)
    end

    def adapter_class(kind)
      KINDS.fetch(kind.to_s) { raise Notes::Invalid, "#{kind.inspect} is not a note backend kind (#{kinds.join(', ')})" }.constantize
    end

    def adapter_for(backend)
      adapter_class(backend.kind).new(backend)
    end
  end
end
