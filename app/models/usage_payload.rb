# What a metered call said, kept beside its ledger row and filtered by realm
# like the prompt snapshot it answers. One per usage_event, written by the
# gateway with the event; never rewritten.
#
# response: { content, reasoning, tool_calls: [{ id, name, arguments }] }
# request:  { system, messages, tools, schema } — only when the call carried
#           no prompt snapshot to hold it
class UsagePayload < ApplicationRecord
  self.primary_key = :usage_event_id

  belongs_to :usage_event

  def response_content = response&.dig("content")
  def reasoning = response&.dig("reasoning")
  def tool_calls = Array(response&.dig("tool_calls"))
end
