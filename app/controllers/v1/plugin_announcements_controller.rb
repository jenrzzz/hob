module V1
  # A plugin installation asking hob to re-read its manifest (PLUGINS.md,
  # section 1): "my manifest changed", or "I have restarted with the
  # credentials you rotated". No bearer key: the installation's own key
  # (HOB_PLUGIN_KEY) signs the request (PluginSignature), and it reaches
  # this endpoint and nothing else, since it is not an ApiKey.
  #
  # POST /v1/plugins/announce
  #   X-Hob-Installation: <namespace>
  #   X-Hob-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(key, "hob-announce.v1\n<namespace>\n<t>\n<raw body>")>
  #   → 202 { queued }      a refresh is queued (or one was, within DEBOUNCE)
  #   → 401 { error }       the signature does not verify, or no such installation
  #   → 403 { error }       it has never signed its manifest, or is quarantined
  #
  # A ping that does not verify says nothing about the installation it names
  # (anyone can send one), so it is logged and rate-limited by address and
  # never touches the installation's row. The refresh itself verifies the
  # manifest it reads, so an announcement only ever authorizes a fetch.
  class PluginAnnouncementsController < ApplicationController
    skip_before_action :authenticate!, :gate_agents!
    skip_around_action :with_clearance
    rate_limit to: 30, within: 1.minute

    DEBOUNCE = 1.minute

    def create
      namespace = request.headers["X-Hob-Installation"].to_s
      plugin = Plugin.includes(:principal).find_by(namespace: namespace)
      body = request.raw_post.to_s
      key = plugin && PluginSignature.verify_announcement(request.headers["X-Hob-Signature"], keys: plugin.accepted_keys,
                                                                                            namespace: namespace, body: body)
      if key.nil?
        Rails.logger.warn("plugins: an announcement for #{namespace.inspect} from #{request.remote_ip} did not verify")
        return render json: { error: "signature does not verify" }, status: :unauthorized
      end
      return render json: { error: "#{namespace} is quarantined" }, status: :forbidden if plugin.quarantined?
      unless plugin.signed?
        return render json: { error: "#{namespace} has never signed its manifest: a person refreshes it" }, status: :forbidden
      end

      queued = Plugin.where(id: plugin.id).where("announced_at IS NULL OR announced_at < ?", DEBOUNCE.ago)
                     .update_all(announced_at: Time.current).positive?
      PluginRefreshJob.perform_later(plugin.namespace) if queued
      render json: { queued: true }, status: :accepted
    end
  end
end
