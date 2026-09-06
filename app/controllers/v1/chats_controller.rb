module V1
  # POST /v1/conversations/:conversation_id/chat
  # { content?, branch: "main", persona? | personas[]?, context?, instruction?,
  #   role?, preset?, regenerate_at? }
  # Accept: text/event-stream streams `delta` events and finishes with `done`;
  # anything else blocks and returns the full turn as JSON.
  class ChatsController < ApplicationController
    include SseStreaming

    def create
      conversation = Conversation.find(params[:conversation_id])
      branch = conversation.branch(params[:branch].presence || Conversation::MAIN)
      persona = params[:persona].presence && Persona.find_by!(key: params[:persona])
      personas = Array(params[:personas]).presence&.map { |key| Persona.find_by!(key: key) }
      preset = params[:preset].presence && Preset.find_by!(key: params[:preset])

      turn = ChatTurn.new(
        conversation: conversation, branch: branch, persona: persona, personas: personas,
        content: params[:content], context: context_param, instruction: params[:instruction].presence,
        role: params[:role].presence, regenerate_at: params[:regenerate_at].presence,
        preset: preset
      )

      if streaming_requested?
        stream_events do
          result = turn.call { |delta| sse_write(type: "delta", content: delta) }
          sse_write(type: "usage", **result.response.units.symbolize_keys, cost: result.response.cost&.to_f)
          sse_write(type: "done", **serialize_result(result))
        end
      else
        render json: serialize_result(turn.call)
      end
    end

    private

    # context: a string, a hash, or a list of { name, body, budget, volatile }.
    def context_param
      raw = params[:context]
      return nil if raw.blank?
      return raw if raw.is_a?(String)

      raw.respond_to?(:permit!) ? raw.permit!.to_h : raw.map { |b| b.respond_to?(:permit!) ? b.permit!.to_h : b }
    end

    def serialize_result(result)
      {
        status: "success",
        user: node_json(result.user_node),
        assistant: node_json(result.assistant_node),
        assistants: result.assistant_nodes.map { |n| node_json(n) },
        snapshot: result.snapshot.digest
      }
    end
  end
end
