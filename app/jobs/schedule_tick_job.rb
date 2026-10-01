# The clock's tick (SCHEDULES.md): every minute, from config/recurring.yml,
# fire whatever schedules are due. Runs at the top clearance, as hob itself,
# since a schedule's missions are realm-scoped rows like any other.
class ScheduleTickJob < ApplicationJob
  queue_as :default

  def perform
    Clearance.with("intimate") do
      Current.set(surface: "schedule") { Schedule.tick! }
    end
  end
end
