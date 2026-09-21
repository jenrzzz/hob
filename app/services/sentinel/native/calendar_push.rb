module Sentinel
  module Native
    # hob.calendar.push: the ingest half of the household calendar bouncer
    # (SENTINEL.md; petition 01M3198JPT3TGXX53S9M2NYCEG). An agent pushes a
    # batch of normalized events for one household member's calendar; hob
    # upserts them into the calendar mirror, keyed by
    # (source_agent, owner, calendar, uid). Title and location are dropped
    # at write time unless the push's visibility is "details", and a push
    # is refused outright unless the calling agent is a registered
    # CalendarContributor for the named owner. No provider integration, no
    # credentials, no outbound calls, no read path: availability queries
    # are a separate capability and a separate decision.
    class CalendarPush < Base
      CAPABILITY = {
        "name" => "hob.calendar.push",
        "description" => "Accept a batch of normalized calendar events pushed by an agent and store them in hob's " \
                         "household calendar mirror, each tagged with its owner, source agent, and visibility " \
                         "(free/busy by default). Returns how many events were stored, updated, or rejected.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "required" => %w[owner events],
          "properties" => {
            "owner" => { "type" => "string", "description" => "Household member whose calendar these events belong to." },
            "calendar" => { "type" => "string", "description" => "Free-form label for the source calendar, e.g. 'work' or 'family'." },
            "visibility" => { "enum" => %w[free_busy details], "type" => "string", "default" => "free_busy" },
            "events" => {
              "type" => "array",
              "maxItems" => 200,
              "items" => {
                "type" => "object",
                "required" => %w[uid start end],
                "properties" => {
                  "uid" => { "type" => "string" },
                  "start" => { "type" => "string", "format" => "date-time" },
                  "end" => { "type" => "string", "format" => "date-time" },
                  "all_day" => { "type" => "boolean" },
                  "busy" => { "type" => "boolean", "default" => true },
                  "status" => { "enum" => %w[confirmed tentative cancelled], "type" => "string" },
                  "title" => { "type" => "string", "maxLength" => 200 },
                  "location" => { "type" => "string", "maxLength" => 200 }
                },
                "additionalProperties" => false
              }
            },
            "replace_window" => {
              "type" => "object",
              "description" => "If given, events previously pushed by this agent for this owner and calendar within " \
                               "the window that are not in this batch are removed.",
              "properties" => {
                "start" => { "type" => "string", "format" => "date-time" },
                "end" => { "type" => "string", "format" => "date-time" }
              },
              "additionalProperties" => false
            }
          },
          "additionalProperties" => false
        }
      }.freeze

      MAX_EVENTS = 200
      MAX_SPAN = 30.days
      STATUSES = %w[confirmed tentative cancelled].freeze

      def call
        owner = owner!(require_argument(:owner))
        contributor!(owner)
        calendar = arguments["calendar"].presence&.to_s || ""
        visibility = visibility!

        stored = updated = 0
        rejected = []
        pushed_uids = []

        events!.each do |raw|
          uid = raw.is_a?(Hash) ? raw["uid"].to_s : ""
          pushed_uids << uid if uid.present?

          problem = event_problem(raw)
          if problem
            rejected << { "uid" => uid.presence || "(missing)", "reason" => problem }
            next
          end

          record = CalendarEvent.find_or_initialize_by(source_agent: request.principal, owner: owner, calendar: calendar, uid: uid)
          was_new = record.new_record?
          record.assign_attributes(
            start_at: Time.zone.parse(raw["start"]), end_at: Time.zone.parse(raw["end"]),
            all_day: raw.fetch("all_day", false), busy: raw.fetch("busy", true), status: raw["status"],
            visibility: visibility, title: visibility == "details" ? raw["title"] : nil,
            location: visibility == "details" ? raw["location"] : nil
          )
          record.save!
          was_new ? stored += 1 : updated += 1
        end

        removed = arguments["replace_window"].present? ? replace_window!(owner, calendar, pushed_uids) : 0

        result = { "owner" => owner.name, "calendar" => calendar, "visibility" => visibility,
                   "stored" => stored, "updated" => updated, "removed" => removed, "rejected" => rejected }
        result["notice"] = "titles dropped: visibility is free_busy" if visibility == "free_busy"
        result
      end

      private

      def owner!(name)
        principal = Principal.find_by(name: name.to_s)
        raise Error, "#{name} is not a known household member" if principal.nil? || !principal.trusted?

        principal
      end

      def contributor!(owner)
        return if CalendarContributor.exists?(owner: owner, agent: request.principal)

        raise Error, "#{request.principal.name} is not a registered contributor for #{owner.name}'s calendar"
      end

      def visibility!
        value = arguments["visibility"].presence || "free_busy"
        unless CalendarEvent::VISIBILITIES.include?(value)
          raise Error, "visibility must be one of #{CalendarEvent::VISIBILITIES.join(', ')}, got #{value.inspect}"
        end

        value
      end

      def events!
        events = arguments["events"]
        raise Error, "events must be an array" unless events.is_a?(Array)
        raise Error, "events exceeds #{MAX_EVENTS}" if events.size > MAX_EVENTS

        events
      end

      # nil when the event is fine to store; otherwise the rejection reason.
      def event_problem(raw)
        return "must be an object" unless raw.is_a?(Hash)
        return "missing uid" if raw["uid"].blank?

        start_time = parse_time(raw["start"])
        end_time = parse_time(raw["end"])
        return "start and end must be date-times" if start_time.nil? || end_time.nil?
        return "end before start" if end_time < start_time
        return "spans more than #{MAX_SPAN.in_days.to_i} days" if (end_time - start_time) > MAX_SPAN
        return "status must be one of #{STATUSES.join(', ')}" if raw["status"].present? && !STATUSES.include?(raw["status"])

        nil
      end

      def parse_time(value)
        value.is_a?(String) ? Time.zone.parse(value) : nil
      rescue ArgumentError
        nil
      end

      # Deletes this agent's previously stored events for owner+calendar
      # that started inside the window and were not resubmitted just now
      # (whether they were accepted or rejected this time: a malformed
      # resubmission should not wipe out the good copy already on file).
      def replace_window!(owner, calendar, pushed_uids)
        window = arguments["replace_window"]
        raise Error, "replace_window must be an object" unless window.is_a?(Hash)

        from = parse_time(window["start"]) || Time.zone.at(0)
        to = parse_time(window["end"]) || 100.years.from_now
        scope = CalendarEvent.where(source_agent: request.principal, owner: owner, calendar: calendar, start_at: from..to)
        scope = scope.where.not(uid: pushed_uids) if pushed_uids.any?
        count = scope.count
        scope.delete_all
        count
      end
    end
  end
end
