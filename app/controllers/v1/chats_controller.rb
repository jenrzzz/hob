module V1
  # POST /v1/conversations/:conversation_id/chat
  # { content?, branch: "main", persona? | personas[]?, context?, instruction?,
  #   role?, preset?, regenerate_at?, tools?, tool_choice?, tool_results?,
  #   max_iterations? }
  # Accept: text/event-stream streams `delta` events, then any `tool_call`
  # events, `usage`, and `done`; anything else blocks and returns the full
  # turn as JSON with status success|tool_calls.
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
        preset: preset, tools: array_param(:tools), tool_choice: params[:tool_choice].presence,
        tool_results: array_param(:tool_results), max_iterations: params[:max_iterations].presence
      )

      if streaming_requested?
        stream_events do
          result = turn.call { |delta| sse_write(type: "delta", content: delta) }
          result.tool_call_nodes.each { |n| sse_write(type: "tool_call", **tool_call_json(n).symbolize_keys) }
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
        status: result.status,
        user: node_json(result.user_node),
        assistant: node_json(result.assistant_node),
        assistants: result.assistant_nodes.map { |n| node_json(n) },
        tool_calls: result.tool_call_nodes.map { |n| tool_call_json(n) },
        snapshot: result.snapshot.digest
      }
    end
  end
end
