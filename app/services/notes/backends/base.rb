module Notes
  module Backends
    # What an adapter answers. Notes (the façade) has already validated what
    # arrives here: times are Times, filters are string-keyed, and note and
    # folder ids are the backend's own (native), with hob's "<backend>:"
    # prefix taken off. What goes back is the normalized shape in NOTES.md,
    # string-keyed, with the prefix put back on (`prefixed`) and times in the
    # household's zone (`shown_time`).
    #
    #   folders(filter)              → [folder]
    #   notes(filter, limit)         → { "notes" => [note], "truncated" }, the most recently modified first;
    #                                  each note carries "_modified" (a Time) the façade merges by
    #   note(id)                     → note, with text, html, and attachments
    #   create(fields)               → note; fields: folder, title, text, html (any may be absent)
    #   update(id, fields)           → note; fields: title, text, html, append, folder
    #   check                        → { "reachable" => true, ... } or raises
    #
    # An adapter raises Notes::NotFound, Invalid, Forbidden, or Unavailable
    # and nothing else.
    class Base
      attr_reader :backend

      # Problems with a row's config, as sentences; none by default.
      def self.config_errors(_config)
        []
      end

      def initialize(backend)
        @backend = backend
      end

      %i[folders notes note create update check].each do |operation|
        define_method(operation) { |*, **| raise NotImplementedError, "#{self.class.name} does not implement #{operation}" }
      end

      private

      def prefixed(native)
        native.presence && "#{backend.name}:#{native}"
      end

      def parse_time(value)
        return nil if value.blank?

        Time.iso8601(value.to_s).in_time_zone(Notes.zone)
      rescue ArgumentError
        nil
      end

      # Times leave in the household's zone, with its offset, as mail's do.
      def shown_time(value)
        parse_time(value)&.iso8601
      end
    end
  end
end
