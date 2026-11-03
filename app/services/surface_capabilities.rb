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
# Each surface is a Plugin installation (PLUGINS.md, Phase 1): registering
# one the first time mints its `surface` principal and fixes its namespace,
# and its rows belong to it, so no other installation can take them. OWNER=
# makes it a personal installation, reached only by that person. A
# quarantined installation is not refreshed.
#
# Namespace and type (PLUGINS.md, Phase 1c): the namespace is the
# installation's, the type is the app's (its manifest's `surface`), and
# both are fixed at registration (TYPE=, the namespace when not given). The
# manifest names each operation under its type, "contacts.card.get", and
# hob offers it under the namespace, "contacts-house.card.get", keeping the
# manifest's name as the row's remote_name: deliveries go to
# /hob/capabilities/<remote_name> and say { capability: <remote_name>,
# installation: <namespace> }, so the plugin's routes are its own.
#
#   bin/rails "hob:surface:register[contacts-house,https://contacts.example.com]" TYPE=contacts APP=<uuid>
#
# Signing (PLUGINS.md, Phase 1b): register and rotate also mint the
# installation's own key and hand it over as HOB_PLUGIN_KEY (with
# HOB_PLUGIN_ID, its namespace, and HOB_PLUGIN_URL, where hob is). Every
# manifest fetch carries a fresh nonce; a plugin holding the key answers with
# X-Hob-Manifest-Signature (PluginSignature), which must verify before
# anything is written. Once one has, an unsigned answer is refused, the
# plugin may announce itself to have its manifest refreshed (automatic:
# true), and a rotation's old delivery secret keeps signing until the
# plugin's manifest says it holds the new one, rather than for an hour. An
# installation that has never signed keeps its HTTPS origin's word, for a
# person's refresh only.
#
# Reconciling: new capabilities are added, changed descriptions and schemas
# follow the code, a capability the manifest no longer lists is disabled
# (its requests are history, so it is not deleted). Kind, realm, and enabled
# are left alone on an accepted row, so a household can tune them; on one
# still waiting to be accepted, kind and realm follow the proposal.
#
# Contracts (PLUGINS.md, Phase 1d): an accepted row whose schema the
# manifest changes in a way that breaks callers or rules (ContractDiff), or
# whose declared kind or realm changes, is refused, that entry alone: it
# keeps the contract a person accepted, is suspended, and a person is told.
# A loosening change goes through and bumps contract_revision, so a request
# asked against the old one is not delivered. A suspended row stays as it is
# until a person resumes it (#resume, hob:capabilities:resume), which reads
# the manifest again and needs it to serve a compatible contract. A breaking
# change is published under a new name (feedreader.entries.v2), a new
# capability that goes through acceptance; an entry's `version`,
# `deprecated_at`, and `sunset_at` are recorded as the manifest gives them.
class SurfaceCapabilities
  class Error < StandardError; end

  MANIFEST_PATH = "/hob/capabilities".freeze
  SECRET_ENV = "HOB_WEBHOOK_SECRET".freeze
  # How long deliveries stay signed with the old secret too, after a rotation:
  # long enough for the surface to restart with the new one.
  ROTATION_OVERLAP = 1.hour
  SURFACE_FORMAT = Plugin::NAMESPACE_FORMAT
  # Namespaces hob uses for itself beyond its native handlers' prefixes: the
  # steward's charter pseudo-capability (sentinel.petition) and the forge.
  RESERVED = %w[sentinel forge].freeze

  KEY_ENV = "HOB_PLUGIN_KEY".freeze
  ID_ENV = "HOB_PLUGIN_ID".freeze
  URL_ENV = "HOB_PLUGIN_URL".freeze
  SIGNATURE_HEADER = "x-hob-manifest-signature".freeze

  # Tests inject a lambda (url, headers) -> [status, body, response headers] here.
  mattr_accessor :transport

  # `secret` and `plugin_key` are the new credentials when they were not
  # pushed to an app, for a person to set by hand, and nil when they were.
  # `signed` says whether the manifest this run read was signed.
  # `suspended` is [[name, why]] for the entries this run refused
  # (PLUGINS.md, section 7), `resumed` the names a person resumed.
  Result = Struct.new(:surface, :plugin, :created, :updated, :disabled, :proposed, :secret, :plugin_key, :pushed,
                      :restarted, :signed, :suspended, :resumed, keyword_init: true)

  def initialize(coolify: nil)
    @coolify = coolify
  end

  # Bootstrap, by a person. -> Result. `secret` is the new secret when it was
  # not pushed to an app, for the person to set by hand, and nil when it was.
  # `owner` (a person) makes a new installation personal; it is ignored on
  # a re-registration, and an installation's owner is not changed here.
  #
  # A person registering is bootstrap trust: an unsigned answer is taken
  # even from an installation that has signed before, and it then has to
  # prove itself again before it refreshes on its own.
  #
  # `type` is the plugin type a new installation is of (the namespace when
  # not given); an installation's type is never changed.
  def register(surface:, url:, type: nil, app: nil, restart: true, secret: nil, owner: nil)
    base = base_url(url)
    raise Error, "#{owner.name} is not a person; only a person owns a plugin" if owner && !owner.trusted?

    existing = Plugin.find_by(namespace: surface)
    type = plugin_type(surface, type, existing)
    entries, signed, body = manifest_entries(surface, type, base, existing, bootstrap: true)
    secret = secret.presence || SecureRandom.hex(32)
    plugin_key = SecureRandom.hex(32)

    plugin = nil
    counts = Capability.transaction do
      plugin = installation(surface, type, base, owner)
      plugin.with_lock do
        recheck_trust!(plugin, signed, bootstrap: true)
        accept_revision!(plugin, signed, body)
        reconcile(plugin, entries, accept: true, first_secret: secret).tap do
          record_manifest(plugin, signed, body, bootstrap: true)
          rekey(plugin, secret)
          plugin.rekey!(plugin_key)
        end
      end
    end
    counts.delete(:proposed_names)
    tell_suspended(surface, counts[:suspended]) if counts[:suspended].any?
    pushed = push(app, plugin, secret, plugin_key, restart)
    Result.new(surface: surface, plugin: plugin, **counts, proposed: [], secret: pushed ? nil : secret,
               plugin_key: pushed ? nil : plugin_key, pushed: pushed, restarted: pushed && restart, signed: signed.present?)
  end

  # Re-read the manifest and reconcile; never touches the secret or the app.
  # The surface must already be registered (that is where its URL and secret
  # come from); moving it to another URL is a registration, by a person.
  # `automatic` is a refresh no person asked for (an announcement): only an
  # installation that signs its manifest gets one.
  #
  # `resume` ({ name => { by:, realm:, kind: } }) is #resume's: a suspended
  # row is resumed only if this read of the manifest holds to its contract.
  def refresh(surface:, url: nil, automatic: false, resume: {})
    plugin = Plugin.find_by(namespace: surface)
    raise Error, "#{surface} is not registered: bin/rails \"hob:surface:register[#{surface},url]\"" if plugin.nil?
    raise Error, "#{surface} is quarantined (#{plugin.principal.capabilities_freeze_reason}): release it first" if plugin.quarantined?
    if automatic && !plugin.signed?
      raise Error, "#{surface} has never signed its manifest: only a person refreshes it"
    end

    base = plugin.base_url
    if url.present? && base_url(url) != base
      raise Error, "#{surface} is registered at #{base}, not #{base_url(url)}: re-register to move it"
    end

    entries, signed, body = manifest_entries(surface, plugin.plugin_type, base, plugin, bootstrap: false)
    # Serialized per installation: of two refreshes racing, the one holding
    # the older revision cannot overwrite what the newer one wrote, and one
    # fetched before the installation began signing cannot overwrite what a
    # signed one wrote.
    counts = plugin.with_lock do
      raise Error, "#{surface} was quarantined while it was being refreshed; nothing was changed" if plugin.quarantined?
      raise Error, "#{surface} moved to #{plugin.base_url} while it was being refreshed; nothing was changed" if plugin.base_url != base

      recheck_trust!(plugin, signed, bootstrap: false)
      accept_revision!(plugin, signed, body)
      reconcile(plugin, entries, accept: false, resume: resume).tap { record_manifest(plugin, signed, body) }
    end
    proposed = counts.delete(:proposed_names)
    tell_person(surface, proposed) if proposed.any?
    tell_suspended(surface, counts[:suspended]) if counts[:suspended].any?
    Result.new(surface: surface, plugin: plugin, **counts, proposed: proposed, secret: nil, plugin_key: nil, pushed: false,
               restarted: false, signed: signed.present?)
  end

  # Mint (or take) a new delivery secret, and mint a new plugin key: written
  # first, with the old ones still working alongside them, then pushed to
  # the app. The old delivery secret keeps signing for ROTATION_OVERLAP, or,
  # for an installation that signs its manifest, until that manifest says it
  # holds the new one; the old key verifies until a manifest signed with the
  # new one arrives.
  def rotate(surface:, app: nil, restart: true, secret: nil)
    plugin = Plugin.find_by(namespace: surface)
    raise Error, "#{surface} is not registered" if plugin.nil? || self.class.registered(surface).empty?

    secret = secret.presence || SecureRandom.hex(32)
    plugin_key = SecureRandom.hex(32)
    plugin.with_lock do
      rekey(plugin, secret)
      plugin.rekey!(plugin_key)
    end
    pushed = push(app, plugin, secret, plugin_key, restart)
    Result.new(surface: surface, plugin: plugin, created: 0, updated: 0, disabled: 0, proposed: [], suspended: [], resumed: [],
               secret: pushed ? nil : secret,
               plugin_key: pushed ? nil : plugin_key, pushed: pushed, restarted: pushed && restart, signed: nil)
  end

  # A person resumes a capability a refresh suspended (PLUGINS.md, section
  # 7), once the plugin serves a contract its accepted one still holds for:
  # the manifest is read again, as a refresh, and the row is resumed only if
  # that read holds. A changed declaration of kind or realm is what the
  # person is looking at; `realm` and `kind` change the household's, as
  # accepting does. -> Result
  def resume(name:, by:, realm: nil, kind: nil)
    raise Error, "only a person resumes a capability" if by && !by.trusted?

    cap = Capability.find_by(name: name)
    raise Error, "#{name} is not suspended" unless cap&.suspended?
    raise Error, "#{name} belongs to no installation; a person suspended it by hand" if cap.plugin.nil?

    result = refresh(surface: cap.plugin.namespace, resume: { name => { by: by, realm: realm, kind: kind } })
    raise Error, "#{name} is no longer in #{cap.plugin.namespace}'s manifest; it stays suspended, and is disabled" unless result.resumed.include?(name)

    result
  end

  # The webhook capabilities registered for a surface: its installation's.
  def self.registered(surface)
    plugin = Plugin.find_by(namespace: surface)
    plugin ? plugin.capabilities.where(venue: "webhook").order(:name).to_a : []
  end

  # What the plugin is given: the delivery secret, its own key, its
  # installation id, and where hob is, to announce itself to.
  def self.env(plugin, secret, plugin_key)
    hob = ENV["HOB_CLIENT_URL"].presence&.sub(%r{/+\z}, "")
    { SECRET_ENV => secret, KEY_ENV => plugin_key, ID_ENV => plugin.namespace, URL_ENV => hob }.compact
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

  # The type a registration is for: what the person said, or the
  # installation's own; a new installation not told one is its namespace's.
  def plugin_type(surface, type, existing)
    type = type.to_s.presence
    if existing && type && type != existing.plugin_type
      raise Error, "#{surface} is a #{existing.plugin_type} installation, and its type never changes: " \
                   "register the #{type} app under another namespace"
    end
    type ||= existing&.plugin_type || surface.to_s
    raise Error, "plugin type #{type.inspect} must be lowercase letters, digits, - or _" unless type.match?(SURFACE_FORMAT)

    type
  end

  # The surface's installation, made the first time it registers. A person
  # re-registering it may move it to another URL.
  def installation(surface, type, base, owner)
    plugin = Plugin.find_by(namespace: surface)
    if plugin
      plugin.update!(base_url: base)
      return plugin
    end

    Plugin.install!(namespace: surface, plugin_type: type, base_url: base, owner: owner)
  rescue ActiveRecord::RecordInvalid => e
    raise Error, "#{surface}: #{e.record.errors.full_messages.to_sentence}"
  end

  # Fetched, its signature verified, and checked in full before anything is
  # written. Each entry comes back with "name" the name hob offers it under
  # and "remote_name" the manifest's. -> [entries, PluginSignature::Manifest
  # or nil, raw body]
  def manifest_entries(surface, type, base, plugin, bootstrap:)
    check_surface!(surface)
    manifest, signed, body = fetch_manifest(surface, "#{base}#{MANIFEST_PATH}", plugin, bootstrap: bootstrap)
    named = manifest["surface"].to_s
    if named.present? && named != type
      hint = surface == type ? " (a #{named} app under its own namespace: TYPE=#{named})" : ""
      raise Error, "#{base} says it is #{named.inspect}, not #{type.inspect}#{hint}"
    end

    entries = Array(manifest["capabilities"])
    raise Error, "#{base}#{MANIFEST_PATH} lists no capabilities" if entries.empty?

    entries.each { |entry| validate!(entry, type) }
    names = entries.map { |entry| entry["name"] }
    raise Error, "#{base}#{MANIFEST_PATH} lists #{(names.tally.select { |_, n| n > 1 }.keys).join(', ')} more than once" if names.uniq.size < names.size

    entries = entries.map { |entry| local_entry(entry, surface, type) }
    [ entries, signed, body ]
  end

  def local_entry(entry, surface, type)
    name = Plugin.local_name(surface, type, entry["name"])
    raise Error, "#{entry['name']} would be offered as #{name}, which is not a capability name" unless name&.match?(Capability::NAME_FORMAT)

    entry.merge("name" => name, "remote_name" => entry["name"])
  end

  # -> [manifest, PluginSignature::Manifest or nil, raw body]
  def fetch_manifest(surface, url, plugin, bootstrap:)
    nonce = SecureRandom.hex(16)
    status, body, headers = request_manifest(url, { "X-Hob-Installation" => surface, "X-Hob-Nonce" => nonce })
    raise Error, "#{url} answered HTTP #{status}" unless status.to_s.start_with?("2")

    header = headers.to_h.transform_keys { |k| k.to_s.downcase }[SIGNATURE_HEADER]
    signed = nil
    if header.present?
      keys = plugin&.accepted_keys || []
      raise Error, "#{url} signed its manifest, but hob holds no key for #{surface}: register it again" if keys.empty?

      signed = PluginSignature.verify_manifest(header, keys: keys, namespace: surface, nonce: nonce, body: body.to_s)
      raise Error, "#{url}: the manifest's signature does not verify; nothing was changed" if signed.nil?
    elsif plugin&.signed? && !bootstrap
      raise Error, "#{url} answered an unsigned manifest, but #{surface} signs its manifests; nothing was changed " \
                   "(if its key was lost, a person registers it again)"
    end
    [ parse_manifest(url, body), signed, body.to_s ]
  end

  # What the answer was checked against when it was fetched, checked again
  # on the locked row: while it was in flight, another refresh may have
  # established signed trust, or a rotation or registration may have retired
  # the key it was signed with.
  def recheck_trust!(plugin, signed, bootstrap:)
    if signed.nil?
      return unless plugin.signed? && !bootstrap

      raise Error, "#{plugin.namespace} began signing its manifests while an unsigned one was being fetched; nothing was changed"
    end
    return if plugin.accepted_keys.include?(signed.key)

    raise Error, "#{plugin.namespace}'s key changed while its manifest was being fetched; nothing was changed"
  end

  # A signed revision older than the one last reconciled, or the same one
  # with a different body, is refused.
  def accept_revision!(plugin, signed, body)
    return if signed.nil? || plugin.manifest_revision.nil?

    if signed.revision < plugin.manifest_revision
      raise Error, "#{plugin.namespace} answered revision #{signed.revision}, older than #{plugin.manifest_revision}; nothing was changed"
    end
    return unless signed.revision == plugin.manifest_revision && plugin.manifest_digest != digest(body)

    raise Error, "#{plugin.namespace} answered revision #{signed.revision} with a different manifest than before; nothing was changed"
  end

  # What a verified manifest proves: the key it was signed with works, and
  # the delivery secret it says it holds (kid) does. Once it holds the
  # newest one, the one before it stops signing.
  def record_manifest(plugin, signed, body, bootstrap: false)
    if signed.nil?
      plugin.update!(signed_since: nil, manifest_revision: nil, manifest_digest: nil, refreshed_at: Time.current) if bootstrap
      plugin.update!(refreshed_at: Time.current) unless bootstrap
      return
    end

    plugin.manifest_verified!(with: signed.key, revision: signed.revision, digest: digest(body))
    current = self.class.registered(plugin.namespace).max_by(&:updated_at)&.config&.dig("secret")
    retire_previous_secret(plugin) if current && signed.kid == PluginSignature.delivery_key_id(current)
  end

  def retire_previous_secret(plugin)
    self.class.registered(plugin.namespace).each do |cap|
      next unless cap.config.key?("previous_secret")

      cap.update!(config: cap.config.except("previous_secret", "previous_secret_until"))
    end
  end

  def digest(body)
    OpenSSL::Digest::SHA256.hexdigest(body.to_s)
  end

  def check_surface!(surface)
    raise Error, "surface name #{surface.inspect} must be lowercase letters, digits, - or _" unless surface.to_s.match?(SURFACE_FORMAT)
    return unless self.class.reserved_namespaces.include?(surface)

    raise Error, "#{surface} is reserved: hob's own capabilities live under #{surface}."
  end

  def validate!(entry, type)
    raise Error, "a manifest entry is not an object" unless entry.is_a?(Hash)

    name = entry["name"].to_s
    raise Error, "a capability has no name" if name.blank?
    raise Error, "#{name} is not a #{type} operation: a #{type} manifest's names start with \"#{type}.\"" unless name.start_with?("#{type}.")
    raise Error, "#{name} is not a capability name" unless name.match?(Capability::NAME_FORMAT)
    raise Error, "#{name} has no description" if entry["description"].blank?
    raise Error, "#{name}: kind must be read or act" unless Capability::KINDS.include?(entry["kind"])
    raise Error, "#{name}: input_schema must be an object schema" unless entry["input_schema"].is_a?(Hash)

    Realm.rank_of(entry["realm"]) if entry["realm"].present?
    %w[deprecated_at sunset_at].each do |key|
      next if entry[key].blank?
      raise Error, "#{name}: #{key} must be an ISO 8601 time" if Time.zone.parse(entry[key].to_s).nil?
    end
    if entry.key?("version") && !(entry["version"].is_a?(String) || entry["version"].is_a?(Integer))
      raise Error, "#{name}: version must be a string or an integer"
    end
  rescue ArgumentError => e
    raise Error, "#{name}: #{e.message}"
  end

  # -> { created:, updated:, disabled:, suspended:, resumed:, proposed_names: }.
  # A row it adds signs as the surface's rows already do; `first_secret` is
  # for a surface with none yet. `resume` is { name => { by:, realm:, kind: } }
  # for suspended rows a person is resuming.
  def reconcile(plugin, entries, accept:, first_secret: nil, resume: {})
    surface = plugin.namespace
    secrets = self.class.registered(surface).any? ? signing_config(surface) : { "secret" => first_secret }
    counts = Hash.new(0)
    proposed = []
    suspended = []
    resumed = []
    entries.each do |entry|
      cap, outcome = upsert(entry, plugin, secrets, accept: accept, resume: resume[entry["name"]])
      counts[cap.previously_new_record? ? :created : :updated] += 1
      proposed << cap.name if cap.previously_new_record? && !cap.accepted?
      suspended << [ cap.name, cap.suspended_reason ] if outcome == :suspended
      resumed << cap.name if outcome == :resumed
    end
    counts[:disabled] = disable_missing(surface, entries.map { |e| e["name"] })
    { created: counts[:created], updated: counts[:updated], disabled: counts[:disabled], suspended: suspended,
      resumed: resumed, proposed_names: proposed }
  end

  # -> [capability, :created | :updated | :suspended | :held | :resumed]
  def upsert(entry, plugin, secrets, accept:, resume: nil)
    surface = plugin.namespace
    base = plugin.base_url
    cap = Capability.find_or_initialize_by(name: entry["name"])
    created = cap.new_record?
    raise Error, "#{cap.name} is a #{cap.venue} capability, not a surface's" unless created || cap.venue == "webhook"
    unless created || cap.plugin_id == plugin.id
      owner = cap.plugin&.namespace || cap.config["surface"]
      raise Error, "#{cap.name} belongs to #{owner ? owner.inspect : 'no installation (it was registered by hand)'}, not #{surface}"
    end

    cap.venue = "webhook"
    cap.plugin = plugin
    cap.remote_name = entry["remote_name"]
    cap.config = (created ? {} : cap.config).merge(secrets).merge("url" => "#{base}#{MANIFEST_PATH}/#{cap.remote_name}", "surface" => surface)
    cap.deprecated_at = entry["deprecated_at"].presence && Time.zone.parse(entry["deprecated_at"].to_s)
    cap.sunset_at = entry["sunset_at"].presence && Time.zone.parse(entry["sunset_at"].to_s)

    outcome = contract_outcome(cap, entry, created: created, resume: resume)
    case outcome
    when :suspended
      cap.suspended_at = Time.current
      cap.suspended_reason = "#{surface} changed its contract: #{contract_problems(cap, entry).join('; ')}. " \
                             "It keeps the one accepted; publish the new one under a new name (#{entry['remote_name']}.v2)"
    when :resumed
      cap.suspended_at = nil
      cap.suspended_reason = nil
      cap.realm = resume[:realm].presence || cap.realm
      cap.kind = resume[:kind].presence || cap.kind
    end
    if %i[created updated resumed].include?(outcome)
      cap.description = entry["description"]
      cap.input_schema = entry["input_schema"]
      cap.contract_revision += 1 if !created && cap.input_schema_changed?
      cap.config = cap.config.merge("declared" => declared(entry), "version" => entry["version"]).compact
    end
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
    [ cap, outcome ]
  end

  # What a manifest entry does to the row's contract (PLUGINS.md, section 7).
  # Only an accepted row has one: a proposal follows the manifest. A
  # suspended row is held as it is until a person resumes it, and resuming
  # needs the manifest to serve a contract its accepted one still holds for.
  def contract_outcome(cap, entry, created:, resume:)
    return :created if created
    return :updated unless cap.accepted?

    problems = contract_problems(cap, entry)
    if cap.suspended?
      return :held unless resume

      schema = ContractDiff.breaking(cap.input_schema, entry["input_schema"])
      raise Error, "#{cap.name} still breaks its accepted contract (#{schema.join('; ')}); it stays suspended" if schema.any?

      return :resumed
    end
    problems.any? ? :suspended : :updated
  end

  # A breaking schema change, or a changed declaration of kind or realm:
  # either needs a person to look again.
  def contract_problems(cap, entry)
    problems = ContractDiff.breaking(cap.input_schema, entry["input_schema"])
    was = cap.config["declared"]
    now = declared(entry)
    if was.present?
      %w[kind realm].each do |key|
        problems << "it now declares #{key} #{now[key]} (was #{was[key]})" if was[key] != now[key]
      end
    end
    problems
  end

  def declared(entry)
    { "kind" => entry["kind"], "realm" => entry["realm"].presence || "household" }
  end

  # What the surface's rows sign with now, for a row refresh adds.
  def signing_config(surface)
    current = self.class.registered(surface).max_by(&:updated_at)
    current.config.slice("secret", "previous_secret", "previous_secret_until")
  end

  # Every row of the surface signs with `secret` from now on, and with the
  # secret it replaces too, until the overlap ends: after ROTATION_OVERLAP,
  # or, for an installation that signs its manifest, once its manifest says
  # it holds the new one (no previous_secret_until). If a rotation is still
  # waiting for that, the secret that last worked is the one kept.
  def rekey(plugin, secret)
    until_at = plugin.signed? ? nil : ROTATION_OVERLAP.from_now.iso8601
    self.class.registered(plugin.namespace).each do |cap|
      waiting = cap.config["previous_secret"].present? && cap.config["previous_secret_until"].blank?
      previous = waiting ? cap.config["previous_secret"] : cap.config["secret"]
      config = cap.config.merge("secret" => secret)
      config = if previous.present? && previous != secret
                 config.merge("previous_secret" => previous, "previous_secret_until" => until_at).compact
      else
                 config.except("previous_secret", "previous_secret_until")
      end
      cap.update!(config: config)
    end
  end

  # -> true when the credentials were handed to an app.
  def push(app, plugin, secret, plugin_key, restart)
    return false unless app

    coolify.set_env(app, self.class.env(plugin, secret, plugin_key), secret: [ SECRET_ENV, KEY_ENV ])
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

  # Suspension is immediate; the person hears why, and what would end it.
  def tell_suspended(surface, suspended)
    title = suspended.one? ? "hob: #{surface} broke #{suspended.first[0]}, now suspended" : "hob: #{surface} broke #{suspended.size} capabilities, now suspended"
    body = suspended.map { |name, why| "#{name}: #{why}\n  once it serves the accepted contract again: bin/rails \"hob:capabilities:resume[#{name}]\"" }
    Notify.person(title: title, tags: "warning", body: body.join("\n"))
  end

  def request_manifest(url, headers)
    (transport || SurfaceCapabilities.transport || method(:get)).call(url, headers)
  end

  def parse_manifest(url, body)
    data = JSON.parse(body.to_s)
    raise Error, "#{url} did not answer a manifest object" unless data.is_a?(Hash)

    data
  rescue JSON::ParserError
    raise Error, "#{url} did not answer JSON"
  end

  def get(url, headers)
    uri = URI(url)
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/json"
    headers.each { |name, value| request[name] = value }
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) do |http|
      http.request(request)
    end
    [ response.code, response.body, { SIGNATURE_HEADER => response[SIGNATURE_HEADER] }.compact ]
  rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, IOError => e
    raise Error, "#{uri.host} is unreachable: #{e.message}"
  end

  def coolify
    @coolify ||= Provision::Coolify.from_env
  end
end
