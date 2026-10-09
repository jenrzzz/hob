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
      "mission_create" => "Sentinel::Native::MissionCreate",
      "schedule_create" => "Sentinel::Native::ScheduleCreate",
      "schedule_list" => "Sentinel::Native::ScheduleList",
      "schedule_cancel" => "Sentinel::Native::ScheduleCancel",
      "agent_message" => "Sentinel::Native::AgentMessage",
      "todo_list" => "Sentinel::Native::TodoList",
      "todo_get" => "Sentinel::Native::TodoGet",
      "todo_lists" => "Sentinel::Native::TodoLists",
      "todo_create" => "Sentinel::Native::TodoCreate",
      "todo_update" => "Sentinel::Native::TodoUpdate",
      "todo_complete" => "Sentinel::Native::TodoComplete",
      "todo_drop" => "Sentinel::Native::TodoDrop",
      "ward_status" => "Sentinel::Native::WardStatus",
      "ward_audit_run" => "Sentinel::Native::WardAuditRun",
      "capability_search" => "Sentinel::Native::CapabilitySearch",
      "board_post" => "Sentinel::Native::BoardPost",
      "board_read" => "Sentinel::Native::BoardRead",
      "calendar_push" => "Sentinel::Native::CalendarPush",
      "calendar_calendars" => "Sentinel::Native::CalendarCalendars",
      "calendar_events" => "Sentinel::Native::CalendarEvents",
      "mail_mailboxes" => "Sentinel::Native::MailMailboxes",
      "mail_search" => "Sentinel::Native::MailSearch",
      "mail_message_get" => "Sentinel::Native::MailMessageGet",
      "mail_poll" => "Sentinel::Native::MailPoll",
      "mail_mailbox_create" => "Sentinel::Native::MailMailboxCreate",
      "mail_move" => "Sentinel::Native::MailMove",
      "mail_send" => "Sentinel::Native::MailSend",
      "mail_reply" => "Sentinel::Native::MailReply",
      "attachment_get" => "Sentinel::Native::AttachmentGet",
      "text_chats" => "Sentinel::Native::TextChats",
      "text_messages" => "Sentinel::Native::TextMessages",
      "text_poll" => "Sentinel::Native::TextPoll",
      "text_send" => "Sentinel::Native::TextSend",
      "budget_accounts" => "Sentinel::Native::BudgetAccounts",
      "budget_categories" => "Sentinel::Native::BudgetCategories",
      "budget_transactions" => "Sentinel::Native::BudgetTransactions",
      "budget_transaction_get" => "Sentinel::Native::BudgetTransactionGet",
      "budget_transaction_create" => "Sentinel::Native::BudgetTransactionCreate",
      "budget_transaction_update" => "Sentinel::Native::BudgetTransactionUpdate",
      "browse_open" => "Sentinel::Native::BrowseOpen",
      "browse_act" => "Sentinel::Native::BrowseAct",
      "browse_snapshot" => "Sentinel::Native::BrowseSnapshot",
      "browse_close" => "Sentinel::Native::BrowseClose",
      "browse_sessions" => "Sentinel::Native::BrowseSessions",
      "http_get" => "Sentinel::Native::HttpGet",
      "http_post" => "Sentinel::Native::HttpPost",
      "records_collections" => "Sentinel::Native::RecordsCollections",
      "records_get" => "Sentinel::Native::RecordsGet",
      "records_query" => "Sentinel::Native::RecordsQuery",
      "records_history" => "Sentinel::Native::RecordsHistory",
      "records_changes" => "Sentinel::Native::RecordsChanges",
      "records_put" => "Sentinel::Native::RecordsPut",
      "records_put_many" => "Sentinel::Native::RecordsPutMany",
      "records_collection_create" => "Sentinel::Native::RecordsCollectionCreate",
      "records_collection_update" => "Sentinel::Native::RecordsCollectionUpdate",
      "records_delete" => "Sentinel::Native::RecordsDelete",
      "records_collection_delete" => "Sentinel::Native::RecordsCollectionDelete"
    }.freeze

    module_function

    def handler(name)
      HANDLERS[name.to_s]&.constantize
    end

    def handlers
      HANDLERS.transform_values(&:constantize)
    end

    # Upsert a Capability row per handler. Description, schema, and whether
    # only a person may approve it (CAPABILITY["requires_person"]) follow the
    # code; realm, kind, and enabled are left alone once a row exists so a
    # household can tune them.
    def sync!
      handlers.map do |key, klass|
        spec = klass::CAPABILITY
        Capability.find_or_initialize_by(name: spec["name"]).tap do |cap|
          cap.venue = "native"
          cap.config = { "handler" => key, "requires_person" => spec["requires_person"] || nil }.compact
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
