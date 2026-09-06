module V1
  # POST /v1/conversations/:conversation_id/events { content, branch?, meta? }
  # Appends a `role: event` node at the branch head (B6): a surface's side
  # effect ("added to the meal plan") in the timeline, out of the prompt.
  class EventsController < ApplicationController
    def create
      conversation = Conversation.find(params[:conversation_id])
      branch = conversation.branch(params[:branch].presence || Conversation::MAIN)
      meta = params[:meta].respond_to?(:permit!) ? params[:meta].permit!.to_h : {}

      node = MessageNode.append!(
        conversation: conversation, parent_hash: branch.head_hash,
        role: "event", kind: "event", content: params.require(:content), meta: meta
      )
      branch.advance!(node)
      render json: node_json(node), status: :created
    end
  end
end
