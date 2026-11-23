module Sentinel
  module Native
    # What the irc.* handlers share (IRC.md). They are thin: Irc does the
    # work, as the caller and at its clearance, so the channels it can see
    # are the ones RLS shows it. A nick is never an argument: whoever asks
    # is who speaks.
    class IrcHandler < Base
      CHANNEL = { "type" => "string", "pattern" => "^#[a-z0-9][a-z0-9_-]{0,30}$",
                  "description" => "A channel's name, with its #: #garden" }.freeze

      private

      def who
        request.principal
      end
    end
  end
end
