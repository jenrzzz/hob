module Sentinel
  # The native venue: capabilities hob fulfils in-process. A handler declares
  # what it is (CAPABILITY) and does it (#call → a JSON-able Hash). Adding
  # one is a class here plus `Sentinel::Native.sync!` (seeds run it), which
  # upserts the Capability row policies refer to.
  module Native
    class Error < StandardError; end

    HANDLERS = {
      "complete" => "Sentinel::Native::Complete",
      "usage" => "Sentinel::Native::Usage",
      "conversations_list" => "Sentinel::Native::ConversationsList",
      "conversation_read" => "Sentinel::Native::ConversationRead",
      "conversation_event" => "Sentinel::Native::ConversationEvent",
      "mission_create" => "Sentinel::Native::MissionCreate"
    }.freeze

    module_function

    def handler(name)
      HANDLERS[name.to_s]&.constantize
    end

    def handlers
      HANDLERS.transform_values(&:constantize)
    end

    # Upsert a Capability row per handler. Description and schema follow the
    # code; realm, kind, and enabled are left alone once a row exists so a
    # household can tune them.
    def sync!
      handlers.map do |key, klass|
        spec = klass::CAPABILITY
        Capability.find_or_initialize_by(name: spec["name"]).tap do |cap|
          cap.venue = "native"
          cap.config = { "handler" => key }
          cap.description = spec["description"]
          cap.input_schema = spec["input_schema"]
          cap.kind = spec["kind"] if cap.new_record?
          cap.realm = spec["realm"] if cap.new_record?
          cap.save!
        end
      end
    end

    class Base
      attr_reader :request, :arguments

      def initialize(request)
        @request = request
        @arguments = request.arguments
      end

      private

      def require_argument(name)
        value = arguments[name.to_s]
        raise Error, "#{name} is required" if value.blank?

        value
      end

      def node_json(node)
        { hash: node.content_hash, parent: node.parent_hash, role: node.role, speaker: node.speaker, kind: node.kind,
          content: node.content, meta: node.meta, created_at: node.created_at }
      end
    end
  end
end
