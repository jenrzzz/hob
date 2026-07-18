module V1
  # The inspector: what exactly did the model see? RLS gates visibility.
  class SnapshotsController < ApplicationController
    def show
      snapshot = PromptSnapshot.find(params[:id])
      render json: {
        hash: snapshot.digest, conversation: snapshot.conversation_id,
        assembled: snapshot.assembled, created_at: snapshot.created_at
      }
    end
  end
end
