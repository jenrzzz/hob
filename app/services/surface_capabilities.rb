require "net/http"

# Register what a surface offers the sentinel (SENTINEL.md, *Capabilities*):
# the plugin venue, v0 (PLUGINS.md). A surface that hosts capabilities
# (mise first) serves a manifest at /hob/capabilities: its name and, for
# each capability, the name, description, kind, realm, and input schema.
# Each entry becomes a webhook Capability row, delivered to at
# /hob/capabilities/<name> on the surface and signed with a secret hob mints.
#
# Three operations, so that keeping a manifest in step never touches the
# secret (PLUGINS.md, section 1):
#
#   refresh   re-read the manifest and reconcile the rows. Never touches the
#             secret or the app. What it adds lands unaccepted and disabled,
#             and a person is told: nothing reaches it until they accept it
#             (Capability#accept!). This is what a schedule will run.
#   rotate    mint a new secret, write it to the rows with the old one kept
#             for an overlap (Sentinel::Webhook signs with both), then hand it
#             to the surface's Coolify app as HOB_WEBHOOK_SECRET and restart
#             it. Only at registration or when a person asks.
#   register  bootstrap, by a person: refresh, accepting what is new (the
#             person running it is looking at the list), then rotate.
#
#   bin/rails "hob:surface:register[mise,https://mise.example.com]" APP=<coolify app uuid>
#   bin/rails "hob:surface:refresh[mise]"
#   bin/rails "hob:surface:rotate[mise]" APP=<coolify app uuid>
#
# Reconciling: new capabilities are added, changed descriptions and schemas
# follow the code, a capability the manifest no longer lists is disabled
# (its requests are history, so it is not deleted). Kind, realm, and enabled
# are left alone on an accepted row, so a household can tune them; on one
# still waiting to be accepted, kind and realm follow the proposal.
class SurfaceCapabilities
  class Error < StandardError; end

  MANIFEST_PATH = "/hob/capabilities".freeze
  SECRET_ENV = "HOB_WEBHOOK_SECRET".freeze
  # How long deliveries stay signed with the old secret too, after a rotation:
  # long enough for the surface to restart with the new one.
  ROTATION_OVERLAP = 1.hour
  SURFACE_FORMAT = /\A[a-z0-9]+(?:[_-][a-z0-9]+)*\z/
  # Namespaces hob uses for itself beyond its native handlers' prefixes: the
  # steward's charter pseudo-capability (sentinel.petition) and the forge.
  RESERVED = %w[sentinel forge].freeze

  # Tests inject a lambda (url) -> [status, body] here.
  mattr_accessor :transport

  Result = Struct.new(:surface, :created, :updated, :disabled, :proposed, :secret, :pushed, :restarted, keyword_init: true)

  def initialize(coolify: nil)
    @coolify = coolify
  end

  # Bootstrap, by a person. -> Result. `secret` is the new secret when it was
  # not pushed to an app, for the person to set by hand, and nil when it was.
  def register(surface:, url:, app: nil, restart: true, secret: nil)
    base = base_url(url)
    entries = manifest_entries(surface, base)
    secret = secret.presence || SecureRandom.hex(32)

    counts = Capability.transaction do
      reconcile(surface, base, entries, accept: true, first_secret: secret).tap { rekey(surface, secret) }
    end
    counts.delete(:proposed_names)
    pushed = push(app, secret, restart)
    Result.new(surface: surface, **counts, proposed: [], secret: pushed ? nil : secret, pushed: pushed,
               restarted: pushed && restart)
  end

  # Re-read the manifest and reconcile; never touches the secret or the app.
  # The surface must already be registered (that is where its URL and secret
  # come from); moving it to another URL is a registration, by a person.
  def refresh(surface:, url: nil)
    existing = self.class.registered(surface)
    raise Error, "#{surface} is not registered: bin/rails \"hob:surface:register[#{surface},url]\"" if existing.empty?

    base = registered_base(existing)
    if url.present? && base_url(url) != base
      raise Error, "#{surface} is registered at #{base}, not #{base_url(url)}: re-register to move it"
    end

    entries = manifest_entries(surface, base)
    counts = Capability.transaction { reconcile(surface, base, entries, accept: false) }
    proposed = counts.delete(:proposed_names)
    tell_person(surface, proposed) if proposed.any?
    Result.new(surface: surface, **counts, proposed: proposed, secret: nil, pushed: false, restarted: false)
  end

  # Mint (or take) a new secret: written to the rows first, with the old one
  # still signing alongside it for ROTATION_OVERLAP, then pushed to the app.
  def rotate(surface:, app: nil, restart: true, secret: nil)
    raise Error, "#{surface} is not registered" if self.class.registered(surface).empty?

    secret = secret.presence || SecureRandom.hex(32)
    Capability.transaction { rekey(surface, secret) }
    pushed = push(app, secret, restart)
    Result.new(surface: surface, created: 0, updated: 0, disabled: 0, proposed: [], secret: pushed ? nil : secret,
               pushed: pushed, restarted: pushed && restart)
  end

  # The webhook capabilities registered for a surface.
  def self.registered(surface)
    Capability.where(venue: "webhook").select { |cap| cap.config["surface"] == surface }.sort_by(&:name)
  end

  # The first segment of every native capability's name, and hob's own
  # namespaces: a surface may not offer capabilities under any of them.
  def self.reserved_namespaces
    (Sentinel::Native.handlers.values.map { |klass| klass::CAPABILITY["name"].split(".").first } + RESERVED).uniq.sort
  end

  private

  def base_url(url)
    base = url.to_s.sub(%r{/+\z}, "")
    raise Error, "url must be http(s), got #{url.inspect}" unless base.match?(%r{\Ahttps?://\S+\z})

    base
  end

  def registered_base(caps)
    bases = caps.map { |cap| cap.config["url"].to_s.delete_suffix("#{MANIFEST_PATH}/#{cap.name}") }.uniq
    raise Error, "#{caps.first.config['surface']}'s capabilities point at more than one URL: #{bases.join(', ')}" if bases.size > 1

    bases.first
  end

  # Fetched and checked in full before anything is written.
  def manifest_entries(surface, base)
    check_surface!(surface)
    manifest = fetch("#{base}#{MANIFEST_PATH}")
    named = manifest["surface"].to_s
    raise Error, "#{base} says it is #{named.inspect}, not #{surface.inspect}" if named.present? && named != surface

    entries = Array(manifest["capabilities"])
    raise Error, "#{base}#{MANIFEST_PATH} lists no capabilities" if entries.empty?

    entries.each { |entry| validate!(entry, surface) }
    names = entries.map { |entry| entry["name"] }
    raise Error, "#{base}#{MANIFEST_PATH} lists #{(names.tally.select { |_, n| n > 1 }.keys).join(', ')} more than once" if names.uniq.size < names.size

    entries
  end

  def check_surface!(surface)
    raise Error, "surface name #{surface.inspect} must be lowercase letters, digits, - or _" unless surface.to_s.match?(SURFACE_FORMAT)
    return unless self.class.reserved_namespaces.include?(surface)

    raise Error, "#{surface} is reserved: hob's own capabilities live under #{surface}."
  end

  def validate!(entry, surface)
    raise Error, "a manifest entry is not an object" unless entry.is_a?(Hash)

    name = entry["name"].to_s
    raise Error, "a capability has no name" if name.blank?
    raise Error, "#{name} is not #{surface}'s to offer: names start with \"#{surface}.\"" unless name.start_with?("#{surface}.")
    raise Error, "#{name} is not a capability name" unless name.match?(Capability::NAME_FORMAT)
    raise Error, "#{name} has no description" if entry["description"].blank?
    raise Error, "#{name}: kind must be read or act" unless Capability::KINDS.include?(entry["kind"])
    raise Error, "#{name}: input_schema must be an object schema" unless entry["input_schema"].is_a?(Hash)

    Realm.rank_of(entry["realm"]) if entry["realm"].present?
  rescue ArgumentError => e
    raise Error, "#{name}: #{e.message}"
  end

  # -> { created:, updated:, disabled:, proposed_names: }. A row it adds
  # signs as the surface's rows already do; `first_secret` is for a surface
  # with none yet.
  def reconcile(surface, base, entries, accept:, first_secret: nil)
    secrets = self.class.registered(surface).any? ? signing_config(surface) : { "secret" => first_secret }
    counts = Hash.new(0)
    proposed = []
    entries.each do |entry|
      cap = upsert(entry, surface, base, secrets, accept: accept)
      counts[cap.previously_new_record? ? :created : :updated] += 1
      proposed << cap.name if cap.previously_new_record? && !cap.accepted?
    end
    counts[:disabled] = disable_missing(surface, entries.map { |e| e["name"] })
    { created: counts[:created], updated: counts[:updated], disabled: counts[:disabled], proposed_names: proposed }
  end

  def upsert(entry, surface, base, secrets, accept:)
    cap = Capability.find_or_initialize_by(name: entry["name"])
    created = cap.new_record?
    raise Error, "#{cap.name} is a #{cap.venue} capability, not a surface's" unless created || cap.venue == "webhook"
    unless created || cap.config["surface"] == surface
      raise Error, "#{cap.name} belongs to #{cap.config['surface'].inspect}, not #{surface}"
    end

    cap.venue = "webhook"
    cap.config = (created ? {} : cap.config).merge(secrets).merge("url" => "#{base}#{MANIFEST_PATH}/#{cap.name}", "surface" => surface)
    cap.description = entry["description"]
    cap.input_schema = entry["input_schema"]
    if created || !cap.accepted?
      # A proposal, until a person accepts it.
      cap.kind = entry["kind"]
      cap.realm = entry["realm"].presence || "household"
    end
    if created
      cap.accepted_at = accept ? Time.current : nil
      cap.enabled = accept
    end
    cap.save!
    cap
  end

  # What the surface's rows sign with now, for a row refresh adds.
  def signing_config(surface)
    current = self.class.registered(surface).max_by(&:updated_at)
    current.config.slice("secret", "previous_secret", "previous_secret_until")
  end

  # Every row of the surface signs with `secret` from now on, and with the
  # secret it replaces too, until the overlap ends.
  def rekey(surface, secret)
    until_at = ROTATION_OVERLAP.from_now.iso8601
    self.class.registered(surface).each do |cap|
      previous = cap.config["secret"]
      config = cap.config.merge("secret" => secret)
      config = if previous.present? && previous != secret
                 config.merge("previous_secret" => previous, "previous_secret_until" => until_at)
      else
                 config.except("previous_secret", "previous_secret_until")
      end
      cap.update!(config: config)
    end
  end

  # -> true when the secret was handed to an app.
  def push(app, secret, restart)
    return false unless app

    coolify.set_env(app, { SECRET_ENV => secret }, secret: SECRET_ENV)
    coolify.restart(app) if restart
    true
  end

  def disable_missing(surface, names)
    self.class.registered(surface).reject { |cap| names.include?(cap.name) }.count do |cap|
      cap.enabled && cap.update!(enabled: false)
    end
  end

  # PLUGINS.md, section 5: automatic discovery must not mean the person who
  # decides never hears about it.
  def tell_person(surface, names)
    title = names.one? ? "hob: #{surface} offers a new capability, #{names.first}" : "hob: #{surface} offers #{names.size} new capabilities"
    accept = names.map { |name| "bin/rails \"hob:capabilities:accept[#{name}]\"" }
    Notify.person(title: title, tags: "package",
                  body: ([ "Nobody can use #{names.one? ? 'it' : 'them'} until you accept: see bin/rails hob:capabilities:unaccepted, then" ] + accept).join("\n"))
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
