module Calendars
  # Where calendars are kept. A backend is a `calendar_backends` row; its
  # `kind` names one of the adapters here, and the adapter is the only code
  # that knows how that place talks. A new place (iCloud, Google, the mirror
  # agents push into) is a class under Calendars::Backends answering Base's
  # interface, plus its line in KINDS.
  module Backends
    KINDS = {
      "ics" => "Calendars::Backends::Ics",
      "fastmail" => "Calendars::Backends::Fastmail",
      "caldav" => "Calendars::Backends::Caldav"
    }.freeze

    module_function

    def kinds
      KINDS.keys
    end

    def kind?(kind)
      KINDS.key?(kind.to_s)
    end

    def adapter_class(kind)
      KINDS.fetch(kind.to_s) { raise Calendars::Invalid, "#{kind.inspect} is not a calendar backend kind (#{kinds.join(', ')})" }.constantize
    end

    def adapter_for(backend)
      adapter_class(backend.kind).new(backend)
    end
  end
end
