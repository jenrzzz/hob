require "time"

module Hob
  # One todo in hob's normalized shape, wherever it lives (OmniFocus, say).
  # `id` is "<backend>:<the backend's own id>"; `start_at` is when it becomes
  # actionable (OmniFocus's defer date); `list` is { "id", "name" } or nil
  # for the inbox. `next` is set on the answer to `complete` when a
  # repeating todo made its next occurrence.
  class Todo < Record
    attribute :id, :backend, :title, :notes, :status, :actionable, :blocked, :flagged, :due_at, :start_at, :planned_at,
              :completed_at, :tags, :list, :parent_id, :has_children, :estimate_minutes, :repeats, :url,
              :created_at, :updated_at

    def open?
      status == "open"
    end

    def done?
      status == "done"
    end

    def dropped?
      status == "dropped"
    end

    def actionable?
      actionable == true
    end

    def flagged?
      flagged == true
    end

    def next
      @data["next"] && Todo.new(@data["next"])
    end
  end

  # Where todos sit: a backend's project, or its inbox (kind: project | inbox).
  class TodoList < Record
    attribute :id, :backend, :name, :kind, :path, :status, :open_count

    def inbox?
      kind == "inbox"
    end
  end

  # A place todos live, as hob shows it: the key is never in it, only
  # config["key"] == "set" or config["key_env"].
  class TodoBackend < Record
    attribute :id, :name, :kind, :owner, :realm, :enabled, :primary, :config, :created_at, :updated_at
  end

  # What `list` and `lists` return: the records, enumerable, plus the
  # backends that could not answer. When `partial?`, what is missing is
  # missing, not absent.
  class TodoListing
    include Enumerable

    attr_reader :items, :unavailable

    def initialize(items, unavailable)
      @items = items
      @unavailable = unavailable || []
    end

    def each(&block)
      @items.each(&block)
    end

    def size
      @items.size
    end

    def empty?
      @items.empty?
    end

    def [](index)
      @items[index]
    end

    def last
      @items.last
    end

    def partial?
      !@unavailable.empty?
    end
  end

  # /v1/todos: the household's todos through hob's one contract, whatever
  # backend holds them. What this key can see is its clearance's business;
  # an agent's key cannot call these at all (it asks the sentinel for
  # todo.list, todo.create, ...).
  class Todos
    def initialize(http)
      @http = http
    end

    # GET /v1/todos → Hob::TodoListing of Hob::Todo.
    #   backend:, status: open (default) | done | dropped | all, actionable:, list: (a list id; "<backend>:inbox"),
    #   tag: (a name or several; a todo must carry every one), flagged:, due_before:, due_after:, start_before:,
    #   q:, updated_after:, sort: due | start | created | updated | title ("-" reverses), limit: (100; at most 500)
    # Times may be Time objects. An unknown filter is Hob::Invalid.
    def list(**filters)
      data = @http.get("/v1/todos", query(filters))
      TodoListing.new(data["todos"].map { |t| Todo.new(t) }, data["unavailable"])
    end

    def find(id)
      Todo.new(@http.get(path(id)))
    end

    # POST /v1/todos. title:, and any of notes:, flagged:, due_at:, start_at:, planned_at:, estimate_minutes:,
    # tags:, list: (a list id or a project's name), parent_id:, backend: (default: your primary, or the only one).
    def create(**attributes)
      Todo.new(@http.post("/v1/todos", body(attributes)))
    end

    # PATCH /v1/todos/:id. The same attributes, plus notes_append:, add_tags:, remove_tags:. Only what is named
    # changes; nil clears a date or an estimate, and `list: nil` moves it to the inbox.
    def update(id, **attributes)
      Todo.new(@http.patch(path(id), body(attributes)))
    end

    def complete(id)
      Todo.new(@http.post("#{path(id)}/complete", nil))
    end

    # Back to open, from done or dropped.
    def reopen(id)
      Todo.new(@http.post("#{path(id)}/reopen", nil))
    end

    def drop(id)
      Todo.new(@http.post("#{path(id)}/drop", nil))
    end

    # Gone for good, children included.
    def delete(id)
      @http.delete(path(id))
      true
    end

    # GET /v1/todo_lists → Hob::TodoListing of Hob::TodoList. backend:, status: active (default) | on_hold | done |
    # dropped | all, q:
    def lists(**filters)
      data = @http.get("/v1/todo_lists", query(filters))
      TodoListing.new(data["lists"].map { |l| TodoList.new(l) }, data["unavailable"])
    end

    # GET /v1/todo_backends — a person's key.
    def backends
      @http.get("/v1/todo_backends").map { |b| TodoBackend.new(b) }
    end

    private

    def path(id)
      id = id.id if id.respond_to?(:id)
      "/v1/todos/#{URI.encode_www_form_component(id.to_s).gsub('+', '%20')}"
    end

    # Rails reads a repeated parameter as `tag[]`.
    def query(filters)
      filters.compact.to_h do |name, value|
        value = value.map { |v| wire(v) } if value.is_a?(Array)
        value.is_a?(Array) ? [ "#{name}[]", value ] : [ name, wire(value) ]
      end
    end

    def body(attributes)
      attributes.transform_values { |value| wire(value) }
    end

    def wire(value)
      value.respond_to?(:iso8601) ? value.iso8601 : value
    end
  end
end
