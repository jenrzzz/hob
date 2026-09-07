# Onboard a surface: mint its hob key and hand it straight to the app that
# will hold it, so the raw token goes from hob's database into the app's
# environment on Coolify and is never shown to a person.
#
#   bin/rails "hob:provision[airing,<coolify app uuid>]"
#
# The app gets HOB_URL (hob's name), HOB_ADDR (hob's tailnet address, so the
# call never leaves the tailnet — see Hob::Client ipaddr:) and HOB_KEY, then
# a restart so the new environment takes. Re-running rotates: the new key is
# pushed first, and only then are the surface's older keys deleted, so the
# app is never left holding a dead key.
class Provision
  class Error < StandardError; end

  Result = Struct.new(:surface, :app, :env, :rotated, :restarted, keyword_init: true)

  def initialize(coolify: nil, url: ENV["HOB_CLIENT_URL"], addr: ENV["HOB_CLIENT_ADDR"])
    @coolify = coolify
    @url = url.presence
    @addr = addr.presence
  end

  def call(surface:, app:, clearance: "personal", principal: "jenner", restart: true)
    raise Error, "HOB_CLIENT_URL is not set (the URL surfaces reach hob at)" unless @url

    Realm.rank_of(clearance) # an unknown realm raises before anything is issued
    owner = Principal.find_by!(name: principal)
    token = ApiKey.issue!(principal: owner, surface: surface, default_clearance: clearance)
    env = { "HOB_URL" => @url, "HOB_ADDR" => @addr, "HOB_KEY" => token }.compact

    begin
      coolify.set_env(app, env, secret: "HOB_KEY")
    rescue StandardError
      ApiKey.where(token_digest: ApiKey.digest(token)).destroy_all # nobody holds it; don't leave it live
      raise
    end

    rotated = ApiKey.where(surface: surface).where.not(token_digest: ApiKey.digest(token)).destroy_all.size
    coolify.restart(app) if restart
    Result.new(surface: surface, app: app, env: env.keys, rotated: rotated, restarted: restart)
  end

  private

  def coolify
    @coolify ||= Coolify.from_env
  end
end
