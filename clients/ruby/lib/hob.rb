require "json"
require_relative "hob/version"
require_relative "hob/errors"
require_relative "hob/record"
require_relative "hob/completion"
require_relative "hob/turn"
require_relative "hob/conversation"
require_relative "hob/usage"
require_relative "hob/http"
require_relative "hob/conversations"
require_relative "hob/client"
require_relative "hob/fake"

# hob — the household spirit that does the chores overnight, keeps the pots
# warm beside the fire, and knows everything about the house — provided you
# leave the milk out.
#
#   hob = Hob::Client.new(base: ENV["HOB_URL"], key: ENV["HOB_KEY"])
#   hob.complete(role: "extractor", messages: [{ role: "user", content: text }], schema: SCHEMA).parsed
#
# Apps inject the client so tests can swap in Hob::Fake:
#
#   Llm.client = Hob::Fake.new.reply("Hello.")
module Hob
end
