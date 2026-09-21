module Todos
  module Backends
    # What an adapter answers, and the helpers every adapter wants. Todos
    # (the façade) has already validated and normalized what arrives here:
    # filters and attributes are string-keyed, dates are ISO8601 strings or
    # nil, ids are the backend's own (native) ids with hob's "<backend>:"
    # prefix taken off. What goes back is the normalized shape in TODOS.md,
    # string-keyed, with the prefix put back on (`todo_id`, `list_id`).
    #
    #   list(filters)          → [todo]      find(id)          → todo
    #   create(attrs)          → todo        update(id, attrs) → todo
    #   complete(id) reopen(id) drop(id)     → todo
    #   destroy(id)            → true
    #   lists(filters)         → [list], the synthetic inbox included when there is one
    #   check                  → { "reachable" => true, ... } or raises
    #
    # An adapter raises Todos::NotFound, Invalid, Forbidden, or Unavailable
    # and nothing else; the façade and the controllers know what those mean.
    class Base
      INBOX = "inbox".freeze

      attr_reader :backend

      # Problems with a row's config, as sentences; none by default.
      def self.config_errors(_config)
        []
      end

      def initialize(backend)
        @backend = backend
      end

      %i[list find create update complete reopen drop destroy lists check].each do |operation|
        define_method(operation) { |*| raise NotImplementedError, "#{self.class.name} does not implement #{operation}" }
      end

      private

      def todo_id(native)
        native.presence && "#{backend.name}:#{native}"
      end
      alias_method :list_id, :todo_id

      def inbox_id
        list_id(INBOX)
      end

      # Every backend has an inbox: the list a todo is in when its `list` is null.
      def inbox_list(open_count: nil)
        { "id" => inbox_id, "backend" => backend.name, "name" => "Inbox", "kind" => "inbox", "path" => nil,
          "status" => "active", "open_count" => open_count }
      end

      # `list` on a write is a list id or a plain project name. It is an id
      # only when it carries this backend's prefix; "Home : Garden" is a name.
      # -> [:inbox] | [:id, native] | [:name, string]
      def list_reference(value)
        prefix, native = value.to_s.split(":", 2)
        return [ :name, value.to_s ] unless prefix == backend.name && native.present?

        native == INBOX ? [ :inbox ] : [ :id, native ]
      end

      # A todo id from another backend cannot be this one's parent.
      def native_id!(id, what)
        prefix, native = id.to_s.split(":", 2)
        raise Todos::Invalid, "#{what} #{id.inspect} is not in #{backend.name}" unless prefix == backend.name && native.present?

        native
      end

      # Times leave as UTC ISO8601 whatever the backend's own spelling.
      def iso(value)
        return nil if value.blank?

        (value.respond_to?(:utc) ? value : Time.iso8601(value.to_s)).utc.iso8601
      rescue ArgumentError
        value.to_s
      end
    end
  end
end
