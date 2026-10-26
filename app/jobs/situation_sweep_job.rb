# Situation is weather, not memory. Remove observations after the bounded
# retention window; runs at full clearance so every realm is swept.
class SituationSweepJob < ApplicationJob
  queue_as :default

  def perform
    Clearance.with("intimate") do
      Current.set(surface: "situation-sweep") { Situation.sweep! }
    end
  end
end
