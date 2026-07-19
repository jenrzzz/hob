module V1
  class BranchesController < ApplicationController
    def index
      conversation = Conversation.find(params[:conversation_id])
      render json: conversation.branches.order(:created_at).map { |b|
        { name: b.name, head: b.head_hash, created_at: b.created_at }
      }
    end

    # Fork: POST { name:, at: <node hash> } — a ref, not a copy.
    def create
      conversation = Conversation.find(params[:conversation_id])
      node = conversation.message_nodes.find(params.require(:at))
      branch = conversation.branches.create!(name: params.require(:name), head_hash: node.content_hash)
      render json: { name: branch.name, head: branch.head_hash }, status: :created
    end

    # Ref move: PATCH { head: <node hash> } — how swipe cycling activates an
    # older sibling. Nothing is destroyed; the ref just points elsewhere.
    def update
      conversation = Conversation.find(params[:conversation_id])
      branch = conversation.branch(params[:name])
      node = conversation.message_nodes.find(params.require(:head))
      branch.advance!(node)
      render json: { name: branch.name, head: branch.head_hash }
    end
  end
end
