require "net/http"

module Todos
  module Backends
    # OmniFocus, by way of tally: an HTTP server on the owner's Mac that
    # carries each call out inside the OmniFocus app. tally knows nothing of
    # hob; this class is the whole of what hob knows of tally (its API.md).
    #
    #   todo   ← a tally task       list ← a tally project, plus the inbox
    #   start_at is OmniFocus's defer date; dates and flags are the
    #   *effective* ones (inherited from a project or parent counts)
    #
    # The bearer key is the backend row's (TodoBackend#key). A key tally has
    # *scoped* to a folder, project, or tag sees only that much of OmniFocus,
    # has no inbox, and files new todos in the key's default project; that is
    # how one OmniFocus is shared with household agents (TODOS.md).
    class Omnifocus < Base
      # Tests inject a lambda (verb, url, body, headers) -> [status, body]
      # here, as they do with Sentinel::Webhook.transport, so nothing in the
      # suite touches the network.
      class_attribute :transport

      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 30
      CONFIG_KEYS = %w[url key key_env addr create_tags].freeze
      ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/

      ACTIONABLE = %w[available next due_soon overdue].freeze
      TASK_STATUS = { "open" => "remaining", "done" => "completed", "dropped" => "dropped", "all" => "all" }.freeze
      PROJECT_FIELDS = "id,name,status,folder,remaining_count".freeze
      TASK_SORT = { "due" => "due", "start" => "defer", "created" => "added", "updated" => "modified", "title" => "name" }.freeze
      # hob's attribute → tally's field, where only the name differs.
      FIELDS = { "title" => "name", "notes" => "note", "notes_append" => "note_append", "flagged" => "flagged",
                 "due_at" => "due", "start_at" => "defer", "planned_at" => "planned",
                 "estimate_minutes" => "estimated_minutes", "tags" => "tags", "add_tags" => "add_tags",
                 "remove_tags" => "remove_tags" }.freeze

      def self.config_errors(config)
        errors = []
        unknown = config.keys - CONFIG_KEYS
        errors << "has unknown keys #{unknown.join(', ')} (known: #{CONFIG_KEYS.join(', ')})" if unknown.any?
        errors << "needs a url (http or https): where tally listens" unless config["url"].to_s.match?(%r{\Ahttps?://\S+\z})
        errors << "needs a key or a key_env: tally's bearer key" if config["key"].blank? && config["key_env"].blank?
        errors << "takes a key or a key_env, not both" if config["key"].present? && config["key_env"].present?
        # A key_env comes back out in every response, so a key put there by
        # mistake would be published. The value is not echoed in the error.
        if config["key_env"].present? && !config["key_env"].to_s.match?(ENV_NAME)
          errors << "key_env names an environment variable (like TALLY_KEY); the key itself goes in key"
        end
        errors
      end

      def list(filters)
        get("/v1/tasks", task_query(filters)).fetch("tasks", []).map { |task| todo(task) }
      end

      def find(id)
        todo(get("/v1/tasks/#{escape(id)}"))
      end

      # Nothing is addressed on a create, so whatever tally could not find
      # (a project, a tag, a parent) was named in the body: the caller's mistake.
      def create(attributes)
        todo(post("/v1/tasks", task_body(attributes, creating: true)))
      rescue Todos::NotFound => e
        raise Todos::Invalid, e.message
      end

      def update(id, attributes)
        todo(patch("/v1/tasks/#{escape(id)}", task_body(attributes, creating: false)))
      end

      # A repeating todo completes this occurrence only; when OmniFocus made
      # the next one it rides along as `next`.
      def complete(id)
        data = post("/v1/tasks/#{escape(id)}/complete", {})
        task = data["task"].is_a?(Hash) ? data["task"] : data
        following = data["next"] || task["next"]
        todo(task).tap { |done| done["next"] = todo(following) if following.is_a?(Hash) }
      end

      def reopen(id)
        todo(post("/v1/tasks/#{escape(id)}/reopen", {}))
      end

      def drop(id)
        todo(post("/v1/tasks/#{escape(id)}/drop", {}))
      end

      def destroy(id)
        delete("/v1/tasks/#{escape(id)}")
        true
      end

      # Projects, with the inbox in front. A scoped key has no inbox (tally's
      # status names the scope, or refuses), so none is invented for it.
      def lists(filters)
        query = { "status" => filters["status"], "q" => filters["q"], "fields" => PROJECT_FIELDS, "limit" => 2000 }.compact
        data = get("/v1/projects", query)
        projects = Array(data["projects"] || data["data"]).map { |project| project_list(project) }
        [ inbox(filters), *projects ].compact
      end

      # GET /v1/status: tally answers, OmniFocus answers tally, the key is good.
      def check
        status = get("/v1/status")
        { "reachable" => true, "omnifocus" => status["omnifocus"], "counts" => status["counts"],
          "last_sync" => status["last_sync"], "tally_key" => status["key"], "now" => status["now"] }.compact
      end

      private

      # --- hob → tally ---

      def task_query(filters)
        query = { "status" => tally_status(filters), "limit" => filters["limit"] }
        if filters["list"].present?
          kind, native = list_reference(filters["list"])
          raise Todos::Invalid, "list must be a list id like #{inbox_id}, got #{filters['list'].inspect}" if kind == :name

          kind == :inbox ? query["inbox"] = true : query["project"] = native
        end
        if filters["tag"].present?
          query["tag"] = filters["tag"]
          query["tag_mode"] = "all" if filters["tag"].size > 1
        end
        query["flagged"] = filters["flagged"] unless filters["flagged"].nil?
        { "due_before" => "due_before", "due_after" => "due_after", "start_before" => "defer_before",
          "updated_after" => "modified_after", "q" => "q" }.each { |ours, theirs| query[theirs] = filters[ours] if filters[ours].present? }
        if filters["sort"].present?
          descending = filters["sort"].start_with?("-")
          query["sort"] = "#{'-' if descending}#{TASK_SORT.fetch(filters['sort'].delete_prefix('-'))}"
        end
        query.compact
      end

      # actionable: true is tally's `available` (available, next, due_soon,
      # overdue); false is what is left of the open ones, its `blocked`.
      def tally_status(filters)
        return TASK_STATUS.fetch(filters["status"] || "open") if filters["actionable"].nil?

        filters["actionable"] ? "available" : "blocked"
      end

      def task_body(attributes, creating:)
        body = attributes.slice(*FIELDS.keys).transform_keys { |name| FIELDS.fetch(name) }
        body["create_tags"] = true if backend.config["create_tags"] && (body.key?("tags") || body.key?("add_tags"))
        raise Todos::Invalid, "give a list or a parent_id, not both" if attributes["list"].present? && attributes["parent_id"].present?

        body["parent"] = native_id!(attributes["parent_id"], "parent_id") if attributes["parent_id"].present?
        place(body, attributes["list"], creating: creating) if attributes.key?("list") && body["parent"].nil?
        body
      end

      # Where it goes: a project by id or by name, or the inbox (a null list),
      # which on a create is tally's default and on an update has to be said.
      def place(body, list, creating:)
        kind, value = list.nil? ? [ :inbox ] : list_reference(list)
        if kind == :inbox
          body["inbox"] = true unless creating
        else
          body["project"] = value
        end
      end

      # --- tally → hob ---

      def todo(task)
        status = task_status(task)
        actionable = status == "open" && ACTIONABLE.include?(task["status"])
        {
          "id" => todo_id(task["id"]), "backend" => backend.name, "title" => task["name"], "notes" => task["note"].to_s,
          "status" => status, "actionable" => actionable, "blocked" => status == "open" && !actionable,
          "flagged" => task.fetch("effective_flagged") { task["flagged"] } ? true : false,
          "due_at" => iso(task["effective_due"] || task["due"]),
          "start_at" => iso(task["effective_defer"] || task["defer"]),
          "planned_at" => iso(task["effective_planned"] || task["planned"]),
          "completed_at" => iso(task["completed_at"]),
          "tags" => Array(task["tags"]).filter_map { |tag| tag.is_a?(Hash) ? tag["name"] : tag.presence },
          "list" => task["project"].is_a?(Hash) ? { "id" => list_id(task["project"]["id"]), "name" => task["project"]["name"] } : nil,
          "parent_id" => task["parent"].is_a?(Hash) ? todo_id(task["parent"]["id"]) : nil,
          "has_children" => task["has_children"] ? true : false,
          "estimate_minutes" => task["estimated_minutes"], "repeats" => task["repetition"].present?,
          "url" => task["url"], "created_at" => iso(task["added"]), "updated_at" => iso(task["modified"])
        }
      end

      def task_status(task)
        return "done" if task["completed"] || task["status"] == "completed"
        return "dropped" if task["dropped"] || task["status"] == "dropped"

        "open"
      end

      def project_list(project)
        { "id" => list_id(project["id"]), "backend" => backend.name, "name" => project["name"], "kind" => "project",
          "path" => project["folder"].is_a?(Hash) ? project["folder"]["path"] : nil, "status" => project["status"],
          "open_count" => project["remaining_count"] }
      end

      def inbox(filters)
        return nil unless %w[active all].include?(filters["status"])
        return nil if filters["q"].present? && !"inbox".include?(filters["q"].downcase)

        status = get("/v1/status")
        return nil if status.dig("key", "scope").present?

        inbox_list(open_count: status.dig("counts", "inbox"))
      rescue Todos::Forbidden, Todos::NotFound
        nil
      end

      # --- the wire ---

      def get(path, query = nil)
        path = "#{path}?#{URI.encode_www_form(query)}" if query.present?
        request("GET", path)
      end

      def post(path, body)
        request("POST", path, body)
      end

      def patch(path, body)
        request("PATCH", path, body)
      end

      def delete(path)
        request("DELETE", path)
      end

      def request(verb, path, body = nil)
        key = backend.key
        raise Todos::Unavailable, "#{backend.name} has no key: #{key_hint}" if key.blank?

        headers = { "Authorization" => "Bearer #{key}", "Accept" => "application/json" }
        headers["Content-Type"] = "application/json" if body
        status, response = deliver(verb, "#{backend.url}#{path}", body && JSON.generate(body), headers)
        data = parse(response)
        return data if status.to_s.start_with?("2")

        raise error_for(status.to_i, data)
      end

      def key_hint
        backend.config["key_env"].present? ? "#{backend.config['key_env']} is not set in hob's environment" : "set config.key or config.key_env"
      end

      # Whatever goes wrong on the way there is the same answer: not now.
      def deliver(verb, url, body, headers)
        (self.class.transport || method(:http)).call(verb, url, body, headers)
      rescue SocketError, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
        raise Todos::Unavailable, "tally unreachable at #{URI(backend.url).host}: #{e.class.name.demodulize}: #{e.message}"
      end

      def http(verb, url, body, headers)
        uri = URI(url)
        req = Net::HTTP.const_get(verb.capitalize).new(uri)
        headers.each { |name, value| req[name] = value }
        req.body = body if body
        response = connection(uri).start { |session| session.request(req) }
        [ response.code, response.body ]
      end

      # `addr` pins the address to connect to; the hostname still goes out as
      # Host and SNI, so a certificate is checked against the name (Hob::HTTP
      # does the same with ipaddr:). Net::HTTP would quietly send a GET a
      # second time after a read timeout, and a hung Mac would then hold the
      # request for a minute, past the proxy's patience: no retries.
      def connection(uri)
        Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.ipaddr = backend.addr if backend.addr
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = OPEN_TIMEOUT
          http.read_timeout = READ_TIMEOUT
          http.max_retries = 0
        end
      end

      def parse(body)
        return {} if body.blank?

        data = JSON.parse(body)
        data.is_a?(Hash) ? data : { "data" => data }
      rescue JSON::ParserError
        { "error" => { "message" => body.to_s.truncate(200) } }
      end

      # tally's { error: { code, message, candidates? } } as one of ours.
      def error_for(status, data)
        error = data["error"].is_a?(Hash) ? data["error"] : { "message" => data["error"] }
        detail = error["message"].presence || error["code"].presence
        detail = "#{detail} (candidates: #{candidates(error['candidates'])})" if detail && error["candidates"].present?
        case status
        when 404 then missing(error["kind"]).new(detail || "tally found nothing there")
        when 400, 409, 422 then Todos::Invalid.new(detail || "tally refused the request (HTTP #{status})")
        when 401, 403 then Todos::Forbidden.new("tally refused #{backend.name}'s key: #{detail || "HTTP #{status}"}")
        when 503 then Todos::Unavailable.new(detail || "tally cannot reach OmniFocus")
        when 500..599 then Todos::Unavailable.new("tally failed with HTTP #{status}#{detail && ": #{detail}"}")
        else Todos::Error.new("tally answered HTTP #{status}#{detail && ": #{detail}"}")
        end
      end

      # tally says what kind of thing it could not find. A missing task is
      # the todo that was asked for; a missing tag or project was named in
      # the request, which makes the request the thing that is wrong.
      def missing(kind)
        kind.blank? || kind == "task" ? Todos::NotFound : Todos::Invalid
      end

      def candidates(list)
        Array(list).map { |c| c.is_a?(Hash) ? [ c["path"] || c["name"], c["id"] ].compact.join(" ") : c.to_s }.join("; ")
      end

      def escape(id)
        ERB::Util.url_encode(id.to_s)
      end
    end
  end
end
