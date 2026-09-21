module Sentinel
  module Native
    # What the todo.* handlers share (TODOS.md). They are thin: Todos does
    # the work, at the agent's clearance, so the backends an agent can reach
    # are the ones RLS shows it and the handlers add no realm logic of their
    # own. Everything handed back carries Todos::NOTICE, since a todo's
    # title and notes are somebody else's words. What Todos raises (NotFound,
    # Invalid, Forbidden, Unavailable) fails the request with its message.
    class TodoHandler < Base
      ID = { "type" => "string", "description" => "A todo id as todo.list returns it: \"<backend>:<id>\"" }.freeze
      DATE = "ISO8601 time (2026-09-22T17:00:00Z) or a bare date (2026-09-22)".freeze

      # The writable attributes todo.create and todo.update have in common.
      WRITABLE = {
        "title" => { "type" => "string" },
        "notes" => { "type" => "string", "description" => "Replaces the notes" },
        "flagged" => { "type" => "boolean" },
        "due_at" => { "type" => %w[string null], "description" => "#{DATE}; null clears it" },
        "start_at" => { "type" => %w[string null],
                        "description" => "When the todo becomes actionable (OmniFocus's defer date). #{DATE}; null clears it" },
        "planned_at" => { "type" => %w[string null], "description" => "When the owner means to do it. #{DATE}; null clears it" },
        "estimate_minutes" => { "type" => %w[integer null], "minimum" => 0 },
        "tags" => { "type" => "array", "items" => { "type" => "string" }, "description" => "Tag names; replaces the whole set" },
        "list" => { "type" => %w[string null],
                    "description" => "A list id from todo.lists (\"<backend>:<id>\", or \"<backend>:inbox\"), or a project's " \
                                     "exact name; null is the inbox" },
        "parent_id" => { "type" => "string", "description" => "Nest it under this todo (same backend); instead of list" }
      }.freeze

      private

      def noticed(result)
        result.merge("notice" => Todos::NOTICE)
      end

      def todo_result(todo)
        noticed("todo" => todo)
      end
    end
  end
end
