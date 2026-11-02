# A refresh no person asked for (PLUGINS.md, section 1): queued when a plugin
# installation announces itself (V1::PluginAnnouncementsController). It
# re-reads and verifies the signed manifest; what it adds waits for a person
# to accept it, and a person is told.
class PluginRefreshJob < ApplicationJob
  queue_as :default

  def perform(namespace)
    result = SurfaceCapabilities.new.refresh(surface: namespace, automatic: true)
    Rails.logger.info("plugins: #{namespace} refreshed: #{result.created} new, #{result.updated} updated, #{result.disabled} disabled")
  rescue SurfaceCapabilities::Error => e
    # A refused manifest (a bad signature, an old revision) after a ping
    # that verified is worth a person's look, not just a log line.
    Rails.logger.warn("plugins: #{namespace} was not refreshed: #{e.message}")
    Notify.person(title: "hob: #{namespace} asked to be refreshed, and was refused", body: e.message, tags: "warning")
  end
end
