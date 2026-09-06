class ApplicationController < ActionController::API
  before_action :authenticate!
  around_action :with_clearance

  rescue_from ActiveRecord::RecordNotFound do
    render json: { error: "not found" }, status: :not_found
  end

  # Gateway outcomes map onto HTTP once, here (EXTRACTION.md A6, §4).
  rescue_from Gateway::Invalid, ActiveRecord::RecordInvalid, ArgumentError do |e|
    render json: { error: e.message }, status: :unprocessable_entity
  end

  rescue_from Gateway::Refused do |e|
    render json: { status: "refused", error: e.message }, status: :ok
  end

  rescue_from Gateway::RateLimited do |e|
    response.headers["Retry-After"] = e.retry_after.to_s if e.retry_after
    render json: { error: e.message, status: "rate_limited" }, status: :service_unavailable
  end

  rescue_from Gateway::Unavailable do |e|
    render json: { error: e.message, status: "unavailable" }, status: :service_unavailable
  end

  rescue_from Gateway::Unauthorized do |e|
    render json: { error: "provider rejected hob's credentials: #{e.message}" }, status: :bad_gateway
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

  # A new conversation's realm: requested or the key's clearance, never above it.
  def requested_realm
    realm = params[:realm].presence || Current.clearance
    raise Gateway::Invalid, "realm above clearance" if Realm.rank_of(realm) > clearance_rank

    realm
  end

  def streaming_requested?
    request.headers["Accept"].to_s.include?("text/event-stream")
  end

  def node_json(node)
    return nil if node.nil?

    { hash: node.content_hash, parent: node.parent_hash, role: node.role, speaker: node.speaker,
      kind: node.kind, content: node.content, meta: node.meta, snapshot: node.prompt_snapshot_hash,
      created_at: node.created_at }
  end

  # A tool_call node as the caller sees it: the call plus where it lives.
  def tool_call_json(node)
    node.tool_call.merge("node" => node.content_hash)
  end

  # Free-form JSON params (schemas, tool definitions, metadata) arrive as
  # ActionController::Parameters; hand them back as plain hashes.
  def hash_param(name)
    value = params[name]
    return nil if value.blank?

    value.respond_to?(:permit!) ? value.permit!.to_h : value.to_h
  end

  def array_param(name)
    value = params[name]
    return nil if value.blank?

    Array(value).map { |v| v.respond_to?(:permit!) ? v.permit!.to_h : v }
  end
end
