module Sentinel
  module Native
    # What the http.* handlers share (HTTP.md). They are thin: Web makes the
    # request and refuses anywhere inside the house, so what a rule decides
    # is only whether this request, to this public URL, should be made.
    # Everything handed back carries Web::NOTICE: a response is a website's
    # words. What Web raises (Invalid, Blocked, Unavailable) fails the
    # request with its message.
    class HttpHandler < Base
      URL = { "type" => "string", "description" => "An http or https URL on the public internet, on its usual port" }.freeze
      HEADERS = { "type" => "object", "additionalProperties" => { "type" => "string" },
                  "description" => "Request headers to add (Accept, Accept-Language, ...), at most #{Web::MAX_HEADERS}. Host, " \
                                   "Content-Length, Connection, and the like are hob's to set" }.freeze
      RAW = { "type" => "boolean", "default" => false,
              "description" => "Give an HTML page back as it came, markup and forms included, instead of as its text" }.freeze
      MAX_CHARS = { "type" => "integer", "minimum" => 1, "maximum" => Web::MAX_CHARS, "default" => Web::DEFAULT_MAX_CHARS,
                    "description" => "Cap on the body's length; `body_truncated` says when it bit" }.freeze
      RESULT = "Returns { url, final_url, redirects, status, ok, headers: { content-type, location, ... }, content_type, " \
               "bytes, body, body_truncated, body_omitted?, notice }. An HTML body comes back as its text unless `raw`; a " \
               "body that is not text (an image, a PDF) is not shown, only its size. A status that is not 2xx is an " \
               "answer, not a failure: it comes back like any other".freeze
      WHERE = "hob goes only to http and https URLs on ports 80 and 443 whose host resolves to the public internet: " \
              "never to an address inside the household, its tailnet, or hob's own box, and a redirect that leads there " \
              "fails as Blocked. Nothing is kept between requests: no cookies, no login".freeze

      private

      def noticed(result)
        result.merge("notice" => Web::NOTICE)
      end
    end
  end
end
