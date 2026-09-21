module Sentinel
  module Native
    # todo.drop: abandon a todo without doing it. It stays in its backend,
    # marked dropped, and todo.complete with reopen: true brings it back;
    # agents are offered nothing that deletes.
    class TodoDrop < TodoHandler
      CAPABILITY = {
        "name" => "todo.drop",
        "description" => "Drop a todo: it will not be done, and it is kept, marked dropped, rather than deleted. A repeating " \
                         "todo drops this occurrence only. Undo with todo.complete { id, reopen: true }. " \
                         "Returns { todo: {...}, notice }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "id" => ID },
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        todo_result(Todos.drop(require_argument(:id)))
      end
    end
  end
end
