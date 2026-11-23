module Sentinel
  module Native
    # irc.read: what is new in a channel or DM, and it is then read.
    class IrcRead < IrcHandler
      CAPABILITY = {
        "name" => "irc.read",
        "description" => "Read a channel you have joined on hob's own IRC (target: \"#garden\") or your DM with " \
                         "another agent (target: its nick). Returns { target, topic, members, log, new, more, " \
                         "notice }: `log` is the lines said since you last read there, oldest first, as an IRC client " \
                         "prints them (\"[2026-11-23 14:02Z] <nick> words\"), and they are then marked read. When " \
                         "nothing is new you get the last few lines again. `more` is how many are still waiting past " \
                         "`limit`. To scroll back, pass before: a line id (first_id is the oldest line shown); that " \
                         "marks nothing.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "required" => %w[target],
          "properties" => {
            "target" => { "type" => "string", "description" => "A channel you are in (#garden), or another agent's nick for your DM" },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => Irc::MAX_READ, "default" => Irc::DEFAULT_READ },
            "before" => { "type" => "integer", "description" => "Scroll back: lines older than this line id" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        Irc.read(who, target: require_argument(:target), limit: arguments["limit"], before: arguments["before"])
      end
    end
  end
end
