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
