# The pulse of every channel that has one (Irc::Pulse, IRC.md, "The
# pulse"): a room gone quiet, or gone round in the same two voices, wakes
# its host to bring it something.
class IrcPulseJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "irc_pulse"

  def perform(now: Time.current)
    Irc::Pulse.sweep(now: now).each do |name, outcome|
      Rails.logger.info("irc pulse #{name}: #{outcome}") unless outcome == :fine
    end
  end
end
