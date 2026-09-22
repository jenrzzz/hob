require "net/http"

# Register what a surface offers the sentinel (SENTINEL.md, *Capabilities*).
# A surface that hosts capabilities (mise first) serves a manifest at
# /hob/capabilities: its name and, for each capability, the name,
# description, kind, realm, and input schema. hob fetches it, mints the
# secret it will sign deliveries with, hands the secret to the surface's
# Coolify app as HOB_WEBHOOK_SECRET (the way hob:provision hands over a
# key: never shown to a person), and upserts a webhook Capability row per
# entry, at /hob/capabilities/<name> on the surface.
#
#   bin/rails "hob:surface:register[mise,https://mise.amber.place]" APP=<coolify app uuid>
#
# Re-running re-reads the manifest: new capabilities are added, changed
# descriptions and schemas follow the code, a capability the manifest no
# longer lists is disabled (its requests are history, so it is not
# deleted), and the secret is rotated. Kind, realm, and enabled are left
# alone on a row that exists, so a household can tune them.
class SurfaceCapabilities
  class Error < StandardError; end

  MANIFEST_PATH = "/hob/capabilities".freeze
  SECRET_ENV = "HOB_WEBHOOK_SECRET".freeze

  # Tests inject a lambda (url) -> [status, body] here.
  mattr_accessor :transport

  Result = Struct.new(:surface, :created, :updated, :disabled, :secret, :pushed, :restarted, keyword_init: true)

  def initialize(coolify: nil)
    @coolify = coolify
  end

  # -> Result. `secret` is the new secret when it was not pushed to an app,
  # for the person to set by hand, and nil when it was.
  def call(surface:, url:, app: nil, restart: true, secret: nil)
    base = url.to_s.sub(%r{/+\z}, "")
    raise Error, "url must be http(s), got #{url.inspect}" unless base.match?(%r{\Ahttps?://\S+\z})

    manifest = fetch("#{base}#{MANIFEST_PATH}")
    named = manifest["surface"].to_s
    raise Error, "#{base} says it is #{named.inspect}, not #{surface.inspect}" if named.present? && named != surface
    entries = Array(manifest["capabilities"])
    raise Error, "#{base}#{MANIFEST_PATH} lists no capabilities" if entries.empty?
    entries.each { |entry| validate!(entry, surface) }

    secret = secret.presence || SecureRandom.hex(32)
    coolify.set_env(app, { SECRET_ENV => secret }, secret: SECRET_ENV) if app
    coolify.restart(app) if app && restart

    counts = Hash.new(0)
    Capability.transaction do
      entries.each { |entry| counts[upsert(entry, base, secret) ? :created : :updated] += 1 }
      counts[:disabled] = disable_missing(surface, entries.map { |e| e["name"] })
    end
    Result.new(surface: surface, created: counts[:created], updated: counts[:updated], disabled: counts[:disabled],
               secret: app ? nil : secret, pushed: app.present?, restarted: app.present? && restart)
  end

  # The webhook capabilities registered for a surface.
  def self.registered(surface)
    Capability.where(venue: "webhook").select { |cap| cap.config["surface"] == surface }.sort_by(&:name)
  end

  private

  def validate!(entry, surface)
    name = entry["name"].to_s
    raise Error, "a capability has no name" if name.blank?
    raise Error, "#{name} is not #{surface}'s to offer: names start with \"#{surface}.\"" unless name.start_with?("#{surface}.")
    raise Error, "#{name} has no description" if entry["description"].blank?
    raise Error, "#{name}: kind must be read or act" unless Capability::KINDS.include?(entry["kind"])
    raise Error, "#{name}: input_schema must be an object schema" unless entry["input_schema"].is_a?(Hash)
  end

  # -> true when the row is new
  def upsert(entry, base, secret)
    cap = Capability.find_or_initialize_by(name: entry["name"])
    created = cap.new_record?
    raise Error, "#{cap.name} is a #{cap.venue} capability, not a surface's" unless created || cap.venue == "webhook"

    cap.venue = "webhook"
    cap.config = { "url" => "#{base}#{MANIFEST_PATH}/#{cap.name}", "secret" => secret, "surface" => entry["name"].split(".").first }
    cap.description = entry["description"]
    cap.input_schema = entry["input_schema"]
    if created
      cap.kind = entry["kind"]
      cap.realm = entry["realm"].presence || "household"
      cap.enabled = true
    end
    cap.save!
    created
  end

  def disable_missing(surface, names)
    self.class.registered(surface).reject { |cap| names.include?(cap.name) }.count do |cap|
      cap.enabled && cap.update!(enabled: false)
    end
  end

  def fetch(url)
    status, body = (transport || SurfaceCapabilities.transport || method(:get)).call(url)
    raise Error, "#{url} answered HTTP #{status}" unless status.to_s.start_with?("2")

    data = JSON.parse(body)
    raise Error, "#{url} did not answer a manifest object" unless data.is_a?(Hash)

    data
  rescue JSON::ParserError
    raise Error, "#{url} did not answer JSON"
  end

  def get(url)
    uri = URI(url)
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/json"
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) do |http|
      http.request(request)
    end
    [ response.code, response.body ]
  rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, IOError => e
    raise Error, "#{uri.host} is unreachable: #{e.message}"
  end

  def coolify
    @coolify ||= Provision::Coolify.from_env
  end
end
