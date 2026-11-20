module V1
  class NodesController < ApplicationController
    MAX_NODES = 50

    # Following a conversation (MELUZINA.md, "Following a conversation"):
    #
    #   GET /v1/conversations/:id/nodes?after=<hash>&wait=25&branch=main
    #   → { head, nodes: [...], missing? }
    #
    # The branch's nodes after `after`, oldest first, waiting up to `wait`
    # seconds for the head to move. Without `after`, no nodes: just the head
    # to follow from. When `after` is no longer on the branch (a reply was
    # regenerated), `missing: true` and the nodes are empty: follow on from
    # the head. A bridge posts the whispers (meta.whisper) it finds here.
    def index
      conversation = Conversation.find(params[:conversation_id])
      branch = conversation.branch(params[:branch].presence || Conversation::MAIN)
      after = params[:after].presence
      if after && params[:wait].present? && branch.head_hash == after
        long_poll(params[:wait]) { branch.reload.head_hash != after }
      end
      branch.reload
      return render json: { head: branch.head_hash, nodes: [] } if after.nil?

      timeline = branch.timeline
      index = timeline.index { |n| n.content_hash == after }
      return render json: { head: branch.head_hash, nodes: [], missing: true } if index.nil? && after != MessageNode::ROOT

      nodes = (index ? timeline.drop(index + 1) : timeline).first(MAX_NODES)
      render json: { head: branch.head_hash, nodes: nodes.map { |n| serialize(n) } }
    end

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

    private

    def serialize(node)
      { hash: node.content_hash, parent: node.parent_hash, role: node.role, speaker: node.speaker, kind: node.kind,
        content: node.content, meta: node.meta.except("reasoning"), created_at: node.created_at }
    end
  end
end
