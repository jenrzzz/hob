# One chat turn: append the user node, assemble context, call the gateway,
# append the assistant node, advance the branch ref. Streams deltas to the
# caller's block when given (the SSE path); otherwise blocks until done.
class ChatTurn
  DEFAULT_ROLE = "chat-default".freeze

  Result = Struct.new(:user_node, :assistant_node, :snapshot, keyword_init: true)

  def initialize(conversation:, branch:, content:, persona: nil, context: nil, role: nil)
    @conversation = conversation
    @branch = branch
    @content = content
    @persona = persona
    @context = context
    @role = role || persona&.model_role || DEFAULT_ROLE
  end

  def call(&stream)
    user_node = MessageNode.append!(
      conversation: @conversation, parent_hash: @branch.head_hash,
      role: "user", content: @content
    )
    @branch.advance!(user_node)

    assembly = Assembly::Pipeline.new(
      conversation: @conversation, head: user_node,
      persona: @persona, context: @context
    ).assemble

    chat, resolution = Gateway.chat(role: @role)
    chat = chat.with_instructions(assembly.system) if assembly.system.present?

    # Replay everything but the final user message; `ask` sends that one.
    assembly.messages[0..-2].to_a.each do |m|
      chat.add_message(role: m["role"].to_sym, content: m["content"])
    end

    response =
      if stream
        chat.ask(@content) { |chunk| stream.call(chunk.content) if chunk.content.present? }
      else
        chat.ask(@content)
      end

    assistant_node = MessageNode.append!(
      conversation: @conversation, parent_hash: user_node.content_hash,
      role: "assistant", speaker: @persona&.key, content: response.content.to_s,
      meta: { "model" => resolution.model,
              "input_tokens" => response.input_tokens.to_i,
              "output_tokens" => response.output_tokens.to_i },
      prompt_snapshot_hash: assembly.snapshot.digest
    )
    @branch.advance!(assistant_node)

    Gateway.record_usage!(chat: chat, resolution: resolution, role: @role,
                          ref: "conversation/#{@conversation.id}")

    Result.new(user_node: user_node, assistant_node: assistant_node, snapshot: assembly.snapshot)
  end
end
