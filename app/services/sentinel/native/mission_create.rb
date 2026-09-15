module Sentinel
  module Native
    # hob.mission.create: hand work to another principal that polls for it —
    # an agent asking a surface's worker (or another agent) to do something.
    class MissionCreate < Base
      CAPABILITY = {
        "name" => "hob.mission.create",
        "description" => "Queue a mission for a principal that polls hob for work: a title, a brief, and a payload. " \
                         "The result comes back on the mission.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "assignee" => { "type" => "string", "description" => "principal name" },
            "title" => { "type" => "string" }, "brief" => { "type" => "string" },
            "payload" => { "type" => "object" }, "priority" => { "type" => "integer" }
          },
          "required" => %w[assignee title]
        }
      }.freeze

      def call
        assignee = Principal.find_by(name: require_argument(:assignee))
        raise Error, "no principal #{arguments['assignee']}" if assignee.nil?
        if Realm.rank_of(assignee.max_clearance) < Realm.rank_of(request.realm)
          raise Error, "#{assignee.name} cannot see #{request.realm} missions"
        end

        mission = Mission.create!(
          assignee: assignee, created_by: request.principal, title: require_argument(:title),
          brief: arguments["brief"].presence, payload: arguments["payload"].is_a?(Hash) ? arguments["payload"] : {},
          priority: arguments["priority"].to_i, realm: request.realm
        )
        { "id" => mission.id, "assignee" => assignee.name, "title" => mission.title, "status" => mission.status }
      end
    end
  end
end
