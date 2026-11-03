module Sentinel
  module Native
    # console.close: done. A closed session hands the KVM back to its owner
    # at once.
    class ConsoleClose < ConsoleHandler
      CAPABILITY = {
        "name" => "console.close",
        "description" => "Close a console session you opened. Do this as soon as the goal is met or given up (or when " \
                         "you meet a login window): while a session is open, nobody else can use the KVM, its owner " \
                         "included. Returns { session: { id, console, goal, status, steps, close_reason, ... } }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "session" => SESSION },
          "required" => %w[session],
          "additionalProperties" => false
        }
      }.freeze

      def call
        { "session" => Consoles.close(require_argument(:session)) }
      end
    end
  end
end
