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

    class FakeSentinel
      attr_reader :requests

      def initialize(fake)
        @fake = fake
        @queue = []
        @requests = {}
        @capabilities = []
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
