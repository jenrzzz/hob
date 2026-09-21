module V1
  # The lists todos sit in: a backend's projects, and its inbox.
  #
  # GET /v1/todo_lists?backend=&status=active|on_hold|done|dropped|all&q=
  #     → { lists: [{ id, backend, name, kind: project|inbox, path, status, open_count }], unavailable: [...] }
  class TodoListsController < ApplicationController
    include TodoErrors

    def index
      render json: Todos.lists(request.query_parameters.to_h)
    end
  end
end
