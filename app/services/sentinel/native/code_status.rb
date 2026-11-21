module Sentinel
  module Native
    # code.status: how the agent's commissions went, and where its repos are.
    class CodeStatus < CodeHandler
      CAPABILITY = {
        "name" => "code.status",
        "description" => "How the work you handed to Claude Code with code.start went. With `id`, one commission in " \
                         "full: #{SHAPE}, where `said` is Claude Code's whole report (what it made, how to run it, what " \
                         "is unfinished), `commits` the commits it pushed, and `brief` what you asked. Without `id`, " \
                         "{ commissions: [the last #{Commissions::RECENT}, newest first, each in brief], repos: [{ name, " \
                         "repo, about }] }: `about` is what a person wrote about the repo, such as where it is cloned on " \
                         "your machine. When one is done with outcome pushed, the work is on its branch: git pull where " \
                         "the repo is cloned, read what arrived, then run it.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "id" => { "type" => "string", "description" => "A commission's id, as code.start returned it" } },
          "additionalProperties" => false
        }
      }.freeze

      def call
        return noticed("commission" => Commissions.status(arguments["id"])) if arguments["id"].present?

        noticed("commissions" => Commissions.status,
                "repos" => Commissions.repos.map { |row| { "name" => row.name, "repo" => row.repo, "about" => row.about }.compact })
      end
    end
  end
end
