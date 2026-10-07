module Sentinel
  module Native
    # text.poll: what arrived since the agent last looked. hob keeps no place
    # for it: the cursor is the agent's to keep.
    class TextPoll < TextHandler
      CAPABILITY = {
        "name" => "text.poll",
        "description" => "New texts since you last looked: messages that arrived after `cursor`, oldest first, optionally only " \
                         "those matching a filter. Call it once without a cursor to get one (and no messages), then keep the " \
                         "cursor each answer returns and give it next time; hob does not remember it for you. Only incoming " \
                         "messages unless include_sent; a tapback or an edit is not a new message. `more: true` means ask again " \
                         "now. Returns { cursor, messages: [#{MESSAGE_SHAPE}], count, more, unavailable, notice }. Pair it with " \
                         "hob.schedule.create to look on a clock.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "cursor" => { "type" => "string", "description" => "What the last text.poll returned as `cursor`. Leave it out the first time" },
            "backend" => BACKEND,
            "chat" => CHAT.merge("description" => "Only what arrived in this chat: #{CHAT['description']}"),
            "from" => { "type" => "string", "description" => "The sender's number, address, or contact name, in part" },
            "q" => { "type" => "string", "description" => "Words that must all appear in the text" },
            "include_sent" => { "type" => "boolean", "default" => false, "description" => "true: the household's own messages too" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Texts.poll(arguments))
      end
    end
  end
end
