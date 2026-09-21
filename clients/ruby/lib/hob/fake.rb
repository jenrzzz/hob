module Hob
  # A scripted stand-in for Hob::Client. Queue replies; each complete/chat
  # consumes one and records what it was asked. Conversations live in memory
  # so a test can read the transcript back.
  #
  #   Llm.client = Hob::Fake.new.reply('{"title": "Soup"}')
  #   Llm.client.calls.last.args[:schema]
  class Fake
    Call = Struct.new(:kind, :args, keyword_init: true)

    attr_reader :calls, :store

    def initialize
      @queue = []
      @calls = []
      @store = {}
      @counter = 0
    end

    def reply(content, parsed: nil, tool_calls: [], usage: {}, model: "fake-model")
      parsed = (JSON.parse(content) rescue nil) if parsed.nil? && content.is_a?(String)
      @queue << { "status" => tool_calls.empty? ? "success" : "tool_calls", "content" => content, "parsed" => parsed,
                  "tool_calls" => tool_calls, "model" => model, "provider" => "fake", "stop_reason" => tool_calls.empty? ? "end_turn" : "tool_use",
                  "usage" => { "input_tokens" => 10, "output_tokens" => 5, "cache_read_tokens" => 0, "cost" => 0.0 }.merge(usage.transform_keys(&:to_s)) }
      self
    end

    def refuse
      @queue << { "status" => "refused", "error" => "the model declined", "usage" => { "input_tokens" => 10, "output_tokens" => 0 } }
      self
    end

    def call_tool(name, arguments = {}, id: nil, content: "")
      reply(content, tool_calls: [ { "id" => id || next_id("call"), "name" => name.to_s, "arguments" => stringify(arguments) } ])
    end

    def fail(error)
      @queue << error
      self
    end

    def complete(**args, &on_event)
      @calls << Call.new(kind: :complete, args: args)
      convo = args[:id] ? @store.fetch(args[:id]) { raise NotFound, "no completion #{args[:id]}" } : new_conversation("pipeline", args[:operation])
      append_input(convo, args[:messages]) unless args[:id]
      Array(args[:tool_results]).each { |r| convo[:messages] << { "role" => "user", "kind" => "tool_result", "content" => r[:content] || r["content"] } }

      data = take(&on_event).merge("id" => convo[:id], "snapshot" => next_id("snap"))
      finish(convo, data, on_event)
      completion = Completion.new(data)
      raise Refused.new(data["error"], completion: completion) if completion.refused?

      completion
    end

    def completion(id)
      convo = @store.fetch(id) { raise NotFound, "no completion #{id}" }
      Completion.new(convo[:last] || { "id" => id, "status" => "refused" })
    end

    def chat(conversation:, **args, &on_event)
      id = conversation.respond_to?(:id) ? conversation.id : conversation
      @calls << Call.new(kind: :chat, args: args.merge(conversation: id))
      convo = @store.fetch(id) { raise NotFound, "no conversation #{id}" }
      user = args[:content] && { "role" => "user", "content" => args[:content], "hash" => next_id("node") }
      convo[:messages] << user if user
      Array(args[:tool_results]).each { |r| convo[:messages] << { "role" => "user", "kind" => "tool_result", "content" => r[:content] || r["content"] } }

      data = take(&on_event)
      raise Refused.new(data["error"]) if data["status"] == "refused"

      assistant = finish(convo, data, on_event)
      Turn.new("status" => data["status"], "user" => user, "assistant" => assistant, "assistants" => [ assistant ].compact,
               "tool_calls" => data["tool_calls"], "snapshot" => next_id("snap"))
    end

    def conversations
      @conversations ||= FakeConversations.new(self)
    end

    def usage(**)
      UsageSummary.new("calls" => @calls.size, "cost" => 0.0, "input_tokens" => 0, "output_tokens" => 0, "by_role" => {}, "by_operation" => {}, "recent" => [])
    end

    # Scripted sentinel: fake.sentinel.allow(result) / deny(reason) / hold(result)
    # decide what the next request meets; requests are recorded in `calls`.
    def sentinel
      @sentinel ||= FakeSentinel.new(self)
    end

    # An in-memory mission queue with the real client's surface.
    def missions
      @missions ||= FakeMissions.new(self)
    end

    # In-memory todos with the real client's surface, in one backend named
    # "fake": fake.todos.create(title: "Buy milk"), then read them back.
    def todos
      @todos ||= FakeTodos.new(self)
    end

    class FakeSentinel
      attr_reader :requests

      def initialize(fake)
        @fake = fake
        @queue = []
        @requests = {}
        @capabilities = []
        @petition_queue = []
        @petitions = {}
      end

      # Script the next petition's outcome: granted (and offered from then
      # on), held for a person, building, or denied.
      def grant(capability, effect: "review")
        @petition_queue << { "status" => "granted", "action" => "grant", "decided_by" => "steward", "capability" => capability, "effect" => effect }
        self
      end

      def hold_petition(rationale = "a person will look")
        @petition_queue << { "status" => "pending", "action" => "refer", "decided_by" => "steward", "rationale" => rationale }
        self
      end

      def build(capability, effect: "review")
        @petition_queue << { "status" => "building", "action" => "build", "decided_by" => "steward", "capability" => capability, "effect" => effect,
                             "mission" => "fake-mission" }
        self
      end

      def deny_petition(rationale = "denied")
        @petition_queue << { "status" => "denied", "action" => "deny", "decided_by" => "steward", "rationale" => rationale }
        self
      end

      def allow(result = {})
        @queue << { "status" => "completed", "decision" => "allow", "decided_by" => "policy", "result" => result }
        self
      end

      def deny(reason = "denied")
        @queue << { "status" => "denied", "decision" => "deny", "decided_by" => "policy", "rationale" => reason }
        self
      end

      # Pending until `decide` (a person) settles it; allow completes with `result`.
      def hold(result = {})
        @queue << { "status" => "pending", "decision" => "escalate", "decided_by" => "policy", "rationale" => "a person must confirm",
                    "held_result" => result }
        self
      end

      # What `capabilities` lists.
      def offer(name, effect: "allow", description: name, kind: "act", realm: "household", input_schema: {})
        @capabilities << Capability.new("name" => name, "effect" => effect, "description" => description, "kind" => kind,
                                        "realm" => realm, "venue" => "native", "enabled" => true, "input_schema" => input_schema)
        self
      end

      def request(capability:, arguments: {}, reason: nil, mission: nil)
        @fake.calls << Call.new(kind: :sentinel, args: { capability: capability, arguments: arguments, reason: reason, mission: mission })
        raise Error, "Hob::Fake: no scripted sentinel decision left" if @queue.empty?

        item = @queue.shift
        raise item if item.is_a?(Exception)

        data = item.merge("id" => @fake.send(:next_id, "req"), "agent" => "fake-agent", "capability" => capability,
                          "arguments" => @fake.send(:stringify, arguments), "reason" => reason, "on_mission" => mission)
        @requests[data["id"]] = data
        SentinelRequest.new(data.reject { |k, _| k == "held_result" })
      end

      def fail(error)
        @queue << error
        self
      end

      def show(id, wait: nil)
        SentinelRequest.new(@requests.fetch(id) { raise NotFound, "no request #{id}" }.reject { |k, _| k == "held_result" })
      end

      def wait(request, timeout: nil)
        show(request.respond_to?(:id) ? request.id : request)
      end

      def list(status: nil, agent: nil)
        @requests.values.select { |r| status.nil? || r["status"] == status }.map { |r| SentinelRequest.new(r.reject { |k, _| k == "held_result" }) }
      end

      def decide(id, decision:, rationale: nil)
        data = @requests.fetch(id) { raise NotFound, "no request #{id}" }
        raise Invalid, "request #{id} is #{data['status']}, not pending" unless data["status"] == "pending"

        data.merge!("decided_by" => "human", "decision" => decision.to_s, "rationale" => rationale)
        data.merge!(decision.to_s == "allow" ? { "status" => "completed", "result" => data["held_result"] } : { "status" => "denied" })
        show(id)
      end

      def capabilities
        @capabilities.dup
      end

      def capability(name)
        @capabilities.find { |c| c.name == name } || raise(NotFound, "no capability #{name}")
      end

      def petition(want:, capability: nil, arguments: nil, reason: nil, mission: nil)
        @fake.calls << Call.new(kind: :petition, args: { want: want, capability: capability, arguments: arguments, reason: reason, mission: mission })
        raise Error, "Hob::Fake: no scripted petition outcome left" if @petition_queue.empty?

        item = @petition_queue.shift
        raise item if item.is_a?(Exception)

        data = item.merge("id" => @fake.send(:next_id, "pet"), "agent" => "fake-agent", "want" => want, "reason" => reason,
                          "arguments" => arguments && @fake.send(:stringify, arguments), "on_mission" => mission)
        data["capability"] ||= capability
        @petitions[data["id"]] = data
        offer(data["capability"], effect: data["effect"]) if data["status"] == "granted" && data["capability"]
        Petition.new(data)
      end

      def show_petition(id, wait: nil)
        Petition.new(@petitions.fetch(id) { raise NotFound, "no petition #{id}" })
      end

      def wait_petition(petition, timeout: nil)
        show_petition(petition.respond_to?(:id) ? petition.id : petition)
      end

      def petitions(status: nil, agent: nil)
        @petitions.values.select { |p| status.nil? || p["status"] == status }.map { |p| Petition.new(p) }
      end

      def decide_petition(id, decision:, capability: nil, effect: nil, constraints: nil, limits: nil, guidance: nil, spec: nil, rationale: nil)
        data = @petitions.fetch(id) { raise NotFound, "no petition #{id}" }
        raise Invalid, "petition #{id} is #{data['status']}, not pending or failed" unless %w[pending failed].include?(data["status"])

        data.merge!("decided_by" => "human", "action" => decision.to_s, "rationale" => rationale)
        case decision.to_s
        when "grant"
          data.merge!("status" => "granted", "capability" => capability || data["capability"], "effect" => effect || data["effect"] || "review")
          offer(data["capability"], effect: data["effect"]) if data["capability"]
        when "build" then data.merge!("status" => "building", "mission" => "fake-mission")
        else data["status"] = "denied"
        end
        show_petition(id)
      end
    end

    class FakeMissions < Missions
      def initialize(fake)
        super(nil)
        @fake = fake
        @store = {}
      end

      def create(assignee:, title:, brief: nil, payload: nil, priority: nil, realm: nil)
        data = { "id" => @fake.send(:next_id, "mission"), "assignee" => assignee, "created_by" => "fake", "title" => title,
                 "brief" => brief, "payload" => @fake.send(:stringify, payload || {}), "priority" => priority.to_i,
                 "realm" => realm || "household", "status" => "queued", "attempts" => 0 }
        @store[data["id"]] = data
        Mission.new(data)
      end

      def list(status: nil, assignee: nil)
        @store.values.select { |m| (status.nil? || m["status"] == status) && (assignee.nil? || m["assignee"] == assignee) }.map { |m| Mission.new(m) }
      end

      def show(id, wait: nil)
        Mission.new(fetch(id))
      end

      def lease(wait: nil, lease: nil)
        data = @store.values.select { |m| m["status"] == "queued" }.min_by { |m| [ -m["priority"], m["id"] ] }
        return nil if data.nil?

        data.merge!("status" => "leased", "attempts" => data["attempts"] + 1, "lease_token" => @fake.send(:next_id, "lease"))
        Mission.new(data)
      end

      def heartbeat(mission, lease: nil)
        Mission.new(held(mission))
      end

      def complete(mission, result)
        Mission.new(held(mission).merge!("status" => "completed", "result" => @fake.send(:stringify, result), "lease_token" => nil))
      end

      def fail(mission, error)
        Mission.new(held(mission).merge!("status" => "failed", "error" => error.to_s, "lease_token" => nil))
      end

      def cancel(id)
        Mission.new(fetch(id).merge!("status" => "cancelled", "lease_token" => nil))
      end

      private

      def fetch(id)
        @store.fetch(id) { raise NotFound, "no mission #{id}" }
      end

      def held(mission)
        data = fetch(mission.id)
        raise Invalid, "mission #{mission.id} is #{data['status']}" unless data["status"] == "leased"
        raise Invalid, "lease_token does not hold mission #{mission.id}" unless data["lease_token"] == mission.lease_token

        data
      end
    end

    class FakeTodos < Todos
      BACKEND = "fake".freeze
      CREATE = %i[title notes flagged due_at start_at planned_at estimate_minutes tags list parent_id backend].freeze
      UPDATE = (CREATE - %i[backend] + %i[notes_append add_tags remove_tags]).freeze
      FILTERS = %i[backend status actionable list tag flagged due_before due_after start_before q updated_after sort limit].freeze
      SORTS = { "due" => "due_at", "start" => "start_at", "created" => "created_at", "updated" => "updated_at", "title" => "title" }.freeze

      def initialize(fake)
        super(nil)
        @fake = fake
        @store = {}
        @lists = {}
      end

      # A project to file todos in; returns its list id.
      def add_list(name, path: nil)
        id = "#{BACKEND}:#{@fake.send(:next_id, 'list')}"
        @lists[id] = { "id" => id, "backend" => BACKEND, "name" => name, "kind" => "project", "path" => path, "status" => "active" }
        id
      end

      def list(**filters)
        known!(filters, FILTERS, "filter")
        status = (filters[:status] || "open").to_s
        found = @store.values.select do |t|
          (status == "all" || t["status"] == status) &&
            (filters[:backend].nil? || filters[:backend].to_s == BACKEND) &&
            (filters[:actionable].nil? || t["actionable"] == filters[:actionable]) &&
            (filters[:flagged].nil? || t["flagged"] == filters[:flagged]) &&
            (filters[:list].nil? || (t["list"] ? t["list"]["id"] : "#{BACKEND}:inbox") == filters[:list]) &&
            Array(filters[:tag]).all? { |tag| t["tags"].include?(tag) } &&
            (filters[:due_before].nil? || (t["due_at"] && t["due_at"] < stamp(filters[:due_before]))) &&
            (filters[:due_after].nil? || (t["due_at"] && t["due_at"] > stamp(filters[:due_after]))) &&
            (filters[:start_before].nil? || (t["start_at"] && t["start_at"] < stamp(filters[:start_before]))) &&
            (filters[:updated_after].nil? || t["updated_at"] > stamp(filters[:updated_after])) &&
            filters[:q].to_s.downcase.split.all? { |word| "#{t['title']} #{t['notes']}".downcase.include?(word) }
        end
        TodoListing.new(sorted(found, filters[:sort]).first(filters[:limit] || 100).map { |t| Todo.new(t) }, [])
      end

      def find(id)
        Todo.new(fetch(id))
      end

      def create(**attributes)
        known!(attributes, CREATE, "attribute")
        raise Invalid, "title is required" if attributes[:title].to_s.strip.empty?
        raise NotFound, "no todo backend named #{attributes[:backend].inspect}" unless [ nil, BACKEND ].include?(attributes[:backend]&.to_s)

        now = stamp(Time.now)
        id = "#{BACKEND}:#{@fake.send(:next_id, 'todo')}"
        data = { "id" => id, "backend" => BACKEND, "title" => nil, "notes" => "", "status" => "open", "actionable" => true,
                 "blocked" => false, "flagged" => false, "due_at" => nil, "start_at" => nil, "planned_at" => nil,
                 "completed_at" => nil, "tags" => [], "list" => nil, "parent_id" => nil, "has_children" => false,
                 "estimate_minutes" => nil, "repeats" => false, "url" => "fake:///task/#{id}", "created_at" => now, "updated_at" => now }
        @store[id] = assign(data, attributes)
        Todo.new(data)
      end

      def update(id, **attributes)
        known!(attributes, UPDATE, "attribute")
        raise Invalid, "nothing to update" if attributes.empty?

        Todo.new(assign(fetch(id), attributes).merge!("updated_at" => stamp(Time.now)))
      end

      def complete(id)
        Todo.new(fetch(id).merge!("status" => "done", "actionable" => false, "completed_at" => stamp(Time.now)))
      end

      def reopen(id)
        Todo.new(fetch(id).merge!("status" => "open", "actionable" => true, "completed_at" => nil))
      end

      def drop(id)
        Todo.new(fetch(id).merge!("status" => "dropped", "actionable" => false))
      end

      def delete(id)
        fetch(id)
        @store.delete_if { |key, t| key == key_of(id) || t["parent_id"] == key_of(id) }
        true
      end

      def lists(**filters)
        known!(filters, %i[backend status q], "filter")
        inbox = { "id" => "#{BACKEND}:inbox", "backend" => BACKEND, "name" => "Inbox", "kind" => "inbox", "path" => nil, "status" => "active" }
        all = [ inbox, *@lists.values ].select { |l| l["name"].downcase.include?(filters[:q].to_s.downcase) }
        TodoListing.new(all.map { |l| TodoList.new(l.merge("open_count" => open_in(l))) }, [])
      end

      def backends
        [ TodoBackend.new("name" => BACKEND, "kind" => "fake", "owner" => "fake", "realm" => "household", "enabled" => true,
                          "primary" => true, "config" => {}) ]
      end

      private

      def key_of(id)
        (id.respond_to?(:id) ? id.id : id).to_s
      end

      def fetch(id)
        @store.fetch(key_of(id)) { raise NotFound, "no todo #{key_of(id)}" }
      end

      # The server refuses what it does not know, so the fake does too.
      def known!(given, allowed, what)
        unknown = given.keys.map(&:to_sym) - allowed
        raise Invalid, "unknown #{what} #{unknown.join(', ')} (known: #{allowed.join(', ')})" unless unknown.empty?
      end

      def assign(data, attributes)
        attributes = attributes.transform_keys(&:to_s)
        data.merge!(attributes.slice("title", "flagged", "estimate_minutes"))
        data["notes"] = attributes["notes"].to_s if attributes.key?("notes")
        data["notes"] = [ data["notes"], attributes["notes_append"] ].reject { |n| n.to_s.empty? }.join("\n") if attributes["notes_append"]
        %w[due_at start_at planned_at].each { |name| data[name] = stamp(attributes[name]) if attributes.key?(name) }
        data["tags"] = Array(attributes["tags"]).map(&:to_s) if attributes.key?("tags")
        data["tags"] = (data["tags"] | Array(attributes["add_tags"])) - Array(attributes["remove_tags"])
        if attributes["parent_id"]
          parent = fetch(attributes["parent_id"])
          parent["has_children"] = true
          data.merge!("parent_id" => parent["id"], "list" => parent["list"])
        elsif attributes.key?("list")
          data.merge!("parent_id" => nil, "list" => list_for(attributes["list"]))
        end
        data
      end

      # nil or "fake:inbox" is the inbox; otherwise a list id or a name from add_list.
      def list_for(value)
        return nil if value.nil? || value == "#{BACKEND}:inbox"

        found = @lists[value] || @lists.values.find { |l| l["name"] == value }
        raise NotFound, "no list #{value.inspect}" if found.nil?

        found.slice("id", "name")
      end

      def open_in(list)
        @store.values.count { |t| t["status"] == "open" && (list["kind"] == "inbox" ? t["list"].nil? : t.dig("list", "id") == list["id"]) }
      end

      def sorted(todos, sort)
        return todos if sort.nil?

        key = SORTS.fetch(sort.to_s.delete_prefix("-")) { raise Invalid, "sort must be one of #{SORTS.keys.join(', ')}" }
        present, absent = todos.partition { |t| t[key] }
        present = present.sort_by { |t| t[key].to_s.downcase }
        present.reverse! if sort.to_s.start_with?("-")
        present + absent
      end

      # UTC ISO8601 from a Time, a Date, or a string.
      def stamp(value)
        return nil if value.nil?

        value = value.to_time if value.respond_to?(:to_time) && !value.is_a?(String)
        value = Time.parse(value) if value.is_a?(String)
        value.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      end
    end

    # In-memory conversations with the same surface as Hob::Conversations.
    class FakeConversations
      def initialize(fake)
        @fake = fake
      end

      def create(title: nil, realm: nil)
        Conversation.new(@fake.send(:new_conversation, "chat", title, realm).slice(:id, :kind, :title, :realm).transform_keys(&:to_s).merge("branches" => [ "main" ]))
      end

      def list(kind: nil)
        @fake.store.values.select { |c| kind.nil? || kind == "all" || c[:kind] == (kind || "chat") }.map { |c| show(c[:id]) }
      end

      def show(id, branch: nil)
        c = @fake.store.fetch(id) { raise NotFound, "no conversation #{id}" }
        Conversation.new("id" => c[:id], "kind" => c[:kind], "title" => c[:title], "realm" => c[:realm], "branches" => [ "main" ],
                         "branch" => branch || "main", "messages" => c[:messages])
      end

      def branches(id)
        [ { "name" => "main", "head" => show(id).messages.last&.dig("hash") } ]
      end

      def fork(id, name:, at:)
        show(id)
        { "name" => name, "head" => at }
      end

      def set_head(id, head:, branch: "main")
        show(id)
        { "name" => branch, "head" => head }
      end

      def siblings(id, hash)
        show(id).messages.select { |m| m["hash"] == hash }
      end

      def event(id, content:, branch: nil, meta: nil)
        node = { "role" => "event", "kind" => "event", "content" => content, "meta" => meta || {}, "hash" => @fake.send(:next_id, "node") }
        @fake.store.fetch(id)[:messages] << node
        node
      end
    end

    private

    def take
      raise Error, "Hob::Fake: no scripted reply left" if @queue.empty?

      item = @queue.shift
      raise item if item.is_a?(Exception)

      if block_given?
        item["content"].to_s.scan(/.{1,7}/m).each { |piece| yield Event.new("type" => "delta", "content" => piece) }
      end
      item.dup
    end

    # Records the reply in the transcript, replays the trailing stream
    # events, and returns the assistant text node (nil when there was none).
    def finish(convo, data, on_event)
      convo[:last] = data
      assistant = data["content"].to_s.empty? ? nil : { "role" => "assistant", "content" => data["content"], "hash" => next_id("node"), "meta" => data["usage"] }
      convo[:messages] << assistant if assistant
      data["tool_calls"].to_a.each { |tc| convo[:messages] << { "role" => "assistant", "kind" => "tool_call", "content" => JSON.generate(tc), "hash" => next_id("node") } }
      if on_event
        data["tool_calls"].to_a.each { |tc| on_event.call(Event.new(tc.merge("type" => "tool_call"))) }
        on_event.call(Event.new(data["usage"].to_h.merge("type" => "usage")))
        on_event.call(Event.new(data.merge("type" => "done")))
      end
      assistant
    end

    def new_conversation(kind, title = nil, realm = nil)
      convo = { id: next_id("conv"), kind: kind, title: title, realm: realm, messages: [], last: nil }
      @store[convo[:id]] = convo
      convo
    end

    def append_input(convo, messages)
      Array(messages).each do |m|
        m = stringify(m)
        next if m["role"] == "system"

        convo[:messages] << m.merge("hash" => next_id("node"))
      end
    end

    def stringify(value)
      case value
      when Hash then value.to_h { |k, v| [ k.to_s, stringify(v) ] }
      when Array then value.map { |v| stringify(v) }
      else value
      end
    end

    def next_id(prefix)
      @counter += 1
      format("%s_%04d", prefix, @counter)
    end
  end
end
