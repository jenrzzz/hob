module Sentinel
  module Native
    # hob.schedule.list (SCHEDULES.md): the schedules an agent made, and the
    # ones that queue missions for it, at the request's clearance.
    class ScheduleList < Base
      CAPABILITY = {
        "name" => "hob.schedule.list",
        "description" => "List the schedules you created and the ones that queue missions for you: cron line, " \
                         "next and last firing, the mission each queues, and how many firings were skipped.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => { "type" => "object", "properties" => {}, "additionalProperties" => false }
      }.freeze

      def call
        agent = request.principal
        schedules = Schedule.where(created_by: agent).or(Schedule.where(assignee: agent)).includes(:assignee, :created_by).order(:name)
        { "schedules" => schedules.map(&:as_json_for_hob) }
      end
    end
  end
end
