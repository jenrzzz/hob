module Sentinel
  module Native
    # todo.list: the todos visible at the agent's clearance, filtered. Which
    # backends that reaches is RLS's answer; the handler adds nothing.
    class TodoList < TodoHandler
      CAPABILITY = {
        "name" => "todo.list",
        "description" => "List todos from the household's todo backends visible at the agent's clearance (OmniFocus, by way " \
                         "of hob). Open todos by default; filter by what can be done now, list, tags, flag, dates, or text. " \
                         "Returns { todos: [{ id, backend, title, notes, status, actionable, blocked, flagged, due_at, start_at, " \
                         "planned_at, completed_at, tags, list, parent_id, has_children, estimate_minutes, repeats, url, " \
                         "created_at, updated_at }], count, unavailable: [{ backend, error }], notice }. A backend listed in " \
                         "`unavailable` could not be reached: its todos are missing from the answer, not absent.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "backend" => { "type" => "string", "description" => "Only this backend (a name from a todo's `backend`); default: all visible" },
            "status" => { "type" => "string", "enum" => Todos::STATUSES, "default" => "open" },
            "actionable" => { "type" => "boolean",
                              "description" => "true: only todos that can be done now; false: only open todos that are blocked " \
                                               "(deferred, waiting on another, on hold)" },
            "list" => { "type" => "string", "description" => "A list id from todo.lists; \"<backend>:inbox\" is that backend's inbox" },
            "tag" => { "type" => "array", "items" => { "type" => "string" }, "description" => "Tag names; a todo must carry every one" },
            "flagged" => { "type" => "boolean" },
            "due_before" => { "type" => "string", "description" => DATE },
            "due_after" => { "type" => "string", "description" => DATE },
            "start_before" => { "type" => "string", "description" => "Start (defer) date before this. #{DATE}" },
            "updated_after" => { "type" => "string", "description" => "Changed since. #{DATE}" },
            "q" => { "type" => "string", "description" => "Words that must all appear in the title or notes" },
            "sort" => { "type" => "string", "description" => "due, start, created, updated, or title; prefix - to reverse. Nulls last",
                        "pattern" => "^-?(#{Todos::SORTS.keys.join('|')})$" },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => Todos::MAX_LIMIT, "default" => Todos::DEFAULT_LIMIT }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        result = Todos.list(arguments)
        noticed("todos" => result["todos"], "count" => result["todos"].size, "unavailable" => result["unavailable"])
      end
    end
  end
end
