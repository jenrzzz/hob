module V1
  # The companion app trades the one-time code from its browser sign-in
  # (AppSignInsController) for a key. No key yet, so no bearer auth: the code
  # and its PKCE verifier are the credential.
  #
  # POST /v1/app_sessions { code, code_verifier }
  #   → 201 { key, principal, surface, clearance }   the key is shown once
  #   → 400 { error }                                 the code is spent either way
  class AppSessionsController < ApplicationController
    skip_before_action :authenticate!, :gate_agents!
    skip_around_action :with_clearance
    rate_limit to: 20, within: 1.minute

    def create
      token, grant = SignInGrant.redeem!(code: params.require(:code), code_verifier: params[:code_verifier])
      render json: { key: token, principal: grant.principal.name, surface: grant.surface,
                     clearance: grant.principal.max_clearance }, status: :created
    rescue SignInGrant::Invalid => e
      render json: { error: e.message }, status: :bad_request
    end
  end
end
