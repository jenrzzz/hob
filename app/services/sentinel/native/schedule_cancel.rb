module Sentinel
  module Native
    # hob.schedule.cancel (SCHEDULES.md): an agent ends a schedule it made.
    # Missions already queued stay queued; the schedule just stops firing.
    class ScheduleCancel < Base
      CAPABILITY = {
        "name" => "hob.schedule.cancel",
        "description" => "Cancel a schedule you created, by name. Missions it already queued are left alone.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "required" => %w[name],
          "properties" => { "name" => { "type" => "string" } },
          "additionalProperties" => false
        }
      }.freeze

      def call
        schedule = Schedule.find_by(created_by: request.principal, name: require_argument(:name).to_s.strip)
        raise Error, "you have no schedule named #{arguments['name'].inspect}" if schedule.nil?

        schedule.destroy!
        { "cancelled" => schedule.name, "fired_count" => schedule.fired_count }
      end
    end
  end
end
