# chatelaine is a browser SPA on a different origin. Lock origins down via
# HOB_CORS_ORIGINS (comma-separated) in production.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*ENV.fetch("HOB_CORS_ORIGINS", "*").split(","))
    resource "*", headers: :any, methods: %i[get post patch put delete options head]
  end
end
