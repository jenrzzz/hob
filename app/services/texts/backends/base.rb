module Texts
  module Backends
    # What an adapter answers. Texts (the façade) has already validated what
    # arrives here: times are Times, filters are string-keyed, and chat ids
    # are the backend's own (native), with hob's "<backend>:" prefix taken
    # off. What goes back is the normalized shape in TEXTS.md, string-keyed,
    # with the prefix put back on (`prefixed`) and times in the household's
    # zone (`shown_time`).
    #
    #   chats(filter, limit)               → [chat], most recently active first; each carries "_last" (a Time)
    #   messages(filter, limit)            → { "messages" => [message], "truncated", "searched_back_to" }, newest
    #                                        first; each message carries "_sent" (a Time) the façade merges by
    #   poll(state, from_me:)              → { "state", "messages" => [message], "more" }, oldest first; a nil
    #                                        state is a first look: the state now, and no messages
    #   send_message(chat:, to:, text:)    → { "status" => "sent", "message" } or
    #                                        { "status" => "pending", "chat_id" }
    #   check                              → { "reachable" => true, ... } or raises
    #
    # An adapter raises Texts::NotFound, Invalid, Forbidden, or Unavailable
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

      %i[chats messages poll send_message check].each do |operation|
        define_method(operation) { |*, **| raise NotImplementedError, "#{self.class.name} does not implement #{operation}" }
      end

      private

      def prefixed(native)
        native.presence && "#{backend.name}:#{native}"
      end

      def parse_time(value)
        return nil if value.blank?

        Time.iso8601(value.to_s).in_time_zone(Texts.zone)
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
