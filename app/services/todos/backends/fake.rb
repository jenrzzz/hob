module Todos
  module Backends
    # An in-memory backend with the real ones' surface, for tests: todos and
    # lists live in a Store per backend name, ids count up (t1, t2; l1, l2),
    # and nothing leaves the process. It is a kind only in the test
    # environment (Todos::Backends registers it there), so no production row
    # can be pointed at it.
    #
    #   store = Todos::Backends::Fake.store("house")     # the row's name
    #   store.add_list("Garden", path: "Home")
    #   Todos::Backends::Fake.fail!("house", Todos::Unavailable.new("the mini is asleep"))
    #   Todos::Backends::Fake.reset!                     # in teardown
    class Fake < Base
      class Store
        attr_reader :todos, :lists
        # false: behave like a scoped tally key, which has no inbox.
        attr_accessor :inbox, :error

        def initialize
          @todos = {}
          @lists = {}
          @inbox = true
          @counters = Hash.new(0)
        end

        def add_list(name, path: nil, status: "active")
          id = next_id("l")
          @lists[id] = { "id" => id, "name" => name, "path" => path, "status" => status }
          id
        end

        def next_id(prefix)
          "#{prefix}#{@counters[prefix] += 1}"
        end
      end

      class << self
        def stores
          @stores ||= Hash.new { |stores, name| stores[name] = Store.new }
        end

        def store(name)
          stores[name.to_s]
        end

        # Every call to this backend raises `error` until reset!.
        def fail!(name, error = Todos::Unavailable.new("#{name} is unreachable"))
          store(name).error = error
        end

        def reset!
          @stores = nil
        end
      end

      def list(filters)
        guard!
        matching = store.todos.values.select { |record| matches?(record, filters) }.map { |record| todo(record) }
        Todos.sorted(matching, filters["sort"]).first(filters["limit"] || Todos::DEFAULT_LIMIT)
      end

      def find(id)
        guard!
        todo(record!(id))
      end

      def create(attributes)
        guard!
        now = stamp(Time.current)
        record = { "id" => store.next_id("t"), "title" => attributes["title"], "notes" => "", "status" => "open",
                   "flagged" => false, "tags" => [], "list" => nil, "parent" => nil, "blocked" => false,
                   "created_at" => now, "updated_at" => now }
        assign(record, attributes)
        store.todos[record["id"]] = record
        todo(record)
      end

      def update(id, attributes)
        guard!
        record = record!(id)
        assign(record, attributes)
        todo(touch(record))
      end

      def complete(id)
        guard!
        todo(touch(record!(id).merge!("status" => "done", "completed_at" => stamp(Time.current))))
      end

      def reopen(id)
        guard!
        todo(touch(record!(id).merge!("status" => "open", "completed_at" => nil)))
      end

      def drop(id)
        guard!
        todo(touch(record!(id).merge!("status" => "dropped")))
      end

      # Children go with it, as they do in OmniFocus.
      def destroy(id)
        guard!
        record = record!(id)
        store.todos.delete_if { |native, other| native == record["id"] || other["parent"] == record["id"] }
        true
      end

      def lists(filters)
        guard!
        projects = store.lists.values.select { |list| list_matches?(list, filters) }.map do |list|
          { "id" => list_id(list["id"]), "backend" => backend.name, "name" => list["name"], "kind" => "project",
            "path" => list["path"], "status" => list["status"], "open_count" => open_in(list["id"]) }
        end
        inbox = store.inbox && list_matches?({ "name" => "Inbox", "status" => "active" }, filters) ? inbox_list(open_count: open_in(nil)) : nil
        [ inbox, *projects ].compact
      end

      def check
        guard!
        { "reachable" => true, "counts" => { "tasks" => store.todos.size } }
      end

      private

      def store
        self.class.store(backend.name)
      end

      def guard!
        raise store.error if store.error
      end

      def record!(id)
        store.todos[id.to_s] || raise(Todos::NotFound, "no todo #{todo_id(id)}")
      end

      def touch(record)
        record.merge!("updated_at" => stamp(Time.current))
      end

      def assign(record, attributes)
        raise Todos::Invalid, "give a list or a parent_id, not both" if attributes["list"].present? && attributes["parent_id"].present?

        record.merge!(attributes.slice("title", "notes", "flagged", "estimate_minutes"))
        record["notes"] = [ record["notes"].presence, attributes["notes_append"] ].compact.join("\n") if attributes["notes_append"]
        %w[due_at start_at planned_at].each { |name| record[name] = stamp(attributes[name]) if attributes.key?(name) }
        record["tags"] = attributes["tags"].uniq if attributes["tags"]
        record["tags"] = (record["tags"] | attributes["add_tags"]) if attributes["add_tags"]
        record["tags"] -= attributes["remove_tags"] if attributes["remove_tags"]
        if attributes["parent_id"].present?
          parent = record!(native_id!(attributes["parent_id"], "parent_id"))
          record.merge!("parent" => parent["id"], "list" => parent["list"])
        elsif attributes.key?("list")
          record.merge!("parent" => nil, "list" => list_native!(attributes["list"]))
        end
      end

      # nil is the inbox; an id must exist; so must a name.
      def list_native!(value)
        return nil if value.nil?

        kind, reference = list_reference(value)
        return nil if kind == :inbox

        found = kind == :id ? store.lists[reference] : store.lists.values.find { |list| list["name"] == reference }
        found ? found["id"] : raise(Todos::NotFound, "no list #{value.inspect} in #{backend.name}")
      end

      def todo(record)
        list = record["list"] && store.lists[record["list"]]
        actionable = actionable?(record)
        {
          "id" => todo_id(record["id"]), "backend" => backend.name, "title" => record["title"], "notes" => record["notes"].to_s,
          "status" => record["status"], "actionable" => actionable, "blocked" => record["status"] == "open" && !actionable,
          "flagged" => record["flagged"] ? true : false,
          "due_at" => record["due_at"], "start_at" => record["start_at"], "planned_at" => record["planned_at"],
          "completed_at" => record["completed_at"], "tags" => record["tags"],
          "list" => list && { "id" => list_id(list["id"]), "name" => list["name"] },
          "parent_id" => todo_id(record["parent"]),
          "has_children" => store.todos.values.any? { |other| other["parent"] == record["id"] },
          "estimate_minutes" => record["estimate_minutes"], "repeats" => false,
          "url" => "fake:///task/#{record['id']}", "created_at" => record["created_at"], "updated_at" => record["updated_at"]
        }
      end

      # Open, not marked blocked, and past its start date.
      def actionable?(record)
        record["status"] == "open" && !record["blocked"] && (record["start_at"].nil? || record["start_at"] <= stamp(Time.current))
      end

      def matches?(record, filters)
        status = filters["status"] || "open"
        return false unless status == "all" || record["status"] == status
        return false if !filters["actionable"].nil? && actionable?(record) != filters["actionable"]
        return false if !filters["flagged"].nil? && (record["flagged"] ? true : false) != filters["flagged"]
        return false if filters["list"].present? && record["list"] != list_native!(filters["list"])
        return false unless Array(filters["tag"]).all? { |tag| record["tags"].include?(tag) }
        return false if filters["due_before"] && !(record["due_at"] && record["due_at"] < stamp(filters["due_before"]))
        return false if filters["due_after"] && !(record["due_at"] && record["due_at"] > stamp(filters["due_after"]))
        return false if filters["start_before"] && !(record["start_at"] && record["start_at"] < stamp(filters["start_before"]))
        return false if filters["updated_after"] && record["updated_at"] <= stamp(filters["updated_after"])

        text = "#{record['title']} #{record['notes']}".downcase
        filters["q"].to_s.downcase.split.all? { |word| text.include?(word) }
      end

      def list_matches?(list, filters)
        status = filters["status"] || "active"
        (status == "all" || list["status"] == status) && list["name"].downcase.include?(filters["q"].to_s.downcase)
      end

      def open_in(list)
        store.todos.values.count { |record| record["status"] == "open" && record["list"] == list }
      end

      # UTC ISO8601, from a Time or from what a caller wrote (a bare date is midnight UTC here).
      def stamp(value)
        return nil if value.blank?

        (value.respond_to?(:utc) ? value : Time.zone.parse(value.to_s)).utc.iso8601
      end
    end
  end
end
