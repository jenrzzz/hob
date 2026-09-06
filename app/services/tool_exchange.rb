# The client-session tool venue (C) in the DAG: the model's calls land as a
# chain of `tool_call` nodes, the request ends, the caller executes and posts
# `tool_results`, which land as `tool_result` nodes before the model is
# called again. Stateless on hob's side; every step is addressable.
module ToolExchange
  DEFAULT_MAX_ITERATIONS = 10

  module_function

  # -> [nodes], chained under parent in the order the model emitted them.
  def append_calls!(conversation:, parent_hash:, calls:, meta: {}, snapshot_digest: nil)
    calls.each_with_index.map do |call, index|
      node_meta = meta.merge("tool" => call["name"], "tool_call_id" => call["id"])
      node_meta = node_meta.except("input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens") unless index == calls.size - 1
      node = MessageNode.append!(
        conversation: conversation, parent_hash: parent_hash, role: "assistant", kind: "tool_call",
        content: JSON.generate("id" => call["id"], "name" => call["name"], "arguments" => call["arguments"] || {}),
        meta: node_meta, prompt_snapshot_hash: snapshot_digest
      )
      parent_hash = node.content_hash
      node
    end
  end

  # results: [{ id, content }] — one per pending call, no more, no fewer.
  # -> [nodes], chained under head in the order the calls were made.
  def append_results!(conversation:, head:, results:)
    pending = pending_calls(head)
    raise Gateway::Invalid, "no tool calls are waiting for results at the branch head" if pending.empty?

    by_id = Array(results).to_h { |r| r = r.to_h.stringify_keys; [ r["id"].to_s, r ] }
    missing = pending.map { |c| c["id"] } - by_id.keys
    extra = by_id.keys - pending.map { |c| c["id"] }
    raise Gateway::Invalid, "tool_results missing for #{missing.join(', ')}" if missing.any?
    raise Gateway::Invalid, "tool_results for unknown calls #{extra.join(', ')}" if extra.any?

    parent_hash = head.content_hash
    pending.map do |call|
      result = by_id[call["id"]]
      content = result["content"]
      content = JSON.generate(content) unless content.is_a?(String)
      node = MessageNode.append!(
        conversation: conversation, parent_hash: parent_hash, role: "user", kind: "tool_result",
        content: content.presence || "(no output)",
        meta: { "tool" => call["name"], "tool_call_id" => call["id"], "error" => result["error"] }.compact
      )
      parent_hash = node.content_hash
      node
    end
  end

  # The unanswered calls at head: the run of tool_call nodes it ends with.
  def pending_calls(head)
    return [] unless head&.tool_call?

    head.ancestry.take_while(&:tool_call?).reverse.map(&:tool_call)
  end

  # How many call/result rounds the branch has been through: the cap counts
  # rounds, not calls, so parallel calls don't burn iterations.
  def rounds(head)
    return 0 if head.nil?

    head.ancestry.each_cons(2).count { |newer, older| newer.tool_result? && !older.tool_result? }
  end
end
