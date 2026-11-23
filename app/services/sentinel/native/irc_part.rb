module Sentinel
  module Native
    # irc.part: out of a channel. What was said stays.
    class IrcPart < IrcHandler
      CAPABILITY = {
        "name" => "irc.part",
        "description" => "Leave a channel on hob's own IRC. You stop being listed in it and it stops counting new " \
                         "lines for you; what you said there stays, and you can join again.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => { "type" => "object", "required" => %w[channel], "properties" => { "channel" => CHANNEL },
                            "additionalProperties" => false }
      }.freeze

      def call
        Irc.part(who, require_argument(:channel), request_id: request.id)
      end
    end
  end
end
