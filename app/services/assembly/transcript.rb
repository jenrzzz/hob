module Assembly
  # Renders a chronological run of nodes as gateway messages. Text nodes are
  # one message each; a run of tool_call nodes folds into one assistant
  # message carrying every call (providers require the calls and their
  # results to be adjacent), together with the assistant text node that
  # immediately precedes the run when the model said both in one turn;
  # tool_result nodes become `tool` messages. Event nodes stay in the DAG but
  # out of the prompt.
  #
  # Images ride as `attachments` (digests; Transport reads the bytes), a
  # failed tool result as `error: true`, and a turn's thinking blocks as
  # `reasoning`, from whichever node of the turn kept them.
  module Transcript
    module_function

    # elide: { content_hash => shorter text } for tool results to shorten.
    def render(nodes, tag_speakers: false, elide: {})
      messages = []
      nodes.each do |node|
        case node.kind
        when "event" then next
        when "tool_call"
          call = node.tool_call
          last = messages.last
          if last&.dig("tool_calls")
            last["tool_calls"] << call
            last["hashes"] << node.content_hash
          elsif last && last["role"] == "assistant" && last["turn_open"]
            # The text the model said before calling, in the same turn.
            last["tool_calls"] = [ call ]
            last["hashes"] = [ last["hash"], node.content_hash ]
          else
            messages << { "role" => "assistant", "content" => "", "tool_calls" => [ call ],
                          "hash" => node.content_hash, "hashes" => [ node.content_hash ] }
          end
          messages.last["reasoning"] ||= node.meta["reasoning"] if node.meta["reasoning"]
        when "tool_result"
          messages << { "role" => "tool", "tool_call_id" => node.meta["tool_call_id"],
                        "content" => elide.fetch(node.content_hash, node.content),
                        "hash" => node.content_hash, "error" => node.meta["error"] ? true : nil,
                        "attachments" => node.attachments.presence }.compact
        else
          next unless %w[user assistant].include?(node.role)

          content = node.content
          content = "[#{node.speaker}]\n#{content}" if tag_speakers && node.speaker.present?
          message = { "role" => node.role, "content" => content, "hash" => node.content_hash }
          message["attachments"] = node.attachments if node.attachments.present?
          message["reasoning"] = node.meta["reasoning"] if node.role == "assistant" && node.meta["reasoning"]
          # Only a reply that stopped at tool calls has calls after it in the
          # same turn; its stop_reason says so.
          message["turn_open"] = true if node.role == "assistant" && node.meta["stop_reason"] == "tool_use"
          messages << message
        end
      end
      messages.each { |m| m.delete("turn_open") }
    end
  end
end
