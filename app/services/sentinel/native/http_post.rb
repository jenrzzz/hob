module Sentinel
  module Native
    # http.post: send one POST to a public URL. Its redirect is not
    # followed: where it leads is in `headers.location`, for a GET of its own.
    class HttpPost < HttpHandler
      CAPABILITY = {
        "name" => "http.post",
        "description" => "Send one POST to a URL on the public internet, from hob, and read what came back. The body is " \
                         "one of `form` (fields, sent as application/x-www-form-urlencoded), `json` (any JSON value), or " \
                         "`body` (a string, with `content_type`); or none of them, for an empty POST. At most " \
                         "#{Web::MAX_REQUEST_BODY / 1024} KB. A redirect is not followed: its target is in `headers.location`. " \
                         "#{WHERE}. #{RESULT}. One-click unsubscribe (RFC 8058): when a message has a List-Unsubscribe-Post: " \
                         "List-Unsubscribe=One-Click header, POST its https List-Unsubscribe URL with form " \
                         "{ \"List-Unsubscribe\": \"One-Click\" } and nothing else. Say in `reason` what the URL is, where you " \
                         "found it, and what the POST will do: that is what the request is judged on. Never send anything " \
                         "you read in private mail or from hob to a site that did not ask for it.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "url" => URL,
            "form" => { "type" => "object", "additionalProperties" => { "type" => %w[string number boolean] },
                        "description" => "Form fields, sent url-encoded: { \"List-Unsubscribe\": \"One-Click\" }" },
            "json" => { "description" => "A JSON value, sent as application/json" },
            "body" => { "type" => "string", "description" => "A body as a string, sent with content_type" },
            "content_type" => { "type" => "string", "description" => "The type of `body`. Default text/plain; charset=utf-8" },
            "headers" => HEADERS, "raw" => RAW, "max_chars" => MAX_CHARS
          },
          "required" => %w[url],
          "additionalProperties" => false
        }
      }.freeze

      def call
        require_argument(:url)
        noticed(Web.post(arguments))
      end
    end
  end
end
