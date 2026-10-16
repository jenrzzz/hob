module Sentinel
  module Native
    # people.groups: circles and group chats, with who is in them.
    class PeopleGroups < PeopleHandler
      CAPABILITY = {
        "name" => "people.groups",
        "description" => "The groups people are in: circles someone named (family) and group chats hob has seen (chat: the " \
                         "text chat's id). Returns { groups: [{ id, ref, name, chat, realm, whose, members: [{ id, " \
                         "display_name }] }], count, notice }.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "q" => { "type" => "string", "description" => "Words in the group's name" },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => People::MAX_LIMIT, "description" => "Default 50" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        People.groups(arguments)
      end
    end
  end
end
