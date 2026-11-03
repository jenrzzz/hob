module Sentinel
  module Native
    # console.open: a session on one of the household's KVMs, for a goal.
    # The goal is required though nothing judges it yet: it is what the
    # audit trail reads as, and what step review will judge once it exists.
    class ConsoleOpen < ConsoleHandler
      CAPABILITY = {
        "name" => "console.open",
        "description" => "Open a session on one of the household's consoles: the real screen, keyboard, and mouse of a " \
                         "household computer, through a KVM, for a stated goal. Use it for what a browser can't reach: a " \
                         "native app, a settings pane, a menu bar, a machine whose app has hung. One session at a time " \
                         "per console, and a person opening the KVM themselves ends yours. A session ends after " \
                         "#{ConsoleSession::DEFAULT_TTL} seconds without a step (ttl), after " \
                         "#{ConsoleSession::MAX_LIFE.in_minutes.to_i} minutes regardless, or after " \
                         "#{ConsoleSession::MAX_STEPS} steps. #{STATE} Then act with console.act, and console.close when done.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "goal" => { "type" => "string", "minLength" => 8, "maxLength" => 500,
                        "description" => "One or two sentences: what you will do on this computer and for whom. It is the record of the session" },
            "console" => { "type" => "string", "description" => "A console's name; needed only when more than one is visible" },
            "ttl" => { "type" => "integer", "minimum" => ConsoleSession::MIN_TTL, "maximum" => ConsoleSession::MAX_TTL,
                       "description" => "Seconds without a step before the session ends (default #{ConsoleSession::DEFAULT_TTL})" },
            "scale" => SCALE
          },
          "required" => %w[goal],
          "additionalProperties" => false
        }
      }.freeze

      def call
        framed(Consoles.open(goal: require_argument(:goal), console: arguments["console"], ttl: arguments["ttl"],
                             scale: arguments["scale"], request: request))
      end
    end
  end
end
