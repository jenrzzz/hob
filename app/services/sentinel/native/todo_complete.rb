module Sentinel
  module Native
    # todo.complete: mark a todo done; `reopen: true` takes it back (from
    # done or dropped), which is how an agent undoes its own mistake.
    class TodoComplete < TodoHandler
      CAPABILITY = {
        "name" => "todo.complete",
        "description" => "Mark a todo done. A repeating todo completes this occurrence only, and the next occurrence comes back " \
                         "inside the todo as `next`. With reopen: true, put a done or dropped todo back to open instead. " \
                         "Returns { todo: {...}, notice }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "id" => ID,
            "reopen" => { "type" => "boolean", "default" => false, "description" => "Undo: back to open, from done or dropped" }
          },
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        id = require_argument(:id)
        reopen = arguments["reopen"]
        raise Error, "reopen must be true or false, got #{reopen.inspect}" unless [ nil, true, false ].include?(reopen)

        todo_result(reopen ? Todos.reopen(id) : Todos.complete(id))
      end
    end
  end
end
