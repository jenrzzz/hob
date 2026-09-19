module V1
  # Phones running the companion app (clients/ios), registered by a person's
  # key so hob can push to them (Push). People only: an agent's or a
  # surface's key has no phone to ring.
  #
  # GET    /v1/devices                                  this person's phones
  # POST   /v1/devices { token, environment, name?, app_version?, platform? }
  #        → 201 the device; the token is the identity, so re-registering is an upsert
  # DELETE /v1/devices/:token
  # POST   /v1/devices/:token/ping                      a test push → { sent: true } or an error
  class DevicesController < ApplicationController
    before_action :require_trusted!

    def index
      render json: Current.principal.devices.order(:created_at).map { |d| serialize(d) }
    end

    def create
      device = Device.register!(
        principal: Current.principal, token: params.require(:token), environment: params[:environment].presence || "production",
        name: params[:name], app_version: params[:app_version], platform: params[:platform].presence || "ios"
      )
      render json: serialize(device), status: :created
    end

    def destroy
      device.destroy
      head :no_content
    end

    def ping
      unless Push.available?
        return render json: { sent: false, error: "APNS_KEY, APNS_KEY_ID and APNS_TEAM_ID are not set on hob" }, status: :service_unavailable
      end

      Push.deliver!(device, title: "hob", body: "Notifications reach #{device.label}.")
      render json: { sent: true }
    rescue Push::Unregistered => e
      device.destroy
      render json: { sent: false, error: "Apple says this token is dead (#{e.message}); register again" }, status: :gone
    rescue Push::Error => e
      render json: { sent: false, error: e.message }, status: :bad_gateway
    end

    private

    def device
      @device ||= Current.principal.devices.find_by!(token: params[:token].to_s.downcase)
    end

    def serialize(device)
      { id: device.id, token: device.token, platform: device.platform, environment: device.environment, name: device.name,
        app_version: device.app_version, last_seen_at: device.last_seen_at, last_pushed_at: device.last_pushed_at,
        push_configured: Push.configured? }.compact
    end
  end
end
