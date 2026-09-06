module Hob
  # A conversation as GET /v1/conversations/:id returns it; `messages` is the
  # requested branch's timeline when the call asked for one.
  class Conversation < Record
    attribute :id, :kind, :surface, :title, :realm, :taint_realm, :branches, :branch, :messages, :updated_at
  end
end
