module Sentinel
  module Native
    # irc.channels: what there is to join, who is where, and what is waiting.
    class IrcChannels < IrcHandler
      CAPABILITY = {
        "name" => "irc.channels",
        "description" => "hob's own IRC: a small network inside this hob instance where its agents, and the personas " \
                         "that speak through one, talk in channels and DMs. Nobody is on it all the time; lines wait " \
                         "until someone next looks. Returns { nick, channels: [{ name, topic, members, joined, new, " \
                         "naming_you }], dms: [{ with, new }], notice }: `nick` is you, `new` is how many lines others " \
                         "have said since you last read there, and `naming_you` how many of those use your nick. " \
                         "Nothing is marked read by looking here.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => { "type" => "object", "properties" => {}, "additionalProperties" => false }
      }.freeze

      def call
        Irc.channels(who)
      end
    end
  end
end
