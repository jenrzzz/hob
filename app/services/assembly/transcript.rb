module Assembly
  # Renders a chronological run of nodes as gateway messages. Text nodes are
  # one message each; a run of tool_call nodes folds into one assistant
  # message carrying every call (providers require the calls and their
  # results to be adjacent); tool_result nodes become `tool` messages.
  # Event nodes stay in the DAG but out of the prompt.
  module Transcript
    module_function

    def render(nodes, tag_speakers: false)
      messages = []
      nodes.each do |node|
        case node.kind
        when "event" then next
        when "tool_call"
          call = node.tool_call
          if messages.last&.dig("tool_calls")
            messages.last["tool_calls"] << call
            messages.last["hashes"] << node.content_hash
          else
            messages << { "role" => "assistant", "content" => "", "tool_calls" => [ call ],
                          "hash" => node.content_hash, "hashes" => [ node.content_hash ] }
          end
        when "tool_result"
          messages << { "role" => "tool", "tool_call_id" => node.meta["tool_call_id"], "content" => node.content,
                        "hash" => node.content_hash }
        else
          next unless %w[user assistant].include?(node.role)

          content = node.content
          content = "[#{node.speaker}]\n#{content}" if tag_speakers && node.speaker.present?
          messages << { "role" => node.role, "content" => content, "hash" => node.content_hash }
        end
      end
      messages
    end
  end
end
