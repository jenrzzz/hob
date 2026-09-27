module Sentinel
  module Native
    # browse.sessions: what the agent has open, for picking up after a
    # restart, and which browsers it could open one in.
    class BrowseSessions < BrowseHandler
      CAPABILITY = {
        "name" => "browse.sessions",
        "description" => "Your open browsing sessions, and the browsers visible to you. Returns { sessions: [{ id, browser, " \
                         "goal, status, steps, url, title, domains, created_at, last_step_at }], browsers: [{ name, domains }], " \
                         "notice }. A session listed here can be continued with browse.act or browse.snapshot; check here " \
                         "before opening a second session for the same goal.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => { "type" => "object", "properties" => {}, "additionalProperties" => false }
      }.freeze

      def call
        noticed(
          "sessions" => Browse.sessions.map(&:as_json),
          "browsers" => Browse.browsers.map { |row| { "name" => row.name, "domains" => row.domains } }
        )
      end
    end
  end
end
