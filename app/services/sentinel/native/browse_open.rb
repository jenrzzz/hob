module Sentinel
  module Native
    # browse.open: a tab in one of the household's browsers, for a goal.
    # This is where policy looks at what the visit is for; every step that
    # follows rides on the session this made.
    class BrowseOpen < BrowseHandler
      CAPABILITY = {
        "name" => "browse.open",
        "description" => "Open a browsing session in one of the household's real browsers (a Chrome on a household Mac, " \
                         "logged in as its owner) at a URL, for a stated goal. Use it for sites that turn away your own " \
                         "browser or need the household's logins. The session is confined to the site's domains and kept " \
                         "off checkout pages; it closes itself after a quarter hour of quiet or an hour of life. " \
                         "#{STATE} Then act with browse.act, and browse.close when done.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "goal" => { "type" => "string", "minLength" => 8, "maxLength" => 500,
                        "description" => "One or two sentences: what you will do in this session and for whom. It is what the household reviews" },
            "url" => { "type" => "string", "description" => "Where to start, http or https" },
            "browser" => { "type" => "string", "description" => "A browser's name; needed only when more than one is visible" },
            "domains" => { "type" => "array", "items" => { "type" => "string" },
                           "description" => "Narrow the session to these domains (subdomains included); it can never widen past the browser's" },
            "ttl" => { "type" => "integer", "minimum" => Browse::MIN_TTL, "maximum" => Browse::MAX_TTL,
                       "description" => "Seconds of quiet before the session closes itself (default 900)" },
            "screenshot" => SCREENSHOT,
            "max_chars" => MAX_CHARS
          },
          "required" => %w[goal url],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Browse.open(
          goal: require_argument(:goal), url: require_argument(:url), browser: arguments["browser"],
          domains: arguments["domains"], ttl: arguments["ttl"], screenshot: arguments["screenshot"],
          max_chars: arguments["max_chars"], request: request
        ))
      end
    end
  end
end
