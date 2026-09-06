module V1
  # POST /v1/completions — the door for one-shot, usually structured, calls.
  # { role, operation?, system? | persona?, messages[], schema?, params?,
  #   metadata?, ref?, realm? }
  # → 200 { id, status: success|refused, content, parsed?, usage, model,
  #         provider, snapshot, node }
  # Accept: text/event-stream → delta… retry? usage done
  # Refusal is 200 with status: refused — the call happened and was metered.
  class CompletionsController < ApplicationController
    include SseStreaming

    def create
      completion = Completion.new(
        role: params.require(:role), operation: params[:operation].presence,
        messages: messages_param, system: params[:system].presence,
        persona: params[:persona].presence && Persona.find_by!(key: params[:persona]),
        schema: hash_param(:schema), params: hash_param(:params) || {}, metadata: hash_param(:metadata) || {},
        ref: params[:ref].presence, realm: requested_realm
      )

      if streaming_requested?
        stream_events do
          result = completion.call(&sse_gateway_events)
          sse_write(type: "usage", **usage_json(result.response))
          sse_write(type: "done", **serialize(result))
        end
      else
        render json: serialize(completion.call)
      end
    end

    # GET /v1/completions/:id — a pipeline conversation's single turn.
    def show
      found = Completion.find(params[:id])
      reply = found[:reply]
      render json: {
        id: found[:conversation].id, status: reply ? "success" : "refused",
        operation: found[:conversation].title, realm: found[:conversation].realm,
        content: reply&.content, parsed: found[:parsed],
        usage: reply ? reply.meta.slice("input_tokens", "output_tokens", "cache_read_tokens") : nil,
        model: reply&.meta&.dig("model"), provider: reply&.meta&.dig("provider"),
        snapshot: found[:snapshot]&.digest, node: node_json(reply),
        created_at: found[:conversation].created_at
      }
    end

    private

    def messages_param
      Array(params[:messages]).map { |m| m.respond_to?(:permit) ? m.permit(:role, :content).to_h : m.to_h }
    end

    def hash_param(name)
      value = params[name]
      return nil if value.blank?

      value.respond_to?(:permit!) ? value.permit!.to_h : value.to_h
    end

    def usage_json(response)
      response.units.symbolize_keys.merge(cost: response.cost&.to_f)
    end

    def serialize(result)
      response = result.response
      {
        id: result.conversation.id, status: result.status,
        content: response.refused? ? nil : response.content, parsed: response.parsed,
        usage: usage_json(response), model: response.model, provider: response.provider,
        stop_reason: response.stop_reason, snapshot: result.snapshot.digest,
        node: node_json(result.assistant_node)
      }
    end
  end
end
