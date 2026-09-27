module Sentinel
  module Native
    # browse.close: done with the tab. Sessions close themselves in time,
    # but a closed one frees the browser for the next visit at once.
    class BrowseClose < BrowseHandler
      CAPABILITY = {
        "name" => "browse.close",
        "description" => "Close a browsing session you opened. Do this when the goal is met or given up; a session left " \
                         "open closes itself after a quarter hour of quiet, but holds one of the browser's few tabs until " \
                         "then. Returns { session: { id, browser, goal, status, steps, url, title, ... } }.",
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
        { "session" => Browse.close(require_argument(:session)) }
      end
    end
  end
end
