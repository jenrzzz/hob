# A chat-authorization claim an agent attaches to a request (SENTINEL.md,
# "User-authorization claims"): the agent says the user already authorized
# this in chat, and quotes the message. hob cannot cryptographically verify
# a quote, so this row is the audit trail — logged for every claim handed to
# the sentinel, whether or not it ended up mattering, and the decision it
# drove. Never deleted, like sentinel_requests and guidance_changes.
#
#   status   rejected       intake failed (missing field, stale quote, unknown agent): ignored, as if absent
#            unused         intake passed, but the rule's effect never needed a claim to skip the person's tap
#            insufficient   the rubric failed a check: escalated to a person, exactly as without a claim
#            backed         the rubric passed and no spot-check fired: the claim let the request skip the tap
#            spot_checked   the rubric passed but a spot-check fired: pending, same as a `confirm` escalation,
#                           its rationale quoting the claim back for the person to say yes or no to
#            confirmed      a spot-checked claim the person allowed
#            declined       a spot-checked claim the person denied without saying the quote was false:
#                           they didn't want it done, no trust consequence
#            fabricated     a spot-checked claim the person said they never made: the agent is frozen
#
#   realm    the request's, so the quote is no more visible than the request it backs (RLS)
class AuthorizationClaim < ApplicationRecord
  STATUSES = %w[rejected unused insufficient backed spot_checked confirmed declined fabricated].freeze

  belongs_to :principal
  belongs_to :sentinel_request

  validates :status, inclusion: { in: STATUSES }

  before_create { self.id ||= ULID.generate }

  scope :recent, -> { order(created_at: :desc) }

  # Whether a person's decision on the request this claim backs is still
  # awaited to settle the claim too (Sentinel.decide!): true only between a
  # spot-check firing and the person's tap.
  def spot_checked?
    status == "spot_checked"
  end
end
