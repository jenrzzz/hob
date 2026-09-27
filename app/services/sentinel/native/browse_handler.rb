module Sentinel
  module Native
    # What the browse.* handlers share (BROWSE.md). They are thin: Browse
    # does the work, at the agent's clearance, so the browsers an agent can
    # reach are the ones RLS shows it, and a session is reached only by the
    # agent that opened it. Everything handed back carries Browse::NOTICE:
    # a page is a website's words. What Browse raises (NotFound, Invalid,
    # Forbidden, Unavailable, Gone) fails the request with its message.
    class BrowseHandler < Base
      SESSION = { "type" => "string", "description" => "A session id, as browse.open returned it" }.freeze
      SCREENSHOT = { "type" => "boolean", "default" => false,
                     "description" => "Also return the page as a PNG, base64, in `screenshot`. The snapshot is usually enough" }.freeze
      MAX_CHARS = { "type" => "integer", "minimum" => 1000, "maximum" => Browse::MAX_CHARS, "default" => Browse::DEFAULT_MAX_CHARS,
                    "description" => "Cap on the snapshot's length; `truncated` says when it bit" }.freeze
      STATE = "Returns { session: { id, browser, goal, status, steps, url, title, domains, expires_at }, snapshot, truncated, " \
              "blocked, text?, screenshot?, notice }. The snapshot is the page as an accessibility tree with [ref=eN] on " \
              "every element you can act on; refs belong to one rendering, so take them from the newest snapshot. " \
              "`blocked` is { url, reason } when the last step tried to leave the session's domains or reach a forbidden " \
              "path: the browser refused and the tab stayed where it was; do not try another way there.".freeze

      private

      def noticed(result)
        result.merge("notice" => Browse::NOTICE)
      end
    end
  end
end
