require "net/http"

module Budgets
  module Backends
    # YNAB, by way of its API (api.ynab.com/v1): this class is the whole of
    # what hob knows of it. A backend row is one YNAB *plan* (what YNAB called
    # a budget until its API renamed them), reached with a personal access
    # token, which sees every plan its owner has: the row's `plan` is what
    # confines hob to one.
    #
    #   amounts  YNAB counts in milliunits (-12340 is -12.34); the contract
    #            counts in the currency, so they are converted at this edge
    #   tags     YNAB has none. A transaction's tags are the #hashtags in its
    #            memo, which is where YNAB's own users keep them: they show in
    #            the app, and its search finds them. Writing tags edits the memo
    #   flag     YNAB's one-of-six colored flag; a color's custom name rides
    #            along on reads as `flag_name`
    #   splits   a split transaction has no category of its own; its parts do
    #
    # YNAB allows a token 200 requests an hour. A read is one request; a write
    # that names an account or category by name spends another to look it up,
    # and one that edits tags without giving the memo spends one to read it.
    class Ynab < Base
      # Tests inject a lambda (verb, url, body, headers) -> [status, body]
      # here, as they do with Todos::Backends::Omnifocus.transport, so nothing
      # in the suite touches the network.
      class_attribute :transport

      URL = "https://api.ynab.com/v1".freeze
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 30
      CONFIG_KEYS = %w[plan key key_env time_zone].freeze
      ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/
      PLAN = /\A[A-Za-z0-9-]+\z/ # a uuid, or YNAB's own "last-used" and "default"
      HASHTAG = /(?<!\S)#(\p{L}[\p{L}\p{N}_-]*)/

      def self.config_errors(config)
        errors = []
        unknown = config.keys - CONFIG_KEYS
        errors << "has unknown keys #{unknown.join(', ')} (known: #{CONFIG_KEYS.join(', ')})" if unknown.any?
        errors << "needs a plan: the YNAB plan's id (hob:budget:plans lists them)" unless config["plan"].to_s.match?(PLAN)
        errors << "needs a key or a key_env: a YNAB personal access token" if config["key"].blank? && config["key_env"].blank?
        errors << "takes a key or a key_env, not both" if config["key"].present? && config["key_env"].present?
        # A key_env comes back out in every response, so a token put there by
        # mistake would be published. The value is not echoed in the error.
        if config["key_env"].present? && !config["key_env"].to_s.match?(ENV_NAME)
          errors << "key_env names an environment variable (like YNAB_TOKEN); the token itself goes in key"
        end
        if config["time_zone"].present? && ActiveSupport::TimeZone[config["time_zone"].to_s].nil?
          errors << "time_zone is not a time zone hob knows (try America/Los_Angeles)"
        end
        errors
      end

      # The plans a token can see, for choosing one before there is a row.
      def self.plans(key)
        new(BudgetBackend.new(name: "ynab", kind: "ynab", config: { "key" => key, "plan" => "last-used" })).send(:plans)
      end

      def accounts
        get("#{plan}/accounts").fetch("accounts", []).reject { |data| data["deleted"] }.map { |data| account(data) }
      end

      def categories(month)
        data = get("#{plan}/months/#{escape(month)}").fetch("month", {})
        { "month" => { "month" => data["month"], "ready_to_assign" => units(data["to_be_budgeted"]), "income" => units(data["income"]),
                       "assigned" => units(data["budgeted"]), "activity" => units(data["activity"]),
                       "age_of_money" => data["age_of_money"] },
          "categories" => Array(data["categories"]).reject { |row| row["deleted"] }.map { |row| category(row) } }
      end

      # YNAB narrows by date and by one `type`; the façade does the rest.
      def transactions(filters)
        query = { "since_date" => filters["since"], "until_date" => filters["until"],
                  "type" => ("uncategorized" if filters["uncategorized"]) || ("unapproved" if filters["unapproved"]) }.compact
        get("#{plan}/transactions", query).fetch("transactions", [])
          .reject { |data| data["deleted"] || (filters["until"] && data["date"].to_s > filters["until"]) }
          .map { |data| transaction(data) }
      end

      def find(id)
        transaction(get("#{plan}/transactions/#{escape(id)}").fetch("transaction"))
      end

      # Nothing is addressed on a create but the plan, so whatever YNAB could
      # not find was named in the body: the caller's mistake.
      def create(attributes)
        body = transaction_body(attributes).merge("account_id" => account_id(attributes["account"]))
        body["memo"] = retag(attributes["memo"], attributes) if attributes.key?("memo") || attributes.key?("tags")
        transaction(post("#{plan}/transactions", "transaction" => body).fetch("transaction"))
      rescue Budgets::NotFound => e
        raise Budgets::Invalid, e.message
      end

      # YNAB's PUT changes what it is given and leaves the rest. Tags live in
      # the memo, so editing them without replacing it means reading it first.
      def update(id, attributes)
        body = transaction_body(attributes)
        if (attributes.keys & Budgets::TAG_LISTS).any? || attributes.key?("memo")
          memo = attributes.key?("memo") ? attributes["memo"] : find(id)["memo"]
          body["memo"] = retag(memo, attributes)
        end
        transaction(put("#{plan}/transactions/#{escape(id)}", "transaction" => body).fetch("transaction"))
      end

      # GET /plans: YNAB answers, the token is good, and the plan is one it sees.
      def check
        seen = plans
        mine = seen.find { |candidate| candidate["id"] == backend.config["plan"] }
        if mine.nil? && backend.config["plan"].to_s.match?(/\A\h{8}-/)
          raise Budgets::NotFound, "#{backend.name}'s token sees no plan #{backend.config['plan']} " \
                                   "(it sees: #{seen.map { |candidate| "#{candidate['name']} #{candidate['id']}" }.join('; ')})"
        end

        { "reachable" => true, "plan" => mine || backend.config["plan"], "plans_visible_to_token" => seen.size }
      end

      private

      # --- hob → YNAB ---

      def plan
        "/plans/#{escape(backend.config['plan'])}"
      end

      def transaction_body(attributes)
        body = attributes.slice("date", "cleared", "approved").compact
        body["amount"] = milliunits(attributes["amount"]) if attributes["amount"]
        body["flag_color"] = attributes["flag"] if attributes.key?("flag")
        # YNAB resolves a payee by name (or makes one) only when the id is null.
        body.merge!("payee_id" => nil, "payee_name" => attributes["payee"]) if attributes.key?("payee")
        body["category_id"] = attributes["category"] && category_id(attributes["category"]) if attributes.key?("category")
        if attributes["splits"]
          body["category_id"] = nil
          body["subtransactions"] = attributes["splits"].map { |split| split_body(split) }
        end
        body
      end

      def split_body(split)
        { "amount" => milliunits(split["amount"]), "memo" => split["memo"].presence,
          "category_id" => split["category"] && category_id(split["category"]) }.tap do |body|
          body.merge!("payee_id" => nil, "payee_name" => split["payee"]) if split["payee"]
        end
      end

      def milliunits(amount)
        milli = amount * 1000
        raise Budgets::Invalid, "YNAB counts to a thousandth: #{amount.to_s('F')} is finer than that" unless milli.frac.zero?

        milli.to_i
      end

      def account_id(value)
        kind, wanted = reference(value)
        return wanted if kind == :id

        @accounts ||= get("#{plan}/accounts").fetch("accounts", []).reject { |account| account["deleted"] }
        the_one(@accounts.select { |account| account["name"].to_s.casecmp?(wanted) }, @accounts, "account", wanted)
      end

      # A category by its name, or "<group>: <name>" when two groups share one.
      def category_id(value)
        kind, wanted = reference(value)
        return wanted if kind == :id

        @categories ||= get("#{plan}/categories").fetch("category_groups", []).flat_map do |group|
          Array(group["categories"]).reject { |category| category["deleted"] }
                                    .map { |category| category.merge("name" => category["name"].to_s, "path" => "#{group['name']}: #{category['name']}") }
        end
        the_one(@categories.select { |category| category["name"].casecmp?(wanted) || category["path"].casecmp?(wanted) },
                @categories, "category", wanted)
      end

      def the_one(matches, all, what, wanted)
        return matches.first["id"] if matches.size == 1
        raise Budgets::Invalid, "#{what} #{wanted.inspect} is ambiguous (candidates: #{labels(matches, 'path', ids: true)})" if matches.size > 1

        raise Budgets::Invalid, "no #{what} named #{wanted.inspect} in #{backend.name} (there: #{labels(all, 'name')})"
      end

      def labels(things, field, ids: false)
        things.map { |thing| [ thing[field] || thing["name"], (prefixed(thing["id"]) if ids) ].compact.join(" ") }.join("; ")
      end

      # The memo with its hashtags brought in line: `tags` replaces them all,
      # `remove_tags` and `add_tags` adjust. The words around them are kept.
      def retag(memo, attributes)
        drop = attributes.key?("tags") ? :all : Array(attributes["remove_tags"]).map(&:downcase)
        text = memo.to_s.gsub(HASHTAG) { drop == :all || drop.include?(Regexp.last_match(1).downcase) ? "" : Regexp.last_match(0) }
        text = text.gsub(/[ \t]{2,}/, " ").strip
        carried = tags_in(text).map(&:downcase)
        adding = [ *attributes["tags"], *attributes["add_tags"] ].reject { |tag| carried.include?(tag.downcase) }
        text = [ text.presence, *adding.map { |tag| "##{tag}" } ].compact.join(" ")
        if text.length > Budgets::MEMO_LIMIT
          raise Budgets::Invalid, "memo and tags come to #{text.length} characters; YNAB keeps #{Budgets::MEMO_LIMIT}"
        end

        text
      end

      # --- YNAB → hob ---

      def tags_in(memo)
        memo.to_s.scan(HASHTAG).flatten.uniq(&:downcase)
      end

      def units(milli)
        milli.nil? ? nil : milli / 1000.0
      end

      def thing(id, name)
        id.present? ? { "id" => prefixed(id), "name" => name } : nil
      end

      def transaction(data)
        splits = Array(data["subtransactions"]).reject { |split| split["deleted"] }
        {
          "id" => prefixed(data["id"]), "backend" => backend.name, "date" => data["date"], "amount" => units(data["amount"]),
          "payee" => data["payee_name"], "account" => thing(data["account_id"], data["account_name"]),
          "category" => splits.any? ? nil : thing(data["category_id"], data["category_name"]),
          "memo" => data["memo"].to_s, "tags" => tags_in(data["memo"]),
          "flag" => data["flag_color"].presence, "flag_name" => data["flag_name"].presence,
          "cleared" => data["cleared"], "approved" => data["approved"] ? true : false,
          "transfer_account_id" => prefixed(data["transfer_account_id"]), "imported" => data["import_id"].present?,
          "splits" => splits.map do |split|
            { "amount" => units(split["amount"]), "payee" => split["payee_name"],
              "category" => thing(split["category_id"], split["category_name"]), "memo" => split["memo"].to_s }
          end
        }
      end

      def account(data)
        { "id" => prefixed(data["id"]), "backend" => backend.name, "name" => data["name"], "kind" => data["type"],
          "on_budget" => data["on_budget"] ? true : false, "closed" => data["closed"] ? true : false,
          "balance" => units(data["balance"]), "cleared_balance" => units(data["cleared_balance"]),
          "uncleared_balance" => units(data["uncleared_balance"]), "last_reconciled_at" => data["last_reconciled_at"],
          "import_broken" => data["direct_import_in_error"] ? true : false, "note" => data["note"].to_s }
      end

      def category(data)
        { "id" => prefixed(data["id"]), "backend" => backend.name, "name" => data["name"], "group" => data["category_group_name"],
          "assigned" => units(data["budgeted"]), "activity" => units(data["activity"]), "available" => units(data["balance"]),
          "goal_target" => units(data["goal_target"]), "goal_under_funded" => units(data["goal_under_funded"]),
          "hidden" => data["hidden"] ? true : false, "note" => data["note"].to_s }
      end

      def plans
        get("/plans").fetch("plans", []).map do |data|
          { "id" => data["id"], "name" => data["name"], "currency" => data.dig("currency_format", "iso_code"),
            "last_modified_on" => data["last_modified_on"] }
        end
      end

      # --- the wire ---

      def get(path, query = nil)
        path = "#{path}?#{URI.encode_www_form(query)}" if query.present?
        request("GET", path)
      end

      def post(path, body)
        request("POST", path, body)
      end

      def put(path, body)
        request("PUT", path, body)
      end

      # -> YNAB's `data`, out of its envelope.
      def request(verb, path, body = nil)
        key = backend.key
        raise Budgets::Unavailable, "#{backend.name} has no key: #{key_hint}" if key.blank?

        headers = { "Authorization" => "Bearer #{key}", "Accept" => "application/json" }
        headers["Content-Type"] = "application/json" if body
        status, response = deliver(verb, "#{URL}#{path}", body && JSON.generate(body), headers)
        parsed = parse(response)
        return parsed["data"].is_a?(Hash) ? parsed["data"] : {} if status.to_s.start_with?("2")

        raise error_for(status.to_i, parsed)
      end

      def key_hint
        backend.config["key_env"].present? ? "#{backend.config['key_env']} is not set in hob's environment" : "set config.key or config.key_env"
      end

      # Whatever goes wrong on the way there is the same answer: not now.
      def deliver(verb, url, body, headers)
        (self.class.transport || method(:http)).call(verb, url, body, headers)
      rescue SocketError, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
        raise Budgets::Unavailable, "YNAB unreachable: #{e.class.name.demodulize}: #{e.message}"
      end

      # No retries: Net::HTTP would quietly send a request a second time after
      # a read timeout, and a POST sent twice is a transaction entered twice.
      def http(verb, url, body, headers)
        uri = URI(url)
        req = Net::HTTP.const_get(verb.capitalize).new(uri)
        headers.each { |name, value| req[name] = value }
        req.body = body if body
        connection = Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.use_ssl = true
          http.open_timeout = OPEN_TIMEOUT
          http.read_timeout = READ_TIMEOUT
          http.max_retries = 0
        end
        response = connection.start { |session| session.request(req) }
        [ response.code, response.body ]
      end

      def parse(body)
        return {} if body.blank?

        data = JSON.parse(body)
        data.is_a?(Hash) ? data : {}
      rescue JSON::ParserError
        { "error" => { "detail" => body.to_s.truncate(200) } }
      end

      # YNAB's { error: { id, name, detail } } as one of ours.
      def error_for(status, parsed)
        error = parsed["error"].is_a?(Hash) ? parsed["error"] : {}
        detail = error["detail"].presence || error["name"].presence
        case status
        when 404 then Budgets::NotFound.new(detail || "YNAB found nothing there")
        when 400, 409, 422 then Budgets::Invalid.new(detail || "YNAB refused the request (HTTP #{status})")
        when 401, 403 then Budgets::Forbidden.new("YNAB refused #{backend.name}'s token: #{detail || "HTTP #{status}"}")
        when 429 then Budgets::Unavailable.new("YNAB's limit of 200 requests an hour is spent for #{backend.name}'s token; it refills within the hour")
        when 500..599 then Budgets::Unavailable.new("YNAB failed with HTTP #{status}#{detail && ": #{detail}"}")
        else Budgets::Error.new("YNAB answered HTTP #{status}#{detail && ": #{detail}"}")
        end
      end

      def escape(id)
        ERB::Util.url_encode(id.to_s)
      end
    end
  end
end
