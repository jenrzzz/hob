# People's derivation (PEOPLE.md), from config/recurring.yml: read every text
# backend's stream since the last run and turn what arrived and what was sent
# into events and loops. Quiet when no text backend is registered.
class PeopleSyncJob < ApplicationJob
  queue_as :default

  def perform
    Clearance.with("intimate") do
      Current.set(surface: People::Sync::SURFACE) do
        People::Sync.run!.each { |report| Rails.logger.info("people: #{report}") }
      end
    end
  end
end
