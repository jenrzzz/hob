module V1
  # POST /v1/conversations/:conversation_id/chat
  # { content:, branch: "main", persona:, context:, role: }
  # Accept: text/event-stream streams `delta` events and finishes with `done`;
  # anything else blocks and returns the full turn as JSON.
  class ChatsController < ApplicationController
    include ActionController::Live

    rescue_from ArgumentError do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def create
      conversation = Conversation.find(params[:conversation_id])
      branch = conversation.branch(params[:branch].presence || Conversation::MAIN)
      persona = params[:persona].presence && Persona.find_by!(key: params[:persona])

      turn = ChatTurn.new(
        conversation: conversation, branch: branch, persona: persona,
        content: params[:content], context: params[:context],
        role: params[:role].presence, regenerate_at: params[:regenerate_at].presence
      )

      if request.headers["Accept"].to_s.include?("text/event-stream")
        stream_turn(turn)
      else
        result = turn.call
        render json: serialize_result(result)
      end
    end

    private

    def stream_turn(turn)
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      result = turn.call { |delta| sse_write(type: "delta", content: delta) }
      sse_write(type: "usage", **result.assistant_node.meta.symbolize_keys)
      sse_write(type: "done", **serialize_result(result))
    rescue StandardError => e
      sse_write(type: "error", message: e.message)
    ensure
      response.stream.close
    end

    def sse_write(payload)
      response.stream.write("data: #{JSON.generate(payload)}\n\n")
    end

    def serialize_result(result)
      {
        user: { hash: result.user_node.content_hash, content: result.user_node.content },
        assistant: {
          hash: result.assistant_node.content_hash,
          speaker: result.assistant_node.speaker,
          content: result.assistant_node.content,
          meta: result.assistant_node.meta
        },
        snapshot: result.snapshot.digest
      }
    end
  end
end
