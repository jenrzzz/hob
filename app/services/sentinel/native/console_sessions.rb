module Sentinel
  module Native
    # console.sessions: what the agent has open, for picking up after a
    # restart, and which consoles it could open one on.
    class ConsoleSessions < ConsoleHandler
      CAPABILITY = {
        "name" => "console.sessions",
        "description" => "Your open console sessions, and the consoles visible to you. Returns { sessions: [{ id, " \
                         "console, machine, goal, status, steps, expires_at, created_at, last_step_at }], consoles: " \
                         "[{ name, machine }], notice }. A session listed here can be continued with console.act or " \
                         "console.screen; check here before opening another.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => { "type" => "object", "properties" => {}, "additionalProperties" => false }
      }.freeze

      def call
        {
          "sessions" => Consoles.sessions.map(&:as_json),
          "consoles" => Consoles.consoles.map { |row| { "name" => row.name, "machine" => row.machine } },
          "notice" => Consoles::NOTICE
        }
      end
    end
  end
end
