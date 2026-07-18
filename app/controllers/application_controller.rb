class ApplicationController < ActionController::API
  before_action :authenticate!
  around_action :with_clearance

  rescue_from ActiveRecord::RecordNotFound do
    render json: { error: "not found" }, status: :not_found
  end

  rescue_from Gateway::UnknownRoleError, Gateway::NoProviderError do |e|
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def authenticate!
    token = request.authorization.to_s.delete_prefix("Bearer ")
    key = ApiKey.authenticate(token)
    return render json: { error: "unauthorized" }, status: :unauthorized if key.nil?

    Current.api_key = key
    Current.principal = key.principal
    Current.surface = key.surface
    Current.clearance = requested_clearance(key)
    key.update_column(:last_used_at, Time.current)
  end

  # request clearance = min(key default, principal grant, explicit cap).
  # X-Hob-Clearance can only lower — an unknown or higher realm is ignored.
  def requested_clearance(key)
    base = key.clearance
    cap = request.headers["X-Hob-Clearance"]
    return base if cap.blank?

    begin
      [ base, cap ].min_by { |slug| Realm.rank_of(slug) }
    rescue ArgumentError
      base
    end
  end

  # RLS reads current_setting('app.clearance'); unset means no rows (fail
  # closed). Session-level SET + RESET rather than SET LOCAL because streaming
  # actions can't hold one transaction open for a whole model response.
  def with_clearance
    connection = ActiveRecord::Base.connection
    connection.execute("SET app.clearance = #{connection.quote(Current.clearance)}")
    yield
  ensure
    ActiveRecord::Base.connection.execute("RESET app.clearance")
  end

  def clearance_rank
    Realm.rank_of(Current.clearance)
  end
end
