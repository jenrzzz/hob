module Admin
  # Editing a gofer key's domain allowlist (BROWSE.md, gofer's admin-only
  # PATCH /v1/keys/:name): widens or narrows where a browsing key may go,
  # without rotating its token. gofer has no endpoint to read an arbitrary
  # named key's domains, so the form starts blank unless "load" prefills it
  # from what a browser row's own bearer key can say about itself (GET
  # /v1/status — real prefill, when that's the key being edited, not a
  # guess). Every accepted change is logged to GoferKeyChange, the audited
  # path this closes.
  class GoferKeysController < BaseController
    def new
      @browsers = Browser.where(kind: "gofer").order(:name)
      @history = GoferKeyChange.recent.includes(:browser, :decider).limit(20)
      @browser_name = params[:browser]
      @key_name = params[:key_name]
      @domains_raw = params[:domains]
      @unrestricted = params[:unrestricted].present?
      load_current! if params[:load].present? && @browser_name.present?
    end

    def update
      browser = Browser.find_by(kind: "gofer", name: params[:browser])
      key_name = params[:key_name].to_s.strip
      domains, domain_error = self.class.parse_domains(params[:domains], unrestricted: params[:unrestricted].present?)
      back = { browser: params[:browser], key_name: params[:key_name], domains: params[:domains], unrestricted: params[:unrestricted].presence }

      return redirect_to admin_gofer_keys_path(back), alert: "Pick a gofer browser." if browser.nil?
      return redirect_to admin_gofer_keys_path(back), alert: "Enter the gofer key's name." if key_name.blank?
      return redirect_to admin_gofer_keys_path(back), alert: domain_error if domain_error

      admin_token = ENV["GOFER_ADMIN_TOKEN"]
      return redirect_to admin_gofer_keys_path(back), alert: "GOFER_ADMIN_TOKEN is not set in hob's environment." if admin_token.blank?

      result = Browse::Backends::Gofer.new(browser).update_key_domains(key_name, domains, admin_token: admin_token, actor: current_person.name)

      last = GoferKeyChange.where(browser: browser, key_name: key_name).recent.first
      change = GoferKeyChange.create!(browser: browser, key_name: key_name, decider: current_person,
                                      domains_before: last&.domains_after, domains_after: result["domains"],
                                      rationale: params[:rationale].presence)

      redirect_to admin_gofer_keys_path(browser: browser.name, key_name: key_name),
                  notice: "Updated #{key_name}'s domains on #{browser.name}: #{describe_domains(change.domains_after)}."
    rescue Browse::NotFound => e
      redirect_to admin_gofer_keys_path(back), alert: "gofer: #{e.message}"
    rescue Browse::Invalid => e
      redirect_to admin_gofer_keys_path(back), alert: "gofer rejected the domains: #{e.message}"
    rescue Browse::Forbidden => e
      redirect_to admin_gofer_keys_path(back), alert: "gofer refused the admin credentials: #{e.message}"
    rescue Browse::Unavailable => e
      redirect_to admin_gofer_keys_path(back), alert: e.message
    end

    # Domains, one per line, trimmed and lowercased like gofer's own
    # normalization (API.md). A blank line among typed domains is rejected
    # rather than silently dropped — it's more likely a stray keystroke
    # than intent. An empty list needs `unrestricted` checked, since that's
    # what clears a key's allowlist entirely (a meaningfully different,
    # security-relevant request, not just "nothing typed yet").
    def self.parse_domains(raw, unrestricted:)
      entries = raw.to_s.split("\n").map(&:strip)
      return [ nil, "Remove the blank line among the domains." ] if entries.any?(&:blank?)

      domains = entries.map(&:downcase)
      if domains.empty?
        return [ [], nil ] if unrestricted

        return [ nil, "Enter at least one domain, or check “unrestricted” to clear this key's allowlist." ]
      end
      return [ nil, "“unrestricted” is checked; clear the domains field too, or uncheck it." ] if unrestricted

      [ domains, nil ]
    end

    private

    def describe_domains(domains)
      domains.presence&.join(", ") || "unrestricted"
    end

    def load_current!
      browser = @browsers.find { |b| b.name == @browser_name }
      return @load_error = "No such gofer browser." unless browser

      key = browser.adapter.check["gofer_key"]
      return @load_error = "gofer didn't say which key #{browser.name} is using." unless key

      @key_name = key["name"]
      @domains_raw = Array(key["domains"]).join("\n")
    rescue Browse::Error => e
      @load_error = "Couldn't read #{browser.name}'s current key from gofer: #{e.message}"
    end
  end
end
