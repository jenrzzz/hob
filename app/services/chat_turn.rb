# One chat turn on a DAG branch: append the user node (if any), assemble
# context, call the gateway, append the assistant node(s), advance the ref.
# Streams deltas to the caller's block when given (the SSE path); otherwise
# blocks until done.
#
# The assistant speaks at whatever the branch head is (B2): a fresh user node
# when `content` is given, the existing head otherwise — including an
# assistant node, which is how an interview steps down a stuck question.
#
# With `tools`, the model may stop to ask for one (C): the calls land as
# tool_call nodes, the turn ends with Result#tool_calls set, and the caller
# comes back with `tool_results` for the next turn.
#
# With memory on (MEMORY.md), hob also offers its own native tools (recall,
# remember) and executes them here: a round whose calls are all native loops
# server-side, re-assembling and asking again, up to max_iterations; a round
# mixing native and client calls answers the native ones in the DAG and hands
# back only the client ones.
class ChatTurn
  DEFAULT_ROLE = "chat-default".freeze
  UNIT_KEYS = %w[input_tokens output_tokens cache_read_tokens cache_creation_tokens].freeze

  Result = Struct.new(:user_node, :assistant_nodes, :tool_call_nodes, :native, :snapshot, :response, :units,
                      :cost, :rounds, keyword_init: true) do
    def assistant_node
      assistant_nodes.last
    end

    def tool_calls
      tool_call_nodes.map(&:tool_call)
    end

    def tool_calls?
      tool_call_nodes.any?
    end

    def status
      tool_calls? ? "tool_calls" : "success"
    end
  end

  # Receives (:call | :result, payload) as native tools run (the SSE path).
  attr_accessor :on_native

  # regenerate_at: hash of an existing node — reply again under it, so the
  # new reply lands as a *sibling* of prior ones (a swipe).
  # tools / tool_choice / tool_results / max_iterations: see ToolExchange.
  # content: a string, or text/image blocks (Attachments).
  # memory: true | false | { recall, tools, budget, about } (Memory::Scope).
  def initialize(conversation:, branch:, content: nil, persona: nil, personas: nil, context: nil,
                 instruction: nil, role: nil, regenerate_at: nil, preset: nil, situation: nil,
                 tools: nil, tool_choice: nil, tool_results: nil, max_iterations: nil, memory: nil)
    @conversation = conversation
    @branch = branch
    @content = content
    @personas = Array(personas.presence || persona).compact
    @context = context
    @instruction = instruction
    @situation = situation
    @regenerate_at = regenerate_at
    @preset = preset
    @role = role || @personas.filter_map(&:model_role).first || DEFAULT_ROLE
    @tools = Array(tools).presence
    @tool_choice = tool_choice
    @tool_results = Array(tool_results).presence
    @max_iterations = (max_iterations || ToolExchange::DEFAULT_MAX_ITERATIONS).to_i
    @memory_request = memory
  end

  def call(&stream)
    scope = Memory::Scope.build(personas: @personas, conversation: @conversation, request: @memory_request)
    native = scope&.tools? ? Memory::Tools.new(scope) : nil
    tools = declared_tools(native)

    user_node, anchor = resolve_anchor
    assistant_nodes = []
    outcomes = []
    units = Hash.new(0)
    cost = nil
    rounds = 0

    loop do
      rounds += 1
      assembly = Assembly::Pipeline.new(
        conversation: @conversation, head: anchor, personas: @personas, context: @context,
        instruction: @instruction, preset: @preset, situation: @situation, memory: scope
      ).assemble

      unless %w[user tool].include?(assembly.messages.last&.dig("role"))
        raise Gateway::Invalid, "nothing for the assistant to answer: give content or an instruction"
      end

      response = Gateway.complete(
        role: @role, system: assembly.system, messages: assembly.messages,
        tools: tools, tool_choice: tool_choice_for(anchor, tools),
        params: @preset&.params || {}, operation: "chat",
        ref: "conversation/#{@conversation.id}", snapshot: assembly.snapshot.digest
      ) { |type, text| stream&.call(text) if type == :delta }

      raise Gateway::Refused, "the model declined to reply" if response.refused?

      response.units.each { |k, v| units[k] += v.to_i }
      cost = response.cost && (cost || 0) + response.cost

      parent_hash = anchor&.content_hash || MessageNode::ROOT
      new_text = response.content.strip.empty? ? [] : append_reply(response, parent_hash: parent_hash, snapshot: assembly.snapshot)
      assistant_nodes.concat(new_text)
      parent_hash = new_text.last.content_hash if new_text.any?

      unless response.tool_calls?
        @branch.advance!(new_text.last) if new_text.any?
        return result(user_node, assistant_nodes, [], outcomes, assembly, response, units, cost, rounds)
      end

      call_nodes = ToolExchange.append_calls!(
        conversation: @conversation, parent_hash: parent_hash, calls: response.tool_calls,
        meta: response.meta, snapshot_digest: assembly.snapshot.digest,
        reasoning: new_text.empty? ? response.reasoning : nil
      )
      @branch.advance!(call_nodes.last)

      client_nodes, settled = ToolExchange.settle_native!(
        conversation: @conversation, branch: @branch, call_nodes: call_nodes, native: native, on_native: on_native
      )
      outcomes.concat(settled)
      if client_nodes.any? || settled.empty?
        return result(user_node, assistant_nodes, client_nodes, outcomes, assembly, response, units, cost, rounds)
      end

      # Only native calls: ask again with their results. The cap makes the
      # model answer (tool_choice none) once the rounds are spent; this guard
      # is for a provider that ignores it.
      raise Gateway::Invalid, "the model kept calling tools past max_iterations" if rounds > @max_iterations + 1

      anchor = @branch.head
    end
  end

  private

  def result(user_node, assistant_nodes, client_nodes, outcomes, assembly, response, units, cost, rounds)
    Result.new(user_node: user_node, assistant_nodes: assistant_nodes, tool_call_nodes: client_nodes,
               native: outcomes.map { |o| { "id" => o.call["id"], "name" => o.call["name"], "arguments" => o.call["arguments"],
                                            "content" => o.content, "error" => o.error } },
               snapshot: assembly.snapshot, response: response, units: units.to_h, cost: cost, rounds: rounds)
  end

  # The caller's tools, plus the native ones when memory tools are on. A
  # caller's tool may not take a native tool's name.
  def declared_tools(native)
    return @tools unless native

    clash = Array(@tools).map { |t| (t["name"] || t[:name]).to_s } & Memory::Tools::NAMES
    raise Gateway::Invalid, "#{clash.join(', ')} is a native tool while memory tools are on; rename yours" if clash.any?

    Array(@tools) + Memory::Tools.defs
  end

  # -> [new user node or nil, the node the reply hangs under (nil = root)]
  def resolve_anchor
    if @tool_results
      raise Gateway::Invalid, "content and tool_results are exclusive" if @content.present?

      nodes = ToolExchange.append_results!(conversation: @conversation, head: @branch.head, results: @tool_results)
      @branch.advance!(nodes.last)
      [ nil, nodes.last ]
    elsif @regenerate_at
      node = @conversation.message_nodes.find(@regenerate_at)
      @branch.advance!(node)
      [ node.role == "user" ? node : nil, node ]
    elsif @content.present?
      text, attachments = Attachments.ingest(@content, realm: @conversation.realm)
      node = MessageNode.append!(
        conversation: @conversation, parent_hash: @branch.head_hash, role: "user", content: text, attachments: attachments
      )
      @branch.advance!(node)
      [ node, node ]
    else
      [ nil, @branch.head ]
    end
  end

  # Past the iteration cap the tools stay declared (providers require it
  # when the history holds calls) but the model may not call them.
  def tool_choice_for(anchor, tools)
    return nil unless tools
    return "none" if ToolExchange.rounds(anchor) >= @max_iterations

    @tool_choice
  end

  # A single persona sometimes self-tags anyway; the speaker column already
  # carries the attribution. An ensemble reply splits into a chain of
  # speaker-attributed nodes, tokens recorded on the last. The turn's thinking
  # blocks ride on the first node (Transcript replays them).
  def append_reply(response, parent_hash:, snapshot:)
    keys = @personas.map(&:key)
    segments = Assembly::Ensemble.split(response.content, keys)
    segments = [ [ nil, response.content.strip ] ] if segments.empty?

    segments.each_with_index.map do |(speaker, text), index|
      last = index == segments.size - 1 && !response.tool_calls?
      meta = last ? response.meta : response.meta.except(*UNIT_KEYS)
      meta = meta.merge("segment" => index + 1, "segments" => segments.size) if segments.size > 1
      meta = meta.merge("reasoning" => response.reasoning) if index.zero? && response.reasoning
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
