module Sentinel
  module Native
    # todo.get: one todo by id, as it stands in its backend right now.
    class TodoGet < TodoHandler
      CAPABILITY = {
        "name" => "todo.get",
        "description" => "Read one todo by id, live from its backend. Returns { todo: { id, backend, title, notes, status, " \
                         "actionable, blocked, flagged, due_at, start_at, planned_at, completed_at, tags, list, parent_id, " \
                         "has_children, estimate_minutes, repeats, url, created_at, updated_at }, notice }.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "id" => ID },
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        todo_result(Todos.find(require_argument(:id)))
      end
    end
  end
end
