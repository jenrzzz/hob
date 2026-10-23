module Sentinel
  module Native
    # What the ward.threat* handlers share (THREATS.md). Thin: Ward::Threats
    # does the work. Who reported, noted, or decided is the request's
    # principal (or, for what only a person may approve, the person who
    # confirmed it), never an argument.
    class WardThreatHandler < Base
      THREAT = { "type" => "string", "description" => "A threat's id, from ward.threats" }.freeze
      REASON = { "type" => "string", "maxLength" => Ward::Threats::REASON_LIMIT,
                 "description" => "The person's reason, in a sentence or two: it is kept on the threat" }.freeze
      THREAT_JSON = "{ id, kind, title, status, cve_ids, component, fixed_versions, claimed_severity, assessed_severity, " \
                    "confidence, exploited, actor, target, sources, reported_by, affected: [{ name, host, component, version, " \
                    "verdict, exposure }], posture, proposals, gotchas, upstream, resolution, expires_at, history? }".freeze

      private

      def threat!
        WardThreat.find_by(id: require_argument(:threat).to_s.strip) || raise(Error, "no threat #{arguments['threat'].inspect}")
      end

      # Who decided a person-confirmed request: the person who confirmed it,
      # or the person calling (Mcp), who needs no one's confirmation.
      def decider
        decider = request.respond_to?(:decider) ? request.decider : nil
        decider&.trusted? ? decider : request.principal
      end

      def answer(threat, **extra)
        { "threat" => threat.as_json_for_ward }.merge(extra.transform_keys(&:to_s)).merge("notice" => Ward::Threats::NOTICE)
      end

      def invalid!
        yield
      rescue Ward::Invalid, ArgumentError => e
        raise Error, e.message
      end
    end
  end
end
