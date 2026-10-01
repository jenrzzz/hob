# The ward's hourly sweep (WARD.md), from config/recurring.yml: what the
# Coolify scheduled task running `hob:ward:sweep` did before hob had a clock.
class WardSweepJob < ApplicationJob
  queue_as :default

  def perform
    Clearance.with("intimate") do
      Current.set(surface: Ward::SURFACE) { Ward::Sweep.call }
    end
  end
end
