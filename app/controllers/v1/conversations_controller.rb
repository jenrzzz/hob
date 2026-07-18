module V1
  class ConversationsController < ApplicationController
    def index
      conversations = Conversation.order(updated_at: :desc).limit(100)
      render json: conversations.map { |c| serialize(c) }
    end

    def create
      realm = params[:realm].presence || Current.clearance
      if Realm.rank_of(realm) > clearance_rank
        return render json: { error: "realm above clearance" }, status: :forbidden
      end

      conversation = Conversation.create!(
        surface: Current.surface, realm: realm, taint_realm: realm,
        title: params[:title]
      )
      render json: serialize(conversation), status: :created
    end

    def show
      conversation = Conversation.find(params[:id])
      branch = conversation.branch(params[:branch].presence || Conversation::MAIN)
      render json: serialize(conversation).merge(
        branch: branch.name,
        messages: branch.timeline.map { |n| serialize_node(n) }
      )
    end

    private

    def serialize(conversation)
      {
        id: conversation.id, surface: conversation.surface, title: conversation.title,
        realm: conversation.realm, taint_realm: conversation.taint_realm,
        branches: conversation.branches.order(:created_at).pluck(:name),
        updated_at: conversation.updated_at
      }
    end

    def serialize_node(node)
      {
        hash: node.content_hash, parent: node.parent_hash, role: node.role,
        speaker: node.speaker, kind: node.kind, content: node.content,
        swipes: node.siblings.count, snapshot: node.prompt_snapshot_hash,
        created_at: node.created_at
      }
    end
  end
end
