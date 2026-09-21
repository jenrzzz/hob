module Sentinel
  module Native
    # todo.update: change a todo's attributes, or move it. Only what is
    # named changes; null clears a date or an estimate.
    class TodoUpdate < TodoHandler
      CAPABILITY = {
        "name" => "todo.update",
        "description" => "Change a todo: only the attributes given are touched. `notes` replaces, `notes_append` adds to the " \
                         "end; `tags` replaces the set, `add_tags` and `remove_tags` adjust it; `list` or `parent_id` moves " \
                         "it. To finish or abandon a todo use todo.complete or todo.drop. Returns { todo: {...}, notice }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "id" => ID }.merge(WRITABLE).merge(
            "notes_append" => { "type" => "string", "description" => "Text added to the end of the notes" },
            "add_tags" => { "type" => "array", "items" => { "type" => "string" } },
            "remove_tags" => { "type" => "array", "items" => { "type" => "string" } }
          ),
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        todo_result(Todos.update(require_argument(:id), arguments.except("id")))
      end
    end
  end
end
