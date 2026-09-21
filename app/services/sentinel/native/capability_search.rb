module Sentinel
  module Native
    # hob.capability.search: keyword search over the capability catalog, filtered
    # to the calling agent's clearance. Name matches rank above description
    # matches. Policy internals (effects, constraints, limits, who holds what)
    # are never returned; capabilities above the caller's clearance are dropped
    # before scoring so they are not counted or hinted at.
    class CapabilitySearch < Base
      CAPABILITY = {
        "name" => "hob.capability.search",
        "description" => "Keyword search over hob's capability catalog: given a query, returns matching " \
                         "capabilities with name, description, kind, realm, and whether the calling agent " \
                         "may petition for each, ranked by relevance and filtered to the caller's clearance.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "required" => [ "query" ],
          "properties" => {
            "query" => {
              "type" => "string",
              "minLength" => 1,
              "maxLength" => 120,
              "description" => "Keywords matched against capability name and description."
            },
            "limit" => {
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 25,
              "default" => 20
            }
          },
          "additionalProperties" => false
        }
      }.freeze

      NOTICE = "Filtered to your clearance (%s)."
      DEFAULT_LIMIT = 20
      MAX_LIMIT = 25

      def call
        query = require_argument(:query)
        raise Error, "query exceeds 120 characters" if query.length > 120

        limit = (arguments["limit"] || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)

        caller_clearance = Current.clearance
        caller_rank = Realm.rank_of(caller_clearance)
        caller_principal = Current.principal

        visible = Capability.enabled.select { |cap| Realm.rank_of(cap.realm) <= caller_rank }

        # Preload the caller's policies once to avoid N+1 on already_held? checks.
        policies = SentinelPolicy.where(principal_id: [ caller_principal.id, nil ]).to_a

        tokens = query.downcase.split(/\s+/).uniq.reject(&:empty?)

        scored = visible.filter_map do |cap|
          score = score_capability(cap, query.downcase, tokens)
          next if score.zero?

          [ cap, score ]
        end

        total_matched = scored.size

        results = scored.sort_by { |cap, score| [ -score, cap.name ] }
                        .first(limit)
                        .map { |cap, _| serialize(cap, caller_rank, policies) }

        { "results" => results, "total_matched" => total_matched, "notice" => format(NOTICE, caller_clearance) }
      end

      private

      def score_capability(cap, query_lower, tokens)
        name_lower = cap.name.downcase
        desc_lower = cap.description.downcase

        score = 0

        score += 4 if name_lower.include?(query_lower)
        score += 2 if desc_lower.include?(query_lower)

        tokens.each do |token|
          score += 2 if name_lower.include?(token)
          score += 1 if desc_lower.include?(token)
        end

        score
      end

      def serialize(cap, caller_rank, policies)
        held = held?(cap.name, policies)
        {
          "kind" => cap.kind,
          "name" => cap.name,
          "realm" => cap.realm,
          "description" => cap.description,
          "already_held" => held,
          "petitionable" => !held && Realm.rank_of(cap.realm) <= caller_rank
        }
      end

      def held?(capability_name, policies)
        rule = policies
               .select { |p| p.matches?(capability_name) }
               .max_by { |p| [ p.principal_id ? 1 : 0, p.specificity ] }
        rule.present? && rule.effect != "deny"
      end
    end
  end
end
