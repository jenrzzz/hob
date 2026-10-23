module Sentinel
  module Native
    # What the people.* handlers share (PEOPLE.md). They are thin: People
    # does the work, at the agent's clearance, so the people an agent can
    # reach are the ones RLS shows it. Who writes is the request's principal
    # and surface, never an argument.
    class PeopleHandler < Base
      PERSON = { "type" => "string",
                 "description" => "Who: a person's id (from people.list), or a phone number or email address they use" }.freeze
      GROUP = { "type" => "string", "description" => "A group's id (from people.groups), or its exact name" }.freeze
      LOOP = { "type" => "string", "description" => "A loop's id, from people.loops or people.get" }.freeze
      REASON = { "type" => "string", "maxLength" => People::REASON_LIMIT,
                 "description" => "Why, in a sentence or two: the person deciding reads it" }.freeze
      REALM = { "type" => "string",
                "description" => "household, personal, or intimate: where this is visible. Default: your clearance; never below the person's own" }.freeze
      WHOSE = { "type" => "string", "description" => "Whose relationship this is: a household person's name (jenner). Default: the person's" }.freeze
      HANDLES = { "type" => "array", "maxItems" => People::HANDLES_LIMIT,
                  "items" => { "anyOf" => [ { "type" => "string" },
                                            { "type" => "object", "properties" => { "address" => { "type" => "string" },
                                                                                    "kind" => { "enum" => PersonHandle::KINDS },
                                                                                    "label" => { "type" => "string" } },
                                              "required" => %w[address], "additionalProperties" => false } ] },
                  "description" => "Phone numbers and email addresses: \"+15551234567\", or { address, kind?, label? }" }.freeze
      CIRCLES = { "type" => "array", "items" => { "type" => "string" }, "maxItems" => People::CIRCLES_LIMIT,
                  "description" => "Group names, like [\"family\", \"biker gang\"]; a name no group has makes one" }.freeze
      KEY_DATES = { "type" => "array", "maxItems" => Person::KEY_DATES_LIMIT,
                    "items" => { "type" => "object",
                                 "properties" => { "kind" => { "enum" => Person::KEY_DATE_KINDS },
                                                   "date" => { "type" => "string", "description" => "YYYY-MM-DD, or --MM-DD without a year" },
                                                   "recurs" => { "type" => "boolean", "description" => "Comes round every year (default true)" },
                                                   "label" => { "type" => "string" } },
                                 "required" => %w[kind date], "additionalProperties" => false },
                    "description" => "Birthdays, anniversaries: the whole set" }.freeze
      PERSON_JSON = "{ id, ref, display_name, names, handles: [{ kind, address, label, opens_loops }], circles, key_dates, " \
                    "automated, cadence_days, realm, whose, created_at, updated_at }".freeze
      LOOP_JSON = "{ id, person: { id, display_name }, group, kind, channel, summary, state, opened_at, age_days, opened_by, " \
                  "latest_event, closed_by, closed_at, snoozed_until, whose, realm }".freeze
      EVENT_JSON = "{ id, person, group, at, kind, direction, channel, summary, source: { kind, ref, by, surface }, whose, realm }".freeze

      private

      def writer
        People::Writer.from(request)
      end

      # Who decided a person-confirmed request: the person who confirmed it,
      # or the person calling (Mcp), who needs no one's confirmation.
      def decider_writer
        decider = request.respond_to?(:decider) ? request.decider : nil
        principal = decider&.trusted? ? decider : request.principal
        People::Writer.new(principal: principal, surface: request.surface, request_id: request.id)
      end

      def noticed(result)
        result.merge("notice" => People::NOTICE)
      end
    end
  end
end
