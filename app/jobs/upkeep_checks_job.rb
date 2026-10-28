# The red-branch watch (SCHEDULES.md, "Upkeep"), every quarter hour from
# config/recurring.yml: queue a forge fix for each kept repo whose branch
# failed its checks. Quiet without HOB_GITHUB_TOKEN.
class UpkeepChecksJob < ApplicationJob
  queue_as :default

  def perform
    return Rails.logger.info("upkeep: HOB_GITHUB_TOKEN not set; no checks read") unless Upkeep::Checks.configured?

    Clearance.with("intimate") do
      report = Upkeep::Checks.watch!
      Rails.logger.info("upkeep checks: #{report.checked.inspect}; queued fixes #{report.queued.inspect}#{"; errors #{report.errors.inspect}" if report.errors.any?}")
      report
    end
  end
end
