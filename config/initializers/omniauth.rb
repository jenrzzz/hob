# Signing in to the admin pages (Admin::BaseController). The household's OIDC
# provider (Pocket ID) says who someone is; principals.oidc_subject says which
# person that is in hob (`hob:link`). Without an issuer configured, development
# gets OmniAuth's developer form instead, which signs in as a principal by name.
OmniAuth.config.logger = Rails.logger
OmniAuth.config.allowed_request_methods = %i[post]

Rails.application.config.middleware.use OmniAuth::Builder do
  issuer = ENV["HOB_OIDC_ISSUER"].presence || ("https://id.test" if Rails.env.test?)
  if issuer
    base = ENV["HOB_CLIENT_URL"].presence || "http://localhost:3400"
    provider :openid_connect,
             name: :oidc,
             issuer: issuer,
             discovery: true,
             scope: %i[openid profile email],
             response_type: :code,
             pkce: true,
             client_options: {
               identifier: ENV["HOB_OIDC_CLIENT_ID"],
               secret: ENV["HOB_OIDC_CLIENT_SECRET"],
               redirect_uri: "#{base.chomp('/')}/auth/oidc/callback"
             }
  elsif Rails.env.development?
    provider :developer, fields: %i[name], uid_field: :name
  end
end
