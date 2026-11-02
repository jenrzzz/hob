require "net/http"
require "openssl"
require "uri"

module Hob
  # The plugin side of hob's plugin installations (hob's PLUGINS.md). hob
  # hands an installation HOB_PLUGIN_KEY, HOB_PLUGIN_ID (its namespace), and
  # HOB_PLUGIN_URL (where hob is), next to HOB_WEBHOOK_SECRET. The key signs
  # what the plugin tells hob:
  #
  # Its manifest. hob's GET /hob/capabilities carries X-Hob-Installation and
  # X-Hob-Nonce; answer with
  #
  #   body = JSON.generate(manifest)
  #   response.headers["X-Hob-Manifest-Signature"] = Hob::Plugin.sign_manifest(
  #     body: body, nonce: request.headers["X-Hob-Nonce"], revision: BOOTED_AT.to_i)
  #   render json: body
  #
  # `revision` must never go down: the process's boot time will do. The
  # signature also says which delivery secret the plugin holds, which is how
  # hob learns a rotation has landed and stops signing with the old one.
  #
  # Announcements: "re-read my manifest", after a deploy, say. hob refreshes
  # it, and anything new waits for a person to accept it.
  #
  #   Hob::Plugin.announce   # -> true when hob queued a refresh
  module Plugin
    MANIFEST = "hob-manifest.v1".freeze
    ANNOUNCE = "hob-announce.v1".freeze
    PATH = "/v1/plugins/announce".freeze

    class Error < StandardError; end

    module_function

    def configured?(env = ENV)
      [ "HOB_PLUGIN_KEY", "HOB_PLUGIN_ID" ].all? { |name| !env[name].to_s.empty? }
    end

    # Which delivery secret this is, without saying it.
    def delivery_key_id(secret)
      return "" if secret.to_s.empty?

      OpenSSL::Digest::SHA256.hexdigest("hob-delivery-key.v1\n#{secret}")[0, 16]
    end

    def sign_manifest(body:, nonce:, revision:, key: ENV["HOB_PLUGIN_KEY"], installation: ENV["HOB_PLUGIN_ID"],
                      delivery_secret: ENV["HOB_WEBHOOK_SECRET"])
      raise Error, "HOB_PLUGIN_KEY and HOB_PLUGIN_ID are not set" if key.to_s.empty? || installation.to_s.empty?
      raise Error, "revision must be a non-negative integer" unless revision.is_a?(Integer) && revision >= 0

      kid = delivery_key_id(delivery_secret)
      "rev=#{revision},kid=#{kid},v1=#{hmac(key, [ MANIFEST, installation, revision, nonce, kid, body ])}"
    end

    def sign_announcement(body:, key: ENV["HOB_PLUGIN_KEY"], installation: ENV["HOB_PLUGIN_ID"], timestamp: Time.now.to_i)
      "t=#{timestamp},v1=#{hmac(key, [ ANNOUNCE, installation, timestamp, body ])}"
    end

    # POSTs a signed announcement to hob. -> true on 202; raises Error otherwise.
    def announce(url: ENV["HOB_PLUGIN_URL"], key: ENV["HOB_PLUGIN_KEY"], installation: ENV["HOB_PLUGIN_ID"],
                 timeout: 10, transport: nil)
      raise Error, "HOB_PLUGIN_URL, HOB_PLUGIN_KEY, and HOB_PLUGIN_ID must all be set" if [ url, key, installation ].any? { |v| v.to_s.empty? }

      body = "{}"
      headers = { "Content-Type" => "application/json", "X-Hob-Installation" => installation,
                  "X-Hob-Signature" => sign_announcement(body: body, key: key, installation: installation) }
      target = "#{url.to_s.sub(%r{/+\z}, '')}#{PATH}"
      status, response = (transport || method(:post)).call(target, body, headers, timeout)
      return true if status.to_s == "202"

      raise Error, "hob answered HTTP #{status}: #{response}"
    end

    def hmac(key, parts)
      OpenSSL::HMAC.hexdigest("SHA256", key.to_s, parts.join("\n"))
    end

    def post(url, body, headers, timeout)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      headers.each { |name, value| request[name] = value }
      request.body = body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: timeout, read_timeout: timeout) do |http|
        http.request(request)
      end
      [ response.code, response.body ]
    rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, IOError => e
      raise Error, "hob is unreachable at #{uri.host}: #{e.message}"
    end
  end
end
