module V1
  # POST /v1/completions — the door for one-shot, usually structured, calls.
  # { role, operation?, system? | persona?, messages[], schema?, tools?,
  #   tool_choice?, max_iterations?, params?, metadata?, ref?, realm? }
  # → 200 { id, status: success|refused|tool_calls, content, parsed?,
  #         tool_calls?, usage, model, provider, snapshot, node }
  # Accept: text/event-stream → delta… retry? tool_call… usage done
  # Refusal is 200 with status: refused — the call happened and was metered.
  #
  # A completion that stopped at tool calls resumes on the same endpoint:
  # { id, tool_results: [{ id, content }] } — the calls and results become
  # nodes and the model is asked again.
  class CompletionsController < ApplicationController
    include SseStreaming

    def create
      run = if params[:id].present?
        conversation = Conversation.pipelines.find(params[:id])
        ->(&on_event) { Completion.resume(conversation, tool_results: array_param(:tool_results) || [], &on_event) }
      else
        completion = Completion.new(
          role: params.require(:role), operation: params[:operation].presence,
          messages: messages_param, system: params[:system].presence,
          persona: params[:persona].presence && Persona.find_by!(key: params[:persona]),
          schema: hash_param(:schema), tools: array_param(:tools), tool_choice: params[:tool_choice].presence,
          max_iterations: params[:max_iterations].presence,
          params: hash_param(:params) || {}, metadata: hash_param(:metadata) || {},
          ref: params[:ref].presence, realm: requested_realm
        )
        ->(&on_event) { completion.call(&on_event) }
      end

      if streaming_requested?
        stream_events do
          result = run.call(&sse_gateway_events)
          result.tool_call_nodes.each { |n| sse_write(type: "tool_call", **tool_call_json(n).symbolize_keys) }
          sse_write(type: "usage", **usage_json(result.response))
          sse_write(type: "done", **serialize(result))
        end
      else
        render json: serialize(run.call)
      end
    end

    # GET /v1/completions/:id — a pipeline conversation's single turn.
    def show
      found = Completion.find(params[:id])
      reply = found[:reply]
      render json: {
        id: found[:conversation].id, status: found[:status],
        operation: found[:conversation].title, realm: found[:conversation].realm,
        content: reply&.content, parsed: found[:parsed],
        tool_calls: found[:tool_calls],
        usage: reply ? reply.meta.slice("input_tokens", "output_tokens", "cache_read_tokens") : nil,
        model: reply&.meta&.dig("model"), provider: reply&.meta&.dig("provider"),
        snapshot: found[:snapshot]&.digest, node: node_json(reply),
        messages: found[:timeline].map { |n| node_json(n) },
        created_at: found[:conversation].created_at
      }
    end

    private

    def messages_param
      Array(params[:messages]).map { |m| m.respond_to?(:permit) ? m.permit(:role, :content).to_h : m.to_h }
    end

    def usage_json(response)
      response.units.symbolize_keys.merge(cost: response.cost&.to_f)
    end

    def serialize(result)
      response = result.response
      {
        id: result.conversation.id, status: result.status,
        content: response.refused? ? nil : response.content, parsed: response.parsed,
        tool_calls: result.tool_call_nodes.map { |n| tool_call_json(n) },
        usage: usage_json(response), model: response.model, provider: response.provider,
        stop_reason: response.stop_reason, snapshot: result.snapshot.digest,
        node: node_json(result.assistant_node)
      }
    end
  end
end
