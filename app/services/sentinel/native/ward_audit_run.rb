module Sentinel
  module Native
    # ward.audit.run (WARD.md): ask for a check to run now rather than on
    # its schedule. hob queues a `ward.audit` mission for the ward worker;
    # the worker leases it, runs the check, posts the report, and the result
    # arrives the usual way (findings, triage, a ping). One at a time per
    # check: a run already queued or leased is the answer.
    class WardAuditRun < Base
      CAPABILITY = {
        "name" => "ward.audit.run",
        "description" => "Queue an out-of-schedule run of a ward check (for example \"exposure\", the full TCP and " \
                         "route audit). Returns the mission the ward worker will lease; the report, its findings, " \
                         "and the triage follow when the run finishes.",
        "kind" => "act",
        "realm" => "personal",
        "input_schema" => {
          "type" => "object",
          "required" => %w[check],
          "properties" => {
            "check" => { "type" => "string", "description" => "The check's slug, as ward.status lists them" },
            "reason" => { "type" => "string", "maxLength" => 200, "description" => "Why now; goes on the mission for the worker's log" }
          },
          "additionalProperties" => false
        }
      }.freeze

      KIND = "ward.audit".freeze

      def call
        check = WardCheck.find_by(slug: require_argument(:check).to_s.strip)
        raise Error, "no ward check named #{arguments['check'].inspect}" if check.nil?
        raise Error, "#{check.slug} is disabled" unless check.enabled?

        worker = Principal.find_by(name: ENV.fetch("HOB_WARD_PRINCIPAL", "ward"), kind: "worker")
        raise Error, "no ward worker is set up (bin/rails \"hob:ward:setup[ward]\")" if worker.nil?

        if (open = Mission.open.for(worker).where("payload->>'kind' = ? AND payload->>'check' = ?", KIND, check.slug).first)
          return { "mission" => open.id, "status" => open.status, "check" => check.slug, "queued_before" => true }
        end

        mission = Mission.create!(
          assignee: worker, created_by: request.principal, title: "ward: run #{check.slug}",
          brief: arguments["reason"].to_s.strip.truncate(200).presence,
          payload: { "kind" => KIND, "check" => check.slug, "request" => request.id }, realm: "personal"
        )
        { "mission" => mission.id, "status" => mission.status, "check" => check.slug }
      end
    end
  end
end
