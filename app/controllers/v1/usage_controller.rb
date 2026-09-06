module V1
  # GET /v1/usage?ref=&role=&operation=&since=&surface=
  # The ledger summary, so surfaces can drop their own. Scoped to the calling
  # key's surface unless `surface` is given ("all" for the whole household).
  class UsageController < ApplicationController
    def show
      scope = UsageEvent.all
      scope = scope.where(surface: Current.surface) if params[:surface].blank?
      scope = scope.where(surface: params[:surface]) if params[:surface].present? && params[:surface] != "all"
      scope = scope.where(ref: params[:ref]) if params[:ref].present?
      scope = scope.where(role: params[:role]) if params[:role].present?
      scope = scope.where(operation: params[:operation]) if params[:operation].present?
      scope = scope.since(Time.zone.parse(params[:since])) if params[:since].present?

      rows = scope.order(created_at: :desc).limit(10_000).to_a
      render json: UsageEvent.summarize(rows).merge(
        by_role: rows.group_by(&:role).transform_values { |r| UsageEvent.summarize(r).slice(:calls, :cost) },
        by_operation: rows.group_by(&:operation).transform_values { |r| UsageEvent.summarize(r).slice(:calls, :cost) },
        recent: rows.first(20).map { |r| event_json(r) }
      )
    end

    private

    def event_json(event)
      { id: event.id, at: event.created_at, surface: event.surface, role: event.role, operation: event.operation,
        status: event.status, model: event.model, provider: event.provider, units: event.units,
        cost: event.cost&.to_f, duration_ms: event.duration_ms, ref: event.ref, error: event.error }
    end
  end
end
