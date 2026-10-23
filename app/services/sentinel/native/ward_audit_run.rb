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

        mission, queued_before = Ward.queue_audit!(check, by: request.principal, reason: arguments["reason"], request: request.id)
        { "mission" => mission.id, "status" => mission.status, "check" => check.slug, "queued_before" => queued_before || nil }.compact
      rescue Ward::Invalid => e
        raise Error, e.message
      end
    end
  end
end
