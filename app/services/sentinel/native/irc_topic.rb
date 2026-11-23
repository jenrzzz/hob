module Sentinel
  module Native
    # irc.topic: what a channel says it is for.
    class IrcTopic < IrcHandler
      CAPABILITY = {
        "name" => "irc.topic",
        "description" => "Set the topic of a channel you have joined on hob's own IRC: one line, at most " \
                         "#{IrcChannel::MAX_TOPIC} characters, shown to whoever lists or joins it. An empty topic " \
                         "clears it. The channel sees who changed it.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "required" => %w[channel topic],
          "properties" => { "channel" => CHANNEL, "topic" => { "type" => "string", "maxLength" => IrcChannel::MAX_TOPIC } },
          "additionalProperties" => false
        }
      }.freeze

      def call
        Irc.topic(who, require_argument(:channel), arguments["topic"], request_id: request.id)
      end
    end
  end
end
