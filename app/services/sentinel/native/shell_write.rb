module Sentinel
  module Native
    # shell.write: a whole file put in place, its content never meeting a shell.
    class ShellWrite < ShellHandler
      CAPABILITY = {
        "name" => "shell.write",
        "description" => "Write a text file on a machine you may use (shell.hosts), as the login: the whole file, " \
                         "replacing what was there, or added to its end with `append`. The directory is made if it " \
                         "is missing. The content arrives exactly as you give it, with no quoting to get right, so " \
                         "prefer this to echo or a heredoc in shell.exec. At most #{Shells::MAX_CONTENT / 1024} KB. " \
                         "Returns { host, path, bytes, appended, notice }. Where the login may not write (/etc, " \
                         "another user's files), write to your home and move it into place with sudo in shell.exec. " \
                         "A file under a directory the machine serves to the internet is published the moment it lands.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "path" => PATH,
            "content" => { "type" => "string", "description" => "The file's text" },
            "host" => HOST,
            "append" => { "type" => "boolean", "default" => false, "description" => "Add to the end instead of replacing" },
            "mode" => { "type" => "string", "pattern" => "^[0-7]{3,4}$", "description" => "Permissions to set, octal: 644, 755, 600" }
          },
          "required" => %w[path content],
          "additionalProperties" => false
        }
      }.freeze

      def call
        raise Error, "content is required" unless arguments.key?("content")

        noticed(Shells.write(path: require_argument(:path), content: arguments["content"], host: arguments["host"],
                             append: arguments["append"], mode: arguments["mode"]))
      end
    end
  end
end
