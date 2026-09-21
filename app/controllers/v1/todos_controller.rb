module V1
  # Todos (TODOS.md): the normalized contract over whatever backends are
  # visible at the key's clearance. Surfaces' and people's keys only: an
  # agent asks the sentinel for todo.list, todo.create, and the rest.
  #
  # GET    /v1/todos?backend=&status=open|done|dropped|all&actionable=&list=&tag[]=&flagged=
  #                 &due_before=&due_after=&start_before=&q=&updated_after=&sort=&limit=
  #                                  → { todos: [...], unavailable: [{ backend, error }] }
  # GET    /v1/todos/:id             an id is "<backend>:<the backend's own id>"
  # POST   /v1/todos                 { title, notes?, flagged?, due_at?, start_at?, planned_at?, estimate_minutes?,
  #                                    tags?, list?, parent_id?, backend? } → 201 the todo
  # PATCH  /v1/todos/:id             the same, plus notes_append, add_tags, remove_tags; null clears a date
  # POST   /v1/todos/:id/complete · /reopen · /drop
  # DELETE /v1/todos/:id             gone for good, children included
  #
  # An unknown filter or attribute is a 422, never ignored.
  class TodosController < ApplicationController
    include TodoErrors

    # The JSON body is the attributes, exactly: no `todo: {...}` copy of it.
    wrap_parameters false

    def index
      render json: Todos.list(request.query_parameters.to_h)
    end

    def show
      render json: Todos.find(params[:id])
    end

    def create
      render json: Todos.create(request.request_parameters.to_h), status: :created
    end

    def update
      render json: Todos.update(params[:id], request.request_parameters.to_h)
    end

    def destroy
      Todos.destroy(params[:id])
      head :no_content
    end

    def complete
      render json: Todos.complete(params[:id])
    end

    def reopen
      render json: Todos.reopen(params[:id])
    end

    def drop
      render json: Todos.drop(params[:id])
    end
  end
end
