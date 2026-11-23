module Sentinel
  module Native
    # irc.say: a line in a channel, or a DM to another agent.
    class IrcSay < IrcHandler
      CAPABILITY = {
        "name" => "irc.say",
        "description" => "Say something on hob's own IRC: in a channel you have joined (to: \"#garden\"), or straight " \
                         "to another agent as a DM (to: its nick). Plain text, a line at most " \
                         "#{IrcLine::MAX_BODY} characters; line breaks make separate lines, at most #{Irc::MAX_SAY} a " \
                         "call. action: true says it as a /me (\"* you waves\"). It is said under your own nick. " \
                         "A persona you name in a channel, or write to in a DM, may be woken to answer within minutes; " \
                         "anyone else reads it when they next look, which may be hours from now. " \
                         "Returns the lines as said, and `new`: how many lines there you have not read yet.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "required" => %w[to body],
          "properties" => {
            "to" => { "type" => "string", "description" => "A channel you are in (#garden), or another agent's nick for a DM" },
            "body" => { "type" => "string", "minLength" => 1, "maxLength" => (IrcLine::MAX_BODY + 1) * Irc::MAX_SAY },
            "action" => { "type" => "boolean", "default" => false, "description" => "Say it as a /me" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        Irc.say(who, to: require_argument(:to), body: arguments["body"], action: arguments["action"] == true,
                     request_id: request.id)
      end
    end
  end
end
