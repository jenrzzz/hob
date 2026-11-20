module Hob
  # /v1/conversations: git for chat. Branches are refs; nothing is destroyed.
  class Conversations
    def initialize(http)
      @http = http
    end

    def create(title: nil, realm: nil)
      Conversation.new(@http.post("/v1/conversations", { title: title, realm: realm }.compact))
    end

    # kind: chat (default) | pipeline | all
    def list(kind: nil)
      @http.get("/v1/conversations", { kind: kind }).map { |c| Conversation.new(c) }
    end

    def show(id, branch: nil)
      Conversation.new(@http.get("/v1/conversations/#{id}", { branch: branch }))
    end

    def branches(id)
      @http.get("/v1/conversations/#{id}/branches")
    end

    # A new ref at an existing node.
    def fork(id, name:, at:)
      @http.post("/v1/conversations/#{id}/branches", { name: name, at: at })
    end

    # Move a ref: how swipe cycling activates an older sibling.
    def set_head(id, head:, branch: "main")
      @http.patch("/v1/conversations/#{id}/branches/#{branch}", { head: head })
    end

    def siblings(id, hash)
      @http.get("/v1/conversations/#{id}/nodes/#{hash}/siblings")
    end

    # Follow a conversation: the branch's nodes after `after`, waiting up to
    # `wait` seconds (≤ 30) for the head to move. Without `after`, just the
    # head to follow from. -> { "head", "nodes" => [...], "missing"? }; on
    # missing (after left the branch), follow on from the head. Follow on
    # from the last node returned, not the head: a page holds at most 50.
    def follow(id, after: nil, wait: nil, branch: nil)
      @http.get("/v1/conversations/#{id}/nodes", { after: after, wait: wait, branch: branch })
    end

    # A surface's side effect in the timeline, out of the prompt (B6).
    def event(id, content:, branch: nil, meta: nil)
      @http.post("/v1/conversations/#{id}/events", { content: content, branch: branch, meta: meta }.compact)
    end
  end
end
