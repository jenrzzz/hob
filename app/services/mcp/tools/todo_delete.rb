module Mcp
  module Tools
    # todo.delete (TODOS.md): the one todo operation no agent is offered.
    class TodoDelete < Sentinel::Native::Base
      TOOL = {
        "name" => "todo.delete",
        "description" => "Delete a todo for good, its children included. There is no undo: todo_drop is how a todo that " \
                         "will not be done is normally put away, and it keeps the record. Returns { deleted: id }.",
        "kind" => "act",
        "destructive" => true,
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "id" => Sentinel::Native::TodoHandler::ID },
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        id = require_argument(:id)
        Todos.destroy(id)
        { "deleted" => id }
      end
    end
  end
end
