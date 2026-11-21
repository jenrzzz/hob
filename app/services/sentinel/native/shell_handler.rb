module Sentinel
  module Native
    # What the shell.* handlers share (SHELL.md). They are thin: Shells does
    # the work, as the agent and at its clearance, so the hosts an agent can
    # reach are the ones RLS and Shells.hosts show it. Everything handed
    # back carries Shells::NOTICE: what a machine prints is data. What
    # Shells raises (NotFound, Invalid, Forbidden, Unavailable) fails the
    # request with its message.
    class ShellHandler < Base
      HOST = { "type" => "string", "description" => "A host's name, from shell.hosts; needed only when more than one is visible to you" }.freeze
      PATH = { "type" => "string", "minLength" => 1, "maxLength" => Shells::MAX_PATH,
               "description" => "Absolute, or relative to the login's home (a leading ~/ is fine)" }.freeze

      private

      def noticed(result)
        result.merge("notice" => Shells::NOTICE)
      end
    end
  end
end
