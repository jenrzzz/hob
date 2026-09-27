module Browse
  module Backends
    # An in-memory browser with gofer's surface, for tests: a Site per
    # browser name holds pages by URL, each with a title, some text, and
    # links and fields by ref; sessions are tabs with a history. Domains are
    # held to the way gofer holds them: a navigation outside them is
    # refused and reported as `blocked`, and the tab stays put. It is a kind
    # only in the test environment (Browse::Backends registers it there).
    #
    #   site = Browse::Backends::Fake.site("mini")          # the row's name
    #   site.page("https://shop.test/", title: "Shop", text: "Welcome",
    #             links: { "e1" => "https://shop.test/orders" }, fields: %w[e2])
    #   Browse::Backends::Fake.fail!("mini", Browse::Unavailable.new("the mini is asleep"))
    #   Browse::Backends::Fake.reset!                          # in teardown
    class Fake < Base
      class Site
        attr_reader :pages, :sessions, :calls
        attr_accessor :error, :key_domains, :ttl

        def initialize
          @pages = {}
          @sessions = {}
          @calls = []
          @key_domains = []
          @ttl = 900
          @counter = 0
        end

        def page(url, title:, text: "", links: {}, fields: [])
          @pages[url] = { "title" => title, "text" => text, "links" => links, "fields" => fields }
        end

        def next_id
          "s#{@counter += 1}"
        end

        def expire!(remote_id)
          @sessions.fetch(remote_id)["closed"] = "session expired"
        end
      end

      class << self
        def sites
          @sites ||= Hash.new { |sites, name| sites[name] = Site.new }
        end

        def site(name)
          sites[name]
        end

        def fail!(name, error)
          sites[name].error = error
        end

        def reset!
          @sites = nil
        end
      end

      def self.config_errors(config)
        config.key?("domains") && !config["domains"].is_a?(Array) ? [ "domains must be an array" ] : []
      end

      def open(url:, domains:, ttl:, screenshot:, max_chars:)
        failing!
        site.calls << [ :open, url, domains ]
        guard = domains.presence || site.key_domains
        raise Browse::Invalid, "#{URI(url).host} is outside this key's domains" unless allowed?(guard, url)
        raise Browse::Unavailable, "4 sessions are open; close one first" if site.sessions.values.count { |s| !s["closed"] } >= 4

        session = { "id" => site.next_id, "domains" => guard, "history" => [ url ], "steps" => 0, "blocked" => nil,
                    "typed" => {}, "ttl" => ttl || site.ttl, "closed" => nil }
        site.sessions[session["id"]] = session
        state(session["id"], screenshot: screenshot, max_chars: max_chars)
      end

      def state(remote_id, screenshot:, max_chars:)
        failing!
        session = live(remote_id)
        page = site.pages[session["history"].last] || { "title" => "Not found", "text" => "nope", "links" => {}, "fields" => [] }
        snapshot = render(page)
        limit = max_chars || 60_000
        result = {
          "id" => remote_id, "url" => session["history"].last, "title" => page["title"], "domains" => session["domains"],
          "steps" => session["steps"], "snapshot" => snapshot.truncate(limit), "truncated" => snapshot.length > limit,
          "blocked" => session["blocked"], "expires_at" => (Time.now.utc + session["ttl"]).iso8601
        }
        result["screenshot"] = Base64.strict_encode64("\x89PNG fake #{page['title']}") if screenshot
        result
      end

      def act(remote_id, body)
        failing!
        session = live(remote_id)
        site.calls << [ :act, remote_id, body ]
        session["blocked"] = nil
        page = site.pages[session["history"].last] || {}
        text = nil
        case body["action"]
        when "navigate"
          # As gofer does: a navigate is checked before it is tried.
          raise Browse::Invalid, "#{URI(body['url']).host} is outside this key's domains" unless allowed?(session["domains"], body["url"])

          visit(session, body["url"])
        when "click"
          ref!(page, body["ref"])
          target = page.dig("links", body["ref"])
          visit(session, target) if target
        when "type"
          ref!(page, body["ref"])
          session["typed"][body["ref"]] = body["text"]
          visit(session, page.dig("links", body["ref"])) if body["submit"] && page.dig("links", body["ref"])
        when "select", "hover", "scroll" then ref!(page, body["ref"]) if body["ref"]
        when "back" then session["history"].pop if session["history"].size > 1
        when "read" then text = (body["ref"] ? "text of #{body['ref']}" : page["text"].to_s)
        end
        session["steps"] += 1
        state(remote_id, screenshot: body["screenshot"] == true, max_chars: body["max_chars"]).tap { |s| s["text"] = text if text }
      end

      def close(remote_id)
        failing!
        live(remote_id)["closed"] = "closed by the caller"
        true
      end

      def check
        failing!
        { "reachable" => true, "gofer" => "fake", "browser" => { "running" => true }, "sessions" => site.sessions.size }
      end

      private

      def site
        Fake.site(browser.name)
      end

      def failing!
        raise site.error if site.error
      end

      def live(remote_id)
        session = site.sessions[remote_id] or raise Browse::NotFound, "no such session"
        raise Browse::Gone, "session closed: #{session['closed']}" if session["closed"]

        session
      end

      def ref!(page, ref)
        raise Browse::Invalid, "ref is an element reference from the snapshot, like e12" unless ref.to_s.match?(/\A(f\d+)?e\d+\z/)
        return if page.dig("links", ref) || Array(page["fields"]).include?(ref)

        raise Browse::Invalid, "#{ref} is not on the page; take a fresh snapshot"
      end

      # A navigation outside the session's domains is refused in place.
      def visit(session, url)
        if allowed?(session["domains"], url)
          session["history"] << url
        else
          session["blocked"] = { "url" => url, "reason" => "#{URI(url).host} is outside this key's domains" }
        end
      end

      def allowed?(domains, url)
        return true if domains.blank?

        host = URI(url).host.to_s
        domains.any? { |d| bare = d.sub(/\A\*\./, ""); host == bare || host.end_with?(".#{bare}") }
      end

      def render(page)
        lines = [ "- document \"#{page['title']}\":" ]
        lines << "  - text: #{page['text']}" if page["text"].present?
        page["links"].each { |ref, url| lines << "  - link \"#{File.basename(url)}\" [ref=#{ref}]:" << "    - /url: #{url}" }
        Array(page["fields"]).each { |ref| lines << "  - textbox \"field\" [ref=#{ref}]" }
        lines.join("\n")
      end
    end
  end
end
