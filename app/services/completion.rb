# A one-shot completion, persisted as a single-branch `pipeline` conversation
# (B1): the request messages become nodes, the prompt is snapshotted, the
# reply is a node with the ledger's ref pointing back here. Everything a
# surface extracts from the reply can cite the reply node's hash.
#
# With `tools` the completion may pause at the model's tool calls (C); the
# caller executes them and resumes the same conversation with `tool_results`
# (Completion.resume). The request's configuration rides in the snapshot so a
# resume needs nothing but the id.
class Completion
  Result = Struct.new(:conversation, :response, :assistant_node, :tool_call_nodes, :snapshot, keyword_init: true) do
    def status
      response.status
    end

    def refused?
      response.refused?
    end

    def tool_calls?
      response.tool_calls?
    end

    def tool_calls
      tool_call_nodes.map(&:tool_call)
    end
  end

  CONFIG_KEYS = %w[role operation persona schema tools tool_choice max_iterations params metadata ref system].freeze

  # messages: [{ role: user|assistant|system, content: }] — system-role
  # messages fold into `system`; `persona` supplies it when given instead.
  def initialize(role:, messages:, system: nil, persona: nil, schema: nil, tools: nil, tool_choice: nil,
                 max_iterations: nil, params: {}, operation: nil, metadata: {}, ref: nil, realm:)
    @role = role
    @messages = Array(messages).map { |m| m.to_h.deep_stringify_keys }
    system_messages, @messages = @messages.partition { |m| m["role"].to_s == "system" }
    @system = [ persona&.system_core, system, *system_messages.map { |m| m["content"] } ].compact_blank.join("\n\n")
    @persona = persona
    @schema = schema
    @tools = Array(tools).presence
    @tool_choice = tool_choice.presence
    @max_iterations = (max_iterations || ToolExchange::DEFAULT_MAX_ITERATIONS).to_i
    @params = params || {}
    @operation = operation
    @metadata = metadata || {}
    @ref = ref
    @realm = realm
  end

  def call(&on_event)
    conversation = Conversation.create!(
      kind: "pipeline", surface: Current.surface, realm: @realm, taint_realm: @realm,
      title: @operation.presence
    )
    branch = conversation.branch
    append_input(conversation, branch)
    run(conversation, branch, &on_event)
  end

  # Continue a paused completion with the caller's tool results.
  def self.resume(conversation, tool_results:, &on_event)
    raise Gateway::Invalid, "not a completion" unless conversation.pipeline?

    branch = conversation.branch
    config = latest_snapshot(conversation)&.assembled&.slice(*CONFIG_KEYS) || {}
    raise Gateway::Invalid, "completion #{conversation.id} has no stored request to resume" if config["role"].blank?

    nodes = ToolExchange.append_results!(conversation: conversation, head: branch.head, results: tool_results)
    branch.advance!(nodes.last)

    completion = new(
      role: config["role"], messages: [], system: config["system"],
      persona: config["persona"].presence && Persona.find_by(key: config["persona"]),
      schema: config["schema"], tools: config["tools"], tool_choice: config["tool_choice"],
      max_iterations: config["max_iterations"], params: config["params"], operation: config["operation"],
      metadata: config["metadata"], ref: config["ref"], realm: conversation.realm
    )
    completion.send(:run, conversation, branch, &on_event)
  end

  # Reads a stored pipeline conversation back into the completion shape.
  def self.find(id)
    conversation = Conversation.pipelines.find(id)
    timeline = conversation.branch.timeline
    head = timeline.last
    reply = head if head&.role == "assistant" && head.kind == "text"
    pending = ToolExchange.pending_calls(head)
    snapshot = (reply && PromptSnapshot.find_by(digest: reply.prompt_snapshot_hash)) || latest_snapshot(conversation)
    parsed = reply && snapshot&.assembled&.dig("schema") ? (Gateway::Structured.parse(reply.content) rescue nil) : nil
    status = if reply then "success"
    elsif pending.any? then "tool_calls"
    else "refused"
    end
    { conversation: conversation, reply: reply, snapshot: snapshot, parsed: parsed, status: status,
      tool_calls: pending, timeline: timeline }
  end

  def self.latest_snapshot(conversation)
    conversation.prompt_snapshots.order(created_at: :desc).first
  end

  private

  # One model call at the branch head; the transcript is whatever the branch
  # holds (input messages, and on a resume the calls and results too).
  def run(conversation, branch, &on_event)
    messages = Assembly::Transcript.render(branch.timeline)
    snapshot = PromptSnapshot.record!(
      conversation: conversation,
      assembled: {
        "role" => @role, "operation" => @operation, "persona" => @persona&.key, "schema" => @schema,
        "tools" => @tools, "tool_choice" => @tool_choice, "max_iterations" => @max_iterations,
        "params" => @params, "metadata" => @metadata, "ref" => @ref,
        "system" => @system, "messages" => messages
      }
    )

    tool_choice = @tools && ToolExchange.rounds(branch.head) >= @max_iterations ? "none" : @tool_choice
    response = Gateway.complete(
      role: @role, system: @system, messages: messages, schema: @schema, tools: @tools, tool_choice: tool_choice,
      params: @params, operation: @operation, ref: @ref.presence || "conversation/#{conversation.id}",
      metadata: @metadata.merge("conversation" => conversation.id), snapshot: snapshot.digest, &on_event
    )

    assistant_node = nil
    tool_call_nodes = []
    if response.tool_calls?
      if response.content.strip.present?
        assistant_node = append_reply(conversation, branch, response, snapshot, final: false)
      end
      tool_call_nodes = ToolExchange.append_calls!(
        conversation: conversation, parent_hash: branch.head_hash, calls: response.tool_calls,
        meta: response.meta, snapshot_digest: snapshot.digest
      )
      branch.advance!(tool_call_nodes.last)
    elsif !response.refused?
      assistant_node = append_reply(conversation, branch, response, snapshot, final: true)
    end

    Result.new(conversation: conversation, response: response, assistant_node: assistant_node,
               tool_call_nodes: tool_call_nodes, snapshot: snapshot)
  end

  def append_reply(conversation, branch, response, snapshot, final:)
    meta = final ? response.meta.merge("parsed" => !response.parsed.nil?) : response.meta.slice("model", "provider")
    node = MessageNode.append!(
      conversation: conversation, parent_hash: branch.head_hash, role: "assistant",
      speaker: @persona&.key, content: response.content, meta: meta, prompt_snapshot_hash: snapshot.digest
    )
    branch.advance!(node)
    node
  end

  def append_input(conversation, branch)
    @messages.map do |m|
      node = MessageNode.append!(
        conversation: conversation, parent_hash: branch.head_hash, role: m["role"].to_s, content: m["content"].to_s
      )
      branch.advance!(node)
      node
    end
  end
end
