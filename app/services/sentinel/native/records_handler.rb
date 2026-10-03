module Sentinel
  module Native
    # What the records.* handlers share (RECORDS.md). They are thin: Records
    # does the work, at the agent's clearance, so the collections an agent
    # can reach are the ones RLS shows it. Who writes is the request's
    # principal and surface, never an argument. Everything handed back
    # carries Records::NOTICE: a record is what a page said.
    class RecordsHandler < Base
      COLLECTION = { "type" => "string", "description" => "The collection's name, as records.collections lists it" }.freeze
      KEY = { "type" => %w[string integer], "description" => "The record's key: the value of its collection's key field" }.freeze
      REASON = { "type" => "string", "maxLength" => Records::REASON_LIMIT,
                 "description" => "Why, in a sentence or two: the person deciding reads it" }.freeze
      DATA = { "type" => "object",
               "description" => "The document: a JSON object holding the collection's key field, meeting its schema, at most 64 KB" }.freeze
      LINKS = { "type" => "array", "maxItems" => Records::LINKS_LIMIT,
                "items" => { "type" => "string", "pattern" => "^(#{Records::REF_KINDS.join('|')}):\\S+$" },
                "description" => "Refs to what this record is about: rec:<collection>:<key>, budget:<backend>:<id>, " \
                                 "todo:<backend>:<id>, mise:recipe:<id>, board:<thread>, mission:<id>. Replaces the set; " \
                                 "left out, the links already there stay" }.freeze
      SOURCE = { "type" => "string", "maxLength" => Records::SOURCE_LIMIT, "description" => "Where you read it: a URL, usually" }.freeze
      OBSERVED_AT = { "type" => "string", "description" => "ISO 8601: when the thing was seen this way, if not now" }.freeze
      SCHEMA = { "type" => %w[object null], "description" => "A JSON Schema every document must meet; null for none" }.freeze
      RECORD = "{ id: \"rec:<collection>:<key>\", collection, key, data, links, version, schema_version, observed_at, source, " \
               "written_by: { principal, surface }, created_at, updated_at }".freeze

      private

      def writer
        Records::Writer.from(request)
      end

      # The person who said yes: the one who confirmed an agent's request,
      # or the person calling (Mcp), who needs no one's confirmation.
      def person
        decider = request.respond_to?(:decider) ? request.decider : nil
        return decider if decider&.trusted?

        request.principal if request.principal&.trusted?
      end

      def agent
        request.principal if request.principal&.agent?
      end

      def noticed(result)
        result.merge("notice" => Records::NOTICE)
      end
    end
  end
end
