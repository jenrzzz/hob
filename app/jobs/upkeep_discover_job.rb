# Upkeep discovery (SCHEDULES.md), weekly from config/recurring.yml: give
# every household repo Coolify runs its upkeep schedules, and disable the
# ones whose repo is gone. Quiet without Coolify configured.
class UpkeepDiscoverJob < ApplicationJob
  queue_as :default

  def perform
    return Rails.logger.info("upkeep: COOLIFY_URL/COOLIFY_TOKEN not set; nothing discovered") if ENV["COOLIFY_URL"].blank? || ENV["COOLIFY_TOKEN"].blank?

    Clearance.with("intimate") do
      report = Upkeep.discover!
      Rails.logger.info("upkeep: #{report.repos.size} repo(s); created #{report.created.inspect}, updated #{report.updated.inspect}, disabled #{report.disabled.inspect}")
      report
    end
  end
end
