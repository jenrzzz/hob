module Browse
  module Backends
    # What an adapter answers. Browse (the façade) has already validated what
    # arrives: a step body is { action, ...its arguments, screenshot?,
    # max_chars? } with string keys. What goes back is the backend's state
    # of the tab, string-keyed, at least:
    #
    #   { "id" => the backend's session id, "url", "title", "snapshot", "truncated",
    #     "blocked" => nil | { "url", "reason" }, "expires_at", "text"?, "screenshot"? }
    #
    #   open(url:, domains:, ttl:, screenshot:, max_chars:) → state
    #   state(remote_id, screenshot:, max_chars:)           → state
    #   act(remote_id, body)                                → state
    #   close(remote_id)                                    → true
    #   check                                               → { "reachable" => true, ... } or raises
    #
    # An adapter raises Browse::NotFound, Invalid, Forbidden, Unavailable, or
    # Gone and nothing else.
    class Base
      attr_reader :browser

      # Problems with a row's config, as sentences; none by default.
      def self.config_errors(_config)
        []
      end

      def initialize(browser)
        @browser = browser
      end

      %i[open state act close check].each do |operation|
        define_method(operation) { |*, **| raise NotImplementedError, "#{self.class.name} does not implement #{operation}" }
      end
    end
  end
end
