module Sentinel
  module Native
    # browse.snapshot: the page as it is now, without touching it.
    class BrowseSnapshot < BrowseHandler
      CAPABILITY = {
        "name" => "browse.snapshot",
        "description" => "The current page of a browsing session you opened, without acting: a fresh snapshot (and a " \
                         "screenshot if asked) after the page has changed on its own, or when refs from an earlier step are " \
                         "stale. #{STATE}",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "session" => SESSION, "screenshot" => SCREENSHOT, "max_chars" => MAX_CHARS },
          "required" => %w[session],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Browse.state(require_argument(:session), screenshot: arguments["screenshot"], max_chars: arguments["max_chars"]))
      end
    end
  end
end
