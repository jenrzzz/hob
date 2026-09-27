module Sentinel
  module Native
    # browse.act: one step in a session the agent opened. No session, no
    # step: the goal was judged at browse.open, and this is bound to it.
    class BrowseAct < BrowseHandler
      CAPABILITY = {
        "name" => "browse.act",
        "description" => "Take one step in a browsing session you opened with browse.open: navigate, click, type, press a " \
                         "key, select, hover, scroll, go back or forward, reload, wait, or read an element's text. Act by " \
                         "ref from the newest snapshot. #{STATE} A step that fails (a ref that is gone, a URL outside the " \
                         "session's domains) fails the request with the reason; take a fresh snapshot and carry on.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "session" => SESSION,
            "action" => { "type" => "string", "enum" => Browse::ACTIONS.keys,
                          "description" => Browse::ACTIONS.map { |name, args| "#{name}(#{args.join(', ')})" }.join("; ") },
            "url" => { "type" => "string", "description" => "navigate: where to go, inside the session's domains" },
            "ref" => { "type" => "string", "pattern" => "^(f\\d+)?e\\d+$",
                       "description" => "click, type, select, hover, scroll, read: the element, as [ref=...] in the snapshot" },
            "text" => { "type" => "string", "description" => "type: the text (replaces the field's contents); wait: text to wait for" },
            "submit" => { "type" => "boolean", "description" => "type: press Enter afterwards" },
            "slowly" => { "type" => "boolean", "description" => "type: key by key, for fields that watch keystrokes" },
            "double" => { "type" => "boolean", "description" => "click: double-click" },
            "button" => { "type" => "string", "enum" => %w[left right middle], "description" => "click: which button" },
            "key" => { "type" => "string", "description" => "press: Enter, Escape, ArrowDown, PageDown, Control+a, ..." },
            "values" => { "type" => "array", "items" => { "type" => "string" }, "description" => "select: option values or labels" },
            "direction" => { "type" => "string", "enum" => %w[up down], "description" => "scroll: without a ref, which way" },
            "amount" => { "type" => "number", "description" => "scroll: screens to move (default 0.8)" },
            "seconds" => { "type" => "integer", "minimum" => 0, "maximum" => 30, "description" => "wait: how long (default 2)" },
            "screenshot" => SCREENSHOT,
            "max_chars" => MAX_CHARS
          },
          "required" => %w[session action],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Browse.act(require_argument(:session), arguments.except("session")))
      end
    end
  end
end
