# Tool calls in the DAG. The model's calls land as a chain of `tool_call`
# nodes; results land as `tool_result` nodes chained after them, in call
# order, before the model is called again. Every step is addressable.
#
# Two venues answer calls (MEMORY.md, "Native tools"): hob's own native tools
# (recall, remember) are executed inside the request and their results
# appended at once; the caller's tools (the client session, C) end the
# request, and the caller comes back with `tool_results` for exactly the
# calls still unanswered. A turn mixing both therefore pauses with the
# native results already in the DAG and only the client calls pending.
module ToolExchange
  DEFAULT_MAX_ITERATIONS = 10

  module_function

  # -> [nodes], chained under parent in the order the model emitted them.
  # The turn's thinking blocks (reasoning) ride on the first call node when
  # the caller passes them (no text node of the same turn holds them).
  def append_calls!(conversation:, parent_hash:, calls:, meta: {}, snapshot_digest: nil, reasoning: nil)
    calls.each_with_index.map do |call, index|
      node_meta = meta.merge("tool" => call["name"], "tool_call_id" => call["id"])
      node_meta = node_meta.except("input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens") unless index == calls.size - 1
      node_meta["reasoning"] = reasoning if reasoning && index.zero?
      node = MessageNode.append!(
        conversation: conversation, parent_hash: parent_hash, role: "assistant", kind: "tool_call",
        content: JSON.generate("id" => call["id"], "name" => call["name"], "arguments" => call["arguments"] || {}),
        meta: node_meta, prompt_snapshot_hash: snapshot_digest
      )
      parent_hash = node.content_hash
      node
    end
  end

  # results: [{ id, content, error? }] — one per pending call, no more, no
  # fewer. content: a string, any JSON, or a list of text/image blocks
  # (Attachments). -> [nodes], chained under head in the order the calls
  # were made.
  # partial: answer only some of the pending calls (the native venue does,
  # leaving the caller's for the caller).
  def append_results!(conversation:, head:, results:, venue: "client", partial: false)
    pending = pending_calls(head)
    raise Gateway::Invalid, "no tool calls are waiting for results at the branch head" if pending.empty?

    by_id = Array(results).to_h { |r| r = r.to_h.stringify_keys; [ r["id"].to_s, r ] }
    missing = pending.map { |c| c["id"] } - by_id.keys
    extra = by_id.keys - pending.map { |c| c["id"] }
    raise Gateway::Invalid, "tool_results missing for #{missing.join(', ')}" if missing.any? && !partial
    raise Gateway::Invalid, "tool_results for unknown calls #{extra.join(', ')}" if extra.any?

    parent_hash = head.content_hash
    pending.select { |call| by_id.key?(call["id"]) }.map do |call|
      result = by_id[call["id"]]
      text, attachments = Attachments.ingest(result["content"], realm: conversation.realm)
      node = MessageNode.append!(
        conversation: conversation, parent_hash: parent_hash, role: "user", kind: "tool_result",
        content: text.presence || (attachments.any? ? "" : "(no output)"), attachments: attachments,
        meta: { "tool" => call["name"], "tool_call_id" => call["id"], "error" => result["error"] ? true : nil,
                "venue" => venue, "duration_ms" => result["duration_ms"] }.compact
      )
      parent_hash = node.content_hash
      node
    end
  end

  # Executes the native calls among call_nodes (MEMORY.md, "Native tools")
  # and appends their results at once, advancing the branch. on_native
  # receives (:call | :result, payload) for the stream.
  # -> [client call nodes still pending, native outcomes]
  def settle_native!(conversation:, branch:, call_nodes:, native:, on_native: nil)
    return [ call_nodes, [] ] if native.nil?

    native_nodes, client_nodes = call_nodes.partition { |n| native.native?(n.tool_call["name"]) }
    return [ client_nodes, [] ] if native_nodes.empty?

    durations = []
    outcomes = native_nodes.map do |node|
      on_native&.call(:call, node.tool_call.merge("node" => node.content_hash))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      native.execute(node.tool_call, node: node.content_hash).tap do
        durations << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      end
    end
    nodes = append_results!(
      conversation: conversation, head: branch.head, venue: "native", partial: true,
      results: outcomes.zip(durations).map do |o, ms|
        { "id" => o.call["id"], "content" => o.content, "error" => o.error, "duration_ms" => ms }
      end
    )
    branch.advance!(nodes.last)
    outcomes.zip(nodes).each do |o, n|
      on_native&.call(:result, { "id" => o.call["id"], "name" => o.call["name"], "content" => o.content,
                                 "error" => o.error, "node" => n.content_hash })
    end
    [ client_nodes, outcomes ]
  end

  # The unanswered calls at head: the run of tool_call nodes the branch ends
  # with, less any already answered by the tool_result nodes after it (a
  # native tool answers inside the request; the caller answers the rest).
  def pending_calls(head)
    return [] if head.nil?

    chain = head.ancestry
    answered = chain.take_while(&:tool_result?)
    calls = chain.drop(answered.size).take_while(&:tool_call?)
    return [] if calls.empty?

    done = answered.map { |n| n.meta["tool_call_id"] }
    calls.reverse.map(&:tool_call).reject { |c| done.include?(c["id"]) }
  end

  # How many call/result rounds the branch has been through: the cap counts
  # rounds, not calls, so parallel calls don't burn iterations.
  def rounds(head)
    return 0 if head.nil?

    head.ancestry.each_cons(2).count { |newer, older| newer.tool_result? && !older.tool_result? }
  end
end
