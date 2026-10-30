module Ward
  # What the household runs, as the ward keeps it (THREATS.md, "Triage"):
  # pulled from Coolify's API with the ward's own read-only token, plus the
  # addresses ward scans. Coolify already knows its servers, applications,
  # services, databases, their images and tags, and its own version; what
  # answers on the wire is the cross-check, posted as observations by the
  # ward worker or a person (WardAsset#observe!).
  #
  # The token is HOB_WARD_COOLIFY_TOKEN, minted read-only for the ward and
  # never the write token provisioning holds (COOLIFY_TOKEN). The client
  # below can only GET.
  class Inventory
    # What an image implies beyond its own name: Coolify is PHP and Laravel.
    STACKS = { "coolify" => %w[php laravel] }.freeze
    # Images whose name is not the product they run, by repository.
    PRODUCTS = { "pgvector/pgvector" => %w[postgres pgvector] }.freeze
    # A last path segment that names a role, not a product: the namespace
    # is the product (vaultwarden/server is Vaultwarden).
    GENERIC = %w[server app web api core backend frontend service].freeze
    # Every host runs a kernel, and every container on it shares that one:
    # a host is a linux_kernel asset whose version the ward worker probes.
    HOST_COMPONENTS = { "linux_kernel" => nil }.freeze
    # A Coolify server runs Docker Engine, whose version Coolify reports.
    # NVD names it both ways: docker:docker and mobyproject:moby.
    ENGINE = %w[docker moby].freeze
    SYNC_EVERY = 1.hour

    # Coolify's API, read-only: there is no method here that writes.
    class Coolify
      def self.from_env
        url = ENV["HOB_WARD_COOLIFY_URL"].presence || ENV["COOLIFY_URL"]
        new(url: url, transport: Provision::Coolify::Transport.new(url: url, token: ENV["HOB_WARD_COOLIFY_TOKEN"]))
      rescue Provision::Error
        raise Ward::Error, "HOB_WARD_COOLIFY_URL (or COOLIFY_URL) and HOB_WARD_COOLIFY_TOKEN, the ward's read-only token, are not set"
      end

      attr_reader :url

      def initialize(transport:, url: nil)
        @transport = transport
        @url = url
      end

      def version
        answer = get("/version")
        answer.is_a?(Hash) ? (answer["version"] || answer["message"]).to_s.strip : answer.to_s.strip
      end

      %w[servers applications services databases].each do |kind|
        define_method(kind) { Array(get("/#{kind}")).select { |row| row.is_a?(Hash) } }
      end

      def service(uuid)
        get("/services/#{uuid}")
      end

      private

      def get(path)
        @transport.call(:get, path, nil)
      rescue Provision::Error => e
        raise Ward::Error, e.message
      end
    end

    def self.configured?
      (ENV["HOB_WARD_COOLIFY_URL"].presence || ENV["COOLIFY_URL"]).present? && ENV["HOB_WARD_COOLIFY_TOKEN"].present?
    end

    # When Coolify last answered a sync.
    def self.last_synced_at
      WardAsset.where(source: "coolify").maximum(:last_seen_at)
    end

    def self.due?(now: Time.current)
      configured? && (last_synced_at.nil? || last_synced_at <= now - SYNC_EVERY)
    end

    def self.sync!(client: nil, now: Time.current)
      new(client: client, now: now).sync!
    end

    # The kernel, and Docker Engine at the version Coolify last read off it.
    def self.host_components(server)
      settings = server["settings"].is_a?(Hash) ? server["settings"] : {}
      engine = Versions.from_tag(settings["docker_version"])
      HOST_COMPONENTS.merge(ENGINE.index_with { engine })
    end

    # "php:8.3.30-fpm" → { "php" => "8.3.30" }; "ghcr.io/coollabsio/coolify"
    # tagged 4.0.0-beta.420 → { "coolify" => "4.0.0-beta.420", "php" => nil, "laravel" => nil };
    # "vaultwarden/server" → { "vaultwarden" => nil }; "pgvector/pgvector:pg16" → { "postgres" => nil, "pgvector" => nil }.
    # The tag's version goes to the first product, the one the image is.
    def self.components_for(image, tag = nil)
      path, inline_tag = split_image(image)
      return {} if path.blank?

      names = products_of(path)
      found = { names.first => Versions.from_tag(tag.presence || inline_tag) }
      (names.drop(1) + STACKS.fetch(names.first, [])).each { |component| found[component] = nil unless found.key?(component) }
      found
    end

    # The repository without its registry ("ghcr.io/", "docker.io/library/"), then the product names.
    def self.products_of(path)
      parts = path.downcase.split("/")
      parts.shift if parts.size > 1 && parts.first.match?(/[.:]|\Alocalhost\z/)
      parts.shift if parts.first == "library" && parts.size > 1
      repository = parts.join("/")
      names = PRODUCTS[repository] || [ GENERIC.include?(parts.last) && parts.size > 1 ? parts[-2] : parts.last ]
      names.filter_map { |n| WardAsset.component_name(n) }
    end

    def self.split_image(image)
      image = image.to_s.strip.sub(/@.*\z/, "")
      head, _, last = image.rpartition("/")
      name, tag = last.split(":", 2)
      [ [ head.presence, name ].compact.join("/"), tag ]
    end

    def initialize(client:, now:)
      @client = client
      @now = now
    end

    # -> { "assets" => n, "gone" => n, "observations" => n }, or raises Ward::Error.
    def sync!
      client = @client || Coolify.from_env
      seen = []
      observed = 0
      servers = client.servers
      server_names = servers.to_h { |s| [ s["uuid"], s["name"] ] }

      WardAsset.transaction do
        version = client.version
        coolify = upsert("coolify", name: "coolify", kind: "control_plane", role: "control plane",
                                    host: ENV.fetch("HOB_WARD_COOLIFY_HOST", "cadance"), exposure: exposure_of_url(client.url),
                                    image: "ghcr.io/coollabsio/coolify", tag: version.presence,
                                    components: self.class.components_for("ghcr.io/coollabsio/coolify", version))
        seen << coolify.id
        observed += observe(coolify)

        servers.each do |server|
          asset = upsert("server:#{server['uuid']}", name: server["name"].presence || server["uuid"], kind: "host",
                                                     host: server["name"], exposure: exposure_of_ip(server["ip"]),
                                                     components: self.class.host_components(server), data: { "ip" => server["ip"] }.compact)
          seen << asset.id
          observed += observe(asset)
        end

        client.applications.each do |row|
          image = row["docker_registry_image_name"].presence
          asset = upsert("coolify:#{row['uuid']}", name: row["name"].presence || row["uuid"], kind: "application",
                                                   host: server_of(row, server_names), exposure: row["fqdn"].present? ? "public" : "tailnet",
                                                   image: image, tag: row["docker_registry_image_tag"].presence,
                                                   components: image ? self.class.components_for(image, row["docker_registry_image_tag"]) : {},
                                                   data: { "fqdn" => row["fqdn"].presence, "build_pack" => row["build_pack"] }.compact)
          seen << asset.id
          observed += observe(asset)
        end

        client.services.each do |row|
          row = client.service(row["uuid"]) if !row.key?("applications") && row["uuid"].present?
          images = (Array(row["applications"]) + Array(row["databases"])).filter_map { |part| part["image"].presence if part.is_a?(Hash) }
          public = row["fqdn"].present? || Array(row["applications"]).any? { |a| a.is_a?(Hash) && a["fqdn"].present? }
          asset = upsert("coolify:#{row['uuid']}", name: row["name"].presence || row["uuid"], kind: "service",
                                                   host: server_of(row, server_names), exposure: public ? "public" : "tailnet",
                                                   image: images.first, components: images.map { |i| self.class.components_for(i) }.reduce({}, :merge),
                                                   data: { "images" => images.presence }.compact)
          seen << asset.id
          observed += observe(asset)
        end

        client.databases.each do |row|
          image = row["image"].presence
          asset = upsert("coolify:#{row['uuid']}", name: row["name"].presence || row["uuid"], kind: "database",
                                                   host: server_of(row, server_names), exposure: row["is_public"] ? "public" : "localhost",
                                                   image: image, components: self.class.components_for(image))
          seen << asset.id
          observed += observe(asset)
        end

        seen.concat(sync_scan_targets)
      end

      gone = WardAsset.present.where(source: %w[coolify scan_target]).where.not(id: seen).update_all(gone_at: @now, updated_at: @now)
      { "assets" => seen.size, "gone" => gone, "observations" => observed, "patches" => patches(servers) }.compact
    end

    # Without a Coolify token, the scan targets alone.
    def sync_scan_targets
      Sentinel::Native::WardPortcheck.scan_targets.map do |address|
        upsert("target:#{address}", name: address, kind: "target", host: address, exposure: "public", source: "scan_target").id
      end
    end

    private

    # The patches check from the same servers; its failure is not the inventory's.
    def patches(servers)
      run = Patches.ingest!(servers, now: @now)
      run && run.id
    rescue StandardError => e
      Rails.logger.error("ward patches: #{e.class}: #{e.message}")
      "error: #{e.message.truncate(200)}"
    end

    def upsert(ref, source: "coolify", **attrs)
      asset = WardAsset.find_or_initialize_by(ref: ref)
      asset.assign_attributes(attrs.merge(source: source, last_seen_at: @now, gone_at: nil))
      asset.save!
      asset
    end

    def observe(asset)
      asset.components.count do |component, version|
        next false if version.blank?

        asset.observe!(component: component, version: version, source: "coolify", digest: asset.digest, at: @now)
      end
    end

    def server_of(row, names)
      uuid = row.dig("destination", "server", "uuid") || row["server_uuid"] || row.dig("server", "uuid")
      row.dig("destination", "server", "name") || row.dig("server", "name") || names[uuid]
    end

    def exposure_of_url(url)
      host = URI(url.to_s).host.to_s
      return "tailnet" if host.end_with?(".ts.net")

      exposure_of_ip(host) || "public"
    rescue URI::InvalidURIError
      "public"
    end

    def exposure_of_ip(address)
      ip = IPAddr.new(address.to_s)
      return "localhost" if ip.loopback?

      Web.blocked_ip?(ip) ? "tailnet" : "public"
    rescue IPAddr::InvalidAddressError
      nil
    end
  end
end
