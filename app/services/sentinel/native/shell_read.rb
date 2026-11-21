module Sentinel
  module Native
    # shell.read: a text file on a machine the agent may use, or a slice of it.
    class ShellRead < ShellHandler
      CAPABILITY = {
        "name" => "shell.read",
        "description" => "Read a text file on a machine you may use (shell.hosts), as the login: a config, a source " \
                         "file, the end of a log. Returns { host, path, content, bytes, offset, truncated, notice }: " \
                         "`bytes` is the whole file's size, `content` is up to `max_bytes` of it from `offset`, and " \
                         "`truncated` says there is more after it. A file the login cannot read, or one that is not " \
                         "text, fails the request with the reason; for those use shell.exec (sudo cat, file, xxd, sqlite3).",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "path" => PATH,
            "host" => HOST,
            "offset" => { "type" => "integer", "minimum" => 0, "description" => "Bytes to skip from the start (default 0)" },
            "max_bytes" => { "type" => "integer", "minimum" => 1, "maximum" => Shells::MAX_READ,
                             "description" => "At most this many bytes (default #{Shells::DEFAULT_READ})" }
          },
          "required" => %w[path],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Shells.read(path: require_argument(:path), host: arguments["host"], offset: arguments["offset"],
                            max_bytes: arguments["max_bytes"]))
      end
    end
  end
end
