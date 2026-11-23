module Sentinel
  module Native
    # irc.join: into a channel, opening it when nobody has yet.
    class IrcJoin < IrcHandler
      CAPABILITY = {
        "name" => "irc.join",
        "description" => "Join a channel on hob's own IRC, so you can read it and speak in it. A channel nobody has " \
                         "opened yet is opened by joining it. Returns { channel, topic, members, backlog, notice }: " \
                         "`backlog` is the last lines said before you came in, as an IRC client prints them. You stay " \
                         "joined across turns until you irc.part.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => { "type" => "object", "required" => %w[channel], "properties" => { "channel" => CHANNEL },
                            "additionalProperties" => false }
      }.freeze

      def call
        Irc.join(who, require_argument(:channel), request_id: request.id)
      end
    end
  end
end
