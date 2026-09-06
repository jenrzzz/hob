# One chat turn on a DAG branch: append the user node (if any), assemble
# context, call the gateway, append the assistant node(s), advance the ref.
# Streams deltas to the caller's block when given (the SSE path); otherwise
# blocks until done.
#
# The assistant speaks at whatever the branch head is (B2): a fresh user node
# when `content` is given, the existing head otherwise — including an
# assistant node, which is how an interview steps down a stuck question.
class ChatTurn
  DEFAULT_ROLE = "chat-default".freeze

  Result = Struct.new(:user_node, :assistant_nodes, :snapshot, :response, keyword_init: true) do
    def assistant_node
      assistant_nodes.last
    end
  end

  # regenerate_at: hash of an existing node — reply again under it, so the
  # new reply lands as a *sibling* of prior ones (a swipe).
  def initialize(conversation:, branch:, content: nil, persona: nil, personas: nil, context: nil,
                 instruction: nil, role: nil, regenerate_at: nil, preset: nil)
    @conversation = conversation
    @branch = branch
    @content = content
    @personas = Array(personas.presence || persona).compact
    @context = context
    @instruction = instruction
    @regenerate_at = regenerate_at
    @preset = preset
    @role = role || @personas.filter_map(&:model_role).first || DEFAULT_ROLE
  end

  def call(&stream)
    user_node, anchor = resolve_anchor

    assembly = Assembly::Pipeline.new(
      conversation: @conversation, head: anchor,
      personas: @personas, context: @context, instruction: @instruction, preset: @preset
    ).assemble

    if assembly.messages.last&.dig("role") != "user"
      raise Gateway::Invalid, "nothing for the assistant to answer: give content or an instruction"
    end

    response = Gateway.complete(
      role: @role, system: assembly.system, messages: assembly.messages,
      params: @preset&.params || {}, operation: "chat",
      ref: "conversation/#{@conversation.id}", snapshot: assembly.snapshot.digest
    ) { |type, text| stream&.call(text) if type == :delta }

    raise Gateway::Refused, "the model declined to reply" if response.refused?

    assistant_nodes = append_reply(response, parent_hash: anchor&.content_hash || MessageNode::ROOT,
                                             snapshot: assembly.snapshot)
    @branch.advance!(assistant_nodes.last)

    Result.new(user_node: user_node, assistant_nodes: assistant_nodes, snapshot: assembly.snapshot,
               response: response)
  end

  private

  # -> [new user node or nil, the node the reply hangs under (nil = root)]
  def resolve_anchor
    if @regenerate_at
      node = @conversation.message_nodes.find(@regenerate_at)
      @branch.advance!(node)
      [ node.role == "user" ? node : nil, node ]
    elsif @content.present?
      node = MessageNode.append!(
        conversation: @conversation, parent_hash: @branch.head_hash, role: "user", content: @content
      )
      @branch.advance!(node)
      [ node, node ]
    else
      [ nil, @branch.head ]
    end
  end

  # A single persona sometimes self-tags anyway; the speaker column already
  # carries the attribution. An ensemble reply splits into a chain of
  # speaker-attributed nodes, tokens recorded on the last.
  def append_reply(response, parent_hash:, snapshot:)
    keys = @personas.map(&:key)
    segments = Assembly::Ensemble.split(response.content, keys)
    segments = [ [ nil, response.content.strip ] ] if segments.empty?

    segments.each_with_index.map do |(speaker, text), index|
      last = index == segments.size - 1
      meta = last ? response.meta : response.meta.except("input_tokens", "output_tokens",
                                                         "cache_read_tokens", "cache_creation_tokens")
      meta = meta.merge("segment" => index + 1, "segments" => segments.size) if segments.size > 1
      node = MessageNode.append!(
        conversation: @conversation, parent_hash: parent_hash,
        role: "assistant", speaker: speaker, content: text, meta: meta,
        prompt_snapshot_hash: snapshot.digest
      )
      parent_hash = node.content_hash
      node
    end
  end
end
