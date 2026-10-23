# The ward's hourly sweep (WARD.md), from config/recurring.yml: what the
# Coolify scheduled task running `hob:ward:sweep` did before hob had a clock.
# Then the threats' clock (THREATS.md): the inventory from Coolify, and the
# resolver over every open threat.
class WardSweepJob < ApplicationJob
  queue_as :default

  def perform
    Clearance.with("intimate") do
      Current.set(surface: Ward::SURFACE) do
        Ward::Sweep.call
        Ward.threat_upkeep!
      end
    end
  end
end
