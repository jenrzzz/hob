module Sentinel
  module Native
    # shell.exec: one command on a machine the agent may use.
    class ShellExec < ShellHandler
      CAPABILITY = {
        "name" => "shell.exec",
        "description" => "Run one command on a machine you may use (shell.hosts), over ssh, through the login's shell: " \
                         "pipes, &&, redirects, and sudo where the login has it all work. Every call is its own " \
                         "connection starting in the login's home (or `cwd`): no terminal, and no directory, variable, " \
                         "or shell state carries to the next call, so say cd and export in the same command, and " \
                         "nothing may wait for a keypress (apt-get -y, git with no pager, no editors). Returns { host, " \
                         "exit, stdout, stderr, seconds, truncated?, timed_out?, note?, notice }. Each of stdout and " \
                         "stderr is kept to #{Shells::MAX_OUTPUT / 1000} KB, the first half and the last; send long " \
                         "output to a file and read the part you need. hob waits `timeout` seconds (default " \
                         "#{Shells::DEFAULT_TIMEOUT}, at most #{Shells::MAX_TIMEOUT}) and then hangs up without stopping " \
                         "the command. For anything that should keep running (a server, a long build), start it so it " \
                         "does not hold the connection: a systemd unit, or `nohup ... > log 2>&1 &`, then look in on " \
                         "it with later calls. To put a file in place use shell.write, not a heredoc.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "command" => { "type" => "string", "minLength" => 1, "maxLength" => Shells::MAX_COMMAND,
                           "description" => "The command line, as you would type it at a shell prompt" },
            "host" => HOST,
            "cwd" => PATH.merge("description" => "Directory to run in. #{PATH['description']}"),
            "stdin" => { "type" => "string", "description" => "Text for the command's standard input, at most #{Shells::MAX_STDIN / 1024} KB" },
            "timeout" => { "type" => "integer", "minimum" => 1, "maximum" => Shells::MAX_TIMEOUT,
                           "description" => "Seconds hob waits for the command (default #{Shells::DEFAULT_TIMEOUT})" }
          },
          "required" => %w[command],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Shells.exec(command: require_argument(:command), host: arguments["host"], cwd: arguments["cwd"],
                            stdin: arguments["stdin"], timeout: arguments["timeout"]))
      end
    end
  end
end
