# A one-shot completion, persisted as a single-branch `pipeline` conversation
# (B1): the request messages become nodes, the prompt is snapshotted, the
# reply is a node with the ledger's ref pointing back here. Everything a
# surface extracts from the reply can cite the reply node's hash.
class Completion
  Result = Struct.new(:conversation, :response, :assistant_node, :snapshot, keyword_init: true) do
    def status
      response.status
    end

    def refused?
      response.refused?
    end
  end

  # messages: [{ role: user|assistant|system, content: }] — system-role
  # messages fold into `system`; `persona` supplies it when given instead.
  def initialize(role:, messages:, system: nil, persona: nil, schema: nil, params: {}, operation: nil,
                 metadata: {}, ref: nil, realm:)
    @role = role
    @messages = Array(messages).map { |m| m.to_h.stringify_keys }
    system_messages, @messages = @messages.partition { |m| m["role"].to_s == "system" }
    @system = [ persona&.system_core, system, *system_messages.map { |m| m["content"] } ].compact_blank.join("\n\n")
    @persona = persona
    @schema = schema
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
    nodes = append_input(conversation, branch)

    snapshot = PromptSnapshot.record!(
      conversation: conversation,
      assembled: {
        "operation" => @operation, "persona" => @persona&.key, "schema" => @schema,
        "system" => @system,
        "messages" => nodes.map { |n| { "role" => n.role, "content" => n.content, "hash" => n.content_hash } }
      }
    )

    response = Gateway.complete(
      role: @role, system: @system, messages: @messages, schema: @schema, params: @params,
      operation: @operation, ref: @ref.presence || "conversation/#{conversation.id}",
      metadata: @metadata.merge("conversation" => conversation.id), snapshot: snapshot.digest, &on_event
    )

    assistant_node = nil
    unless response.refused?
      assistant_node = MessageNode.append!(
        conversation: conversation, parent_hash: branch.head_hash, role: "assistant",
        speaker: @persona&.key, content: response.content,
        meta: response.meta.merge("parsed" => !response.parsed.nil?),
        prompt_snapshot_hash: snapshot.digest
      )
      branch.advance!(assistant_node)
    end

    Result.new(conversation: conversation, response: response, assistant_node: assistant_node, snapshot: snapshot)
  end

  # Reads a stored pipeline conversation back into the completion shape.
  def self.find(id)
    conversation = Conversation.pipelines.find(id)
    timeline = conversation.branch.timeline
    reply = timeline.last if timeline.last&.role == "assistant"
    snapshot = reply && PromptSnapshot.find_by(digest: reply.prompt_snapshot_hash)
    parsed = reply && snapshot&.assembled&.dig("schema") ? (Gateway::Structured.parse(reply.content) rescue nil) : nil
    { conversation: conversation, reply: reply, snapshot: snapshot || conversation.prompt_snapshots.first, parsed: parsed }
  end

  private

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
