module Admin
  # Changing a herald key's permissions and scope (TEXTS.md; herald's
  # admin-only /v1/keys): what a key may do and which chats and people it
  # may see, without rotating its token. Unlike gofer, herald can list its
  # keys, so picking a herald shows them as herald has them now and "edit"
  # prefills the form from that. Every accepted change is logged to
  # HeraldKeyChange, with herald's own answer as the "before".
  class HeraldKeysController < BaseController
    PERMISSIONS = %w[read send].freeze

    helper_method :describe_key

    def new
      @backends = TextBackend.where(kind: "herald").order(:name)
      @history = HeraldKeyChange.recent.includes(:text_backend, :decider).limit(20)
      @backend_name = params[:backend]
      @key_name = params[:key_name]
      @permissions = Array(params[:permissions])
      @chats_raw = params[:chats]
      @handles_raw = params[:handles]
      @unscoped = params[:unscoped].present?
      load_keys! if @backend_name.present?
    end

    def update
      backend = TextBackend.find_by(kind: "herald", name: params[:backend])
      key_name = params[:key_name].to_s.strip
      permissions = Array(params[:permissions]).map(&:to_s) & PERMISSIONS
      scope, scope_error = self.class.parse_scope(params[:chats], params[:handles], unscoped: params[:unscoped].present?)
      back = { backend: params[:backend], key_name: params[:key_name], permissions: params[:permissions], chats: params[:chats],
               handles: params[:handles], unscoped: params[:unscoped].presence, edit: 1 }

      return redirect_to admin_herald_keys_path(back), alert: "Pick a herald." if backend.nil?
      return redirect_to admin_herald_keys_path(back), alert: "Enter the herald key's name." if key_name.blank?
      return redirect_to admin_herald_keys_path(back), alert: "Check read, send, or both: a key needs a permission." if permissions.empty?
      return redirect_to admin_herald_keys_path(back), alert: scope_error if scope_error

      admin_token = ENV["HERALD_ADMIN_TOKEN"]
      return redirect_to admin_herald_keys_path(back), alert: "HERALD_ADMIN_TOKEN is not set in hob's environment." if admin_token.blank?

      herald = backend.adapter
      before = herald.key(key_name, admin_token: admin_token)
      after = herald.update_key(key_name, permissions: permissions, scope: scope, admin_token: admin_token, actor: current_person.name)
      HeraldKeyChange.create!(text_backend: backend, key_name: key_name, decider: current_person,
                              key_before: before.slice("permissions", "scope"), key_after: after.slice("permissions", "scope"),
                              rationale: params[:rationale].presence)

      redirect_to admin_herald_keys_path(backend: backend.name),
                  notice: "Updated #{key_name} on #{backend.name}: #{describe_key(after)}."
    rescue Texts::NotFound => e
      redirect_to admin_herald_keys_path(back), alert: "herald: #{e.message}"
    rescue Texts::Invalid => e
      redirect_to admin_herald_keys_path(back), alert: "herald refused the change: #{e.message}"
    rescue Texts::Forbidden, Texts::Unavailable => e
      redirect_to admin_herald_keys_path(back), alert: e.message
    end

    # Chats and handles, one per line each, trimmed (herald matches handles
    # however they are written, so they are left as typed). A blank line
    # among them is rejected rather than dropped, as for gofer's domains.
    # Both empty needs `unscoped` checked: that opens the key to every chat,
    # a meaningfully different request from "nothing typed yet".
    def self.parse_scope(chats_raw, handles_raw, unscoped:)
      lists = { "chats" => chats_raw, "handles" => handles_raw }.transform_values { |raw| raw.to_s.split("\n").map(&:strip) }
      blank = lists.find { |_, entries| entries.any?(&:blank?) }
      return [ nil, "Remove the blank line among the #{blank.first}." ] if blank

      scope = lists.reject { |_, entries| entries.empty? }
      if scope.empty?
        return [ nil, nil ] if unscoped

        return [ nil, "Enter at least one chat or handle, or check “every chat” to remove this key's scope." ]
      end
      return [ nil, "“every chat” is checked; clear the chats and handles too, or uncheck it." ] if unscoped

      [ scope, nil ]
    end

    private

    def describe_key(key)
      scope = key["scope"]
      where = scope.blank? ? "every chat" : scope.map { |kind, values| "#{kind} #{values.join(', ')}" }.join("; ")
      "#{Array(key['permissions']).join(', ')}; #{where}"
    end

    # The picked herald's keys as it has them now. An "edit" link prefills
    # the form from one of them; a bounced form keeps what was typed.
    def load_keys!
      backend = @backends.find { |b| b.name == @backend_name }
      return @load_error = "No such herald." unless backend

      admin_token = ENV["HERALD_ADMIN_TOKEN"]
      return @load_error = "HERALD_ADMIN_TOKEN is not set in hob's environment, so herald's keys can't be read or changed." if admin_token.blank?

      @keys = backend.adapter.keys(admin_token: admin_token)
      prefill(@keys.find { |key| key["name"] == @key_name }) if params[:edit].blank?
    rescue Texts::Error => e
      @load_error = "Couldn't read #{backend.name}'s keys from herald: #{e.message}"
    end

    def prefill(key)
      return unless key

      @permissions = Array(key["permissions"])
      @chats_raw = Array(key.dig("scope", "chats")).join("\n")
      @handles_raw = Array(key.dig("scope", "handles")).join("\n")
      @unscoped = key["scope"].blank?
    end
  end
end
