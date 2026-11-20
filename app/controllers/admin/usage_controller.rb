module Admin
  # Every gateway call the household made: what it cost, what failed, what
  # the model refused, and, for any one call, the prompt it saw, what it said
  # back, and the tools it asked for with their results. The ledger
  # (usage_events) is visible whatever the person's clearance; what a call
  # *said* (its payload, snapshot and conversation) is filtered by realm.
  class UsageController < BaseController
    PER_PAGE = 50

    def index
      @report = UsageEvent::Report.new(params.permit(:period, :group, :metric, :from, :to,
                                                     *UsageEvent::Report::FILTER_DIMS))
      @page = [ params[:page].to_i, 1 ].max
      rows = @report.calls.offset((@page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
      @more = rows.size > PER_PAGE
      @events = rows.first(PER_PAGE)
      @total = @report.stats[:calls]
      @options = { operation: distinct(:operation), model: distinct(:model), role: distinct(:role),
                   surface: distinct(:surface) }
      @unpriced_models = ModelPrice.unpriced_models
    end

    def show
      @event = UsageEvent.includes(:principal).find(params[:id])
      @payload = @event.payload
      @snapshot = @event.snapshot_digest && PromptSnapshot.find_by(digest: @event.snapshot_digest)
      @conversation = @event.conversation_id && Conversation.find_by(id: @event.conversation_id)
      @tool_results = tool_results
      # Same prompt, more than one attempt: a structured retry or a fallback.
      @attempts = @event.snapshot_digest ? UsageEvent.where(snapshot_digest: @event.snapshot_digest).order(:created_at, :id).to_a : []
      @related = @event.ref.present? ? UsageEvent.where(ref: @event.ref).recent.limit(40).to_a : []
    end

    private

    def distinct(column)
      UsageEvent.where(created_at: 90.days.ago..).where.not(column => [ nil, "" ]).distinct.order(column).pluck(column)
    end

    # The answers to this call's tool calls, from the conversation's DAG:
    # tool_call_id -> tool_result node. Native tools answered in the same
    # request; a client's answer arrives with its next one.
    def tool_results
      ids = Array(@payload&.tool_calls).filter_map { |c| c["id"] }
      return {} if ids.empty? || @conversation.nil?

      @conversation.message_nodes.where(kind: "tool_result").where("meta->>'tool_call_id' IN (?)", ids)
                   .index_by { |n| n.meta["tool_call_id"] }
    end
  end
end
