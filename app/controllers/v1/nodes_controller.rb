module V1
  class NodesController < ApplicationController
    # Swipe cycling: all nodes sharing this node's parent, oldest first.
    def siblings
      conversation = Conversation.find(params[:conversation_id])
      node = conversation.message_nodes.find(params[:hash])
      render json: node.siblings.map { |sibling|
        {
          hash: sibling.content_hash, role: sibling.role, speaker: sibling.speaker,
          content: sibling.content, created_at: sibling.created_at
        }
      }
    end
  end
end
