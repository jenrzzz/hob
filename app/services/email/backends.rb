module Email
  # Where mail is kept. A backend is a `mail_backends` row; its `kind` names
  # one of the adapters here, and the adapter is the only code that knows
  # how that place talks. A new place (Gmail, an IMAP server) is a class
  # under Email::Backends answering Base's interface, plus its line in KINDS.
  module Backends
    KINDS = {
      "fastmail" => "Email::Backends::Fastmail",
      "jmap" => "Email::Backends::Jmap"
    }.freeze

    module_function

    def kinds
      KINDS.keys
    end

    def kind?(kind)
      KINDS.key?(kind.to_s)
    end

    def adapter_class(kind)
      KINDS.fetch(kind.to_s) { raise Email::Invalid, "#{kind.inspect} is not a mail backend kind (#{kinds.join(', ')})" }.constantize
    end

    def adapter_for(backend)
      adapter_class(backend.kind).new(backend)
    end
  end
end
