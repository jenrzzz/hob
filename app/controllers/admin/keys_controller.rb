module Admin
  # Minting, rotating and revoking API keys: what hob:key, hob:agent and
  # hob:forge:setup do from a terminal. A raw token is rendered once, in the
  # response to the POST that made it, and never stored.
  class KeysController < BaseController
    def create
      principal = Principal.find(params[:principal_id])
      surface = params.expect(:surface).to_s.strip
      clearance = params[:clearance].presence || principal.max_clearance
      Realm.rank_of(clearance)
      token = ApiKey.issue!(principal: principal, surface: surface, default_clearance: clearance)
      show_token(principal, surface, clearance, token, rotated: 0)
    rescue ArgumentError, ActiveRecord::RecordInvalid, ActionController::ParameterMissing => e
      redirect_to admin_root_path, alert: "Couldn't mint a key: #{e.message}"
    end

    def rotate
      key = ApiKey.find(params[:id])
      token, rotated = ApiKey.rotate!(principal: key.principal, surface: key.surface, default_clearance: key.default_clearance)
      show_token(key.principal, key.surface, key.default_clearance, token, rotated: rotated)
    end

    def revoke
      key = ApiKey.find(params[:id])
      key.destroy!
      redirect_to admin_root_path(anchor: "principal-#{key.principal_id}"),
                  notice: "Revoked #{key.principal.name}'s #{key.surface} key."
    end

    private

    def show_token(principal, surface, clearance, token, rotated:)
      Rails.logger.info("admin: #{current_person.name} minted a #{surface} key for #{principal.name} (rotated #{rotated})")
      @principal, @surface, @clearance, @token, @rotated = principal, surface, clearance, token, rotated
      response.headers["Cache-Control"] = "no-store"
      render :show
    end
  end
end
