module V1
  # POST /v1/conversations/:conversation_id/chat
  # { content?, branch: "main", persona? | personas[]?, context?, instruction?,
  #   role?, preset?, situation?, regenerate_at?, tools?, tool_choice?, tool_results?,
  #   max_iterations?, memory?, with? }
  # with: who the turn is with, from a person's key (Assembly::Counterpart).
  # content and tool_results[].content: a string, or text/image blocks.
  # memory: true | false | { recall, tools, budget, about } (MEMORY.md); with
  # tools on, native recall/remember run inside the turn and stream as
  # native_call / native_result events.
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
        content: content_param, context: context_param, instruction: params[:instruction].presence,
        role: params[:role].presence, regenerate_at: params[:regenerate_at].presence,
        preset: preset, situation: situation_param, tools: array_param(:tools), tool_choice: params[:tool_choice].presence,
        tool_results: array_param(:tool_results), max_iterations: params[:max_iterations].presence,
        memory: memory_param, with: with_param
      )

      if streaming_requested?
        stream_events do
          turn.on_native = ->(kind, payload) { sse_native(kind, payload) }
          result = turn.call { |delta| sse_write(type: "delta", content: delta) }
          result.tool_call_nodes.each { |n| sse_write(type: "tool_call", **tool_call_json(n).symbolize_keys) }
          sse_write(type: "usage", **result.units.symbolize_keys, cost: result.cost&.to_f, rounds: result.rounds)
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

    # with: a ref, or { name, about } for a guest (Assembly::Counterpart).
    def with_param
      raw = params[:with]
      raw.respond_to?(:permit) ? raw.permit(:name, :about).to_h : raw.presence
    end

    def situation_param
      raw = params[:situation]
      return raw unless raw.respond_to?(:permit)

      unknown = raw.keys.map(&:to_s) - %w[person]
      raise Gateway::Invalid, "unknown situation option: #{unknown.join(', ')}" if unknown.any?

      raw.permit(:person).to_h
    end

    def serialize_result(result)
      {
        status: result.status,
        user: node_json(result.user_node),
        assistant: node_json(result.assistant_node),
        assistants: result.assistant_nodes.map { |n| node_json(n) },
        tool_calls: result.tool_call_nodes.map { |n| tool_call_json(n) },
        native: result.native,
        usage: result.units.merge("cost" => result.cost&.to_f, "rounds" => result.rounds),
        snapshot: result.snapshot.digest
      }
    end
  end
end
