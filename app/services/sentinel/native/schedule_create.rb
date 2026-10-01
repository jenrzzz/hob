module Sentinel
  module Native
    # hob.schedule.create (SCHEDULES.md): ask hob to queue a mission on a
    # cadence, for the agent itself or for a principal that polls for work.
    # The same name again replaces that schedule rather than adding one, so
    # an agent can re-run its own setup. Missions go out at the request's
    # realm; an agent's schedule fires at most every 15 minutes, and it may
    # keep 25.
    class ScheduleCreate < Base
      CAPABILITY = {
        "name" => "hob.schedule.create",
        "description" => "Have hob queue a mission on a schedule: a cron line (\"0 7 * * 1-5\") or plain words " \
                         "(\"every day at 7am\") in a time zone, and the mission each firing queues for its assignee " \
                         "(yourself, by default). A firing is skipped while the last mission it queued is still open. " \
                         "Reusing a name replaces that schedule.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "required" => %w[name cron title],
          "properties" => {
            "name" => { "type" => "string", "description" => "lowercase, digits, '.', '_' or '-'; yours to reuse or cancel by" },
            "cron" => { "type" => "string", "description" => "a cron line or fugit words; at most every 15 minutes" },
            "time_zone" => { "type" => "string", "description" => "IANA zone the cron line is read in (default Etc/UTC)" },
            "assignee" => { "type" => "string", "description" => "principal name; default yourself" },
            "title" => { "type" => "string" }, "brief" => { "type" => "string" },
            "payload" => { "type" => "object" }, "priority" => { "type" => "integer" },
            "description" => { "type" => "string", "description" => "what it is for, for the person reading the list" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        agent = request.principal
        assignee = arguments["assignee"].present? ? Principal.find_by(name: arguments["assignee"]) : agent
        raise Error, "no principal #{arguments['assignee']}" if assignee.nil?

        schedule = Schedule.find_or_initialize_by(created_by: agent, name: require_argument(:name).to_s.strip)
        if schedule.new_record? && Schedule.where(created_by: agent).count >= Schedule::MAX_PER_AGENT
          raise Error, "#{agent.name} already has #{Schedule::MAX_PER_AGENT} schedules; cancel one first"
        end

        updated = schedule.persisted?
        schedule.assign_attributes(
          cron: require_argument(:cron).to_s.strip, time_zone: arguments["time_zone"].presence || "Etc/UTC",
          assignee: assignee, realm: request.realm, title: require_argument(:title),
          brief: arguments["brief"].presence, payload: arguments["payload"].is_a?(Hash) ? arguments["payload"] : {},
          priority: arguments["priority"].to_i, description: arguments["description"].to_s, enabled: true
        )
        raise Error, schedule.errors.full_messages.to_sentence unless schedule.save

        schedule.as_json_for_hob.merge("updated" => updated)
      end
    end
  end
end
