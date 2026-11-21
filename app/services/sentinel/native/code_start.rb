module Sentinel
  module Native
    # code.start: hand a piece of building to Claude Code.
    class CodeStart < CodeHandler
      CAPABILITY = {
        "name" => "code.start",
        "description" => "Hand a piece of building to Claude Code: a real coding agent that works in a sandbox, in a " \
                         "git repo that is yours, and pushes what it made there for you to pull onto your machine and " \
                         "run. Use it for anything more than a few lines (a page, a service, a script with moving " \
                         "parts): it writes and tests far more than you can in one turn, and it costs nothing, where " \
                         "writing code yourself through shell.write spends your own turns. Small edits and config are " \
                         "still quicker by hand. It is not a conversation: Claude Code sees only the brief and what is " \
                         "already in the repo, cannot reach your machine, and cannot ask you anything, so the brief " \
                         "says everything: what to make, how it should behave, what it runs on, how you want to start " \
                         "it. It takes minutes to an hour, and you are not waiting on it: this returns at once with an " \
                         "id, and code.status (or your next beat) says how it went. At most " \
                         "#{Commissions::MAX_OPEN} under way at a time. Returns #{SHAPE} and notice. To build on " \
                         "earlier work, start another with the same branch.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "title" => { "type" => "string", "minLength" => 3, "maxLength" => Commissions::TITLE_MAX,
                         "description" => "A few words naming the work; it becomes the commit message if Claude Code leaves none" },
            "brief" => { "type" => "string", "minLength" => Commissions::BRIEF_MIN, "maxLength" => Commissions::BRIEF_MAX,
                         "description" => "The whole request, in your own words" },
            "branch" => { "type" => "string", "description" => "The branch to work on and push to (default: the repo's main one). Made if it does not exist" },
            "repo" => { "type" => "string", "description" => "A repo's name; needed only if you have more than one" }
          },
          "required" => %w[title brief],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Commissions.start(title: require_argument(:title), brief: require_argument(:brief), branch: arguments["branch"],
                                  repo: arguments["repo"], request: request))
      end
    end
  end
end
