module Sentinel
  module Native
    # http.get: fetch one public URL, following its redirects.
    class HttpGet < HttpHandler
      CAPABILITY = {
        "name" => "http.get",
        "description" => "Fetch one URL on the public internet with a GET, from hob, and read what came back. Redirects are " \
                         "followed, up to #{Web::MAX_REDIRECTS}, each checked as the first was. #{WHERE}. #{RESULT}. Say in " \
                         "`reason` what the URL is and where you found it (\"the List-Unsubscribe link in message <id> from " \
                         "<sender>\"): that is what the request is judged on. A GET can still change something (many " \
                         "unsubscribe links act when opened), so ask only for the one you mean to open.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "url" => URL, "headers" => HEADERS, "raw" => RAW, "max_chars" => MAX_CHARS },
          "required" => %w[url],
          "additionalProperties" => false
        }
      }.freeze

      def call
        require_argument(:url)
        noticed(Web.get(arguments))
      end
    end
  end
end
