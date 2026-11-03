module Consoles
  module Backends
    # What an adapter answers. Consoles (the façade) has already validated
    # what arrives: a step body is { action, ...its arguments } with string
    # keys, every argument checked. What goes back is the session's state,
    # string-keyed:
    #
    #   { "id" => the backend's session id, "expires_at",
    #     "video" => { "ready", "error"?, "width", "height", "fps" },
    #     "screen" => { "data" => base64 PNG, "mime_type", "width", "height" } }
    #
    #   open(ttl:, scale:)          → state, with a screen
    #   state(remote_id, scale:)    → state, with a fresh screen
    #   act(remote_id, body)        → state, with the screen after the input
    #   close(remote_id)            → true
    #   check                       → { "reachable" => true, ... } or raises
    #
    # An adapter raises Consoles::NotFound, Invalid, Forbidden, Unavailable,
    # or Gone and nothing else.
    class Base
      attr_reader :console

      # Problems with a row's config, as sentences; none by default.
      def self.config_errors(_config)
        []
      end

      def initialize(console)
        @console = console
      end

      %i[open state act close check].each do |operation|
        define_method(operation) { |*, **| raise NotImplementedError, "#{self.class.name} does not implement #{operation}" }
      end
    end
  end
end
