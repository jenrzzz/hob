module Sentinel
  module Native
    # console.screen: the screen as it is now, without touching it.
    class ConsoleScreen < ConsoleHandler
      CAPABILITY = {
        "name" => "console.screen",
        "description" => "The screen of a console session you opened, now, without acting: after it has changed on its " \
                         "own, or at another scale. #{STATE}",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "session" => SESSION, "scale" => SCALE },
          "required" => %w[session],
          "additionalProperties" => false
        }
      }.freeze

      def call
        framed(Consoles.screen(require_argument(:session), scale: arguments["scale"]))
      end
    end
  end
end
