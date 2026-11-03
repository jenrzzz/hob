module Sentinel
  module Native
    # console.act: one action in a session the agent opened, answered with
    # the screen just after it. No session, no action.
    class ConsoleAct < ConsoleHandler
      POINT = { "type" => "array", "items" => { "type" => "integer", "minimum" => 0 }, "minItems" => 2, "maxItems" => 2 }.freeze

      CAPABILITY = {
        "name" => "console.act",
        "description" => "Take one action in a console session you opened with console.open, as with the computer-use " \
                         "tool: screenshot, mouse_move, left/right/middle/double/triple_click, left_click_drag, scroll, " \
                         "type, key, hold_key, or wait. Every action answers with a fresh frame taken just after it. " \
                         "#{STATE} An action that is refused (an unknown key, a character the keyboard layout can't type) " \
                         "fails the request with the reason and nothing is sent to the computer.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "session" => SESSION,
            "action" => { "type" => "string", "enum" => Consoles::ACTIONS.keys,
                          "description" => Consoles::ACTIONS.map { |name, args| "#{name}(#{args.join(', ')})" }.join("; ") },
            "x" => { "type" => "integer", "minimum" => 0, "description" => "Pixels from the left of the newest frame" },
            "y" => { "type" => "integer", "minimum" => 0, "description" => "Pixels from the top of the newest frame" },
            "modifiers" => { "type" => "string", "description" => "clicks: keys held during the click, like shift or cmd+shift" },
            "from" => POINT.merge("description" => "left_click_drag: [x, y] to press at"),
            "to" => POINT.merge("description" => "left_click_drag: [x, y] to release at"),
            "direction" => { "type" => "string", "enum" => Consoles::DIRECTIONS, "description" => "scroll: which way" },
            "amount" => { "type" => "integer", "minimum" => 1, "maximum" => Consoles::MAX_SCROLL,
                          "description" => "scroll: how many wheel clicks (default 3)" },
            "text" => { "type" => "string", "minLength" => 1, "maxLength" => Consoles::MAX_TEXT,
                        "description" => "type: the text, typed as key presses through the machine's keyboard layout" },
            "key" => { "type" => "string",
                       "description" => "key, hold_key: a key or a chord, like Return, Escape, Tab, cmd+space, ctrl+alt+Delete" },
            "seconds" => { "type" => "number", "minimum" => 0, "maximum" => Consoles::MAX_WAIT,
                           "description" => "wait: how long (up to #{Consoles::MAX_WAIT}); hold_key: how long to hold (up to #{Consoles::MAX_HOLD})" }
          },
          "required" => %w[session action],
          "additionalProperties" => false
        }
      }.freeze

      def call
        framed(Consoles.act(require_argument(:session), arguments.except("session")))
      end
    end
  end
end
