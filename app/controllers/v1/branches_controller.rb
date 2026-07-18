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
  end
end
