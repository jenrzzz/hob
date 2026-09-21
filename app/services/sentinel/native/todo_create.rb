module Sentinel
  module Native
    # todo.create: a new todo in a backend the agent can see. With no
    # backend named it lands in the only one visible (Todos.default_backend!),
    # and a backend behind a scoped tally key files it in that key's default
    # project, so a household agent's todos land in the household's folder.
    class TodoCreate < TodoHandler
      CAPABILITY = {
        "name" => "todo.create",
        "description" => "Create a todo. It goes to `backend` when named, else to the backend of `list` or `parent_id`, else " \
                         "to the only backend visible to the agent. With no `list` or `parent_id` it lands in the inbox (or " \
                         "the backend's default project). Returns { todo: {...}, notice }; keep the todo's id to update or " \
                         "complete it later.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => WRITABLE.merge(
            "backend" => { "type" => "string", "description" => "Backend name; needed only when more than one is visible" }
          ),
          "required" => %w[title],
          "additionalProperties" => false
        }
      }.freeze

      def call
        require_argument(:title)
        todo_result(Todos.create(arguments))
      end
    end
  end
end
