module Sentinel
  module Native
    # todo.lists: the lists todos sit in (a backend's projects and its
    # inbox), for an agent deciding where a new todo belongs.
    class TodoLists < TodoHandler
      CAPABILITY = {
        "name" => "todo.lists",
        "description" => "List the lists todos sit in: each visible backend's projects, and its inbox when it has one. " \
                         "Returns { lists: [{ id, backend, name, kind: project|inbox, path, status, open_count }], " \
                         "unavailable: [{ backend, error }], notice }. Use a list's id as `list` in todo.list, todo.create, " \
                         "and todo.update.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "backend" => { "type" => "string", "description" => "Only this backend; default: all visible" },
            "status" => { "type" => "string", "enum" => Todos::LIST_STATUSES, "default" => "active" },
            "q" => { "type" => "string", "description" => "Text in the list's name" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Todos.lists(arguments))
      end
    end
  end
end
