module Ward
  # The upstream watch (THREATS.md, Tier 0): for a threat awaiting a fix on
  # someone else's schedule, poll where that fix would appear and fire once
  # it has. Two places, answering THREATS.md's open question 3:
  #
  #   github     a repository's tags (Coolify's releases: coollabsio/coolify)
  #   dockerhub  an image's tags, newest first (library/php)
  #
  # Every poll goes out through Web, so it is held to the same rules as any
  # request hob makes to the internet. A poll is quiet: ward speaks only
  # when the fix lands. Default cadence is every six hours.
  #
  # upstream: { source, repository, current?, fixed?, poll_hours?, last_polled_at?, landed? }
  #   current  what runs now: only a newer tag counts
  #   fixed    the first version with the fix, when known: a tag at or past it fires
  module Upstream
    SOURCES = %w[github dockerhub].freeze
    POLL_HOURS = 6

    module_function

    def normalize!(spec)
      spec = (spec || {}).to_h.stringify_keys.slice("source", "repository", "current", "fixed", "poll_hours")
      raise Invalid, "upstream source must be one of #{SOURCES.join(', ')}" unless SOURCES.include?(spec["source"])
      raise Invalid, "upstream repository is required, like coollabsio/coolify" unless spec["repository"].to_s.match?(%r{\A[\w.-]+(/[\w.-]+)?\z})
      if spec["current"].blank? && spec["fixed"].blank?
        raise Invalid, "upstream needs current (what runs now) or fixed (the first version with the fix)"
      end

      spec["repository"] = "library/#{spec['repository']}" if spec["source"] == "dockerhub" && !spec["repository"].include?("/")
      spec["poll_hours"] = (spec["poll_hours"].presence || POLL_HOURS).to_i.clamp(1, 168)
      spec.compact_blank
    end

    def due?(upstream, now: Time.current)
      return false if upstream.blank? || upstream["landed"].present?

      last = upstream["last_polled_at"].presence && Time.zone.parse(upstream["last_polled_at"])
      last.nil? || last <= now - upstream.fetch("poll_hours", POLL_HOURS).to_i.hours
    end

    # -> { "tag", "version", "at" } when a fix has landed, else nil. Raises Ward::Error when the source cannot be read.
    def poll(upstream)
      tags = upstream["source"] == "github" ? github_tags(upstream["repository"]) : dockerhub_tags(upstream["repository"])
      pick(tags, current: upstream["current"], fixed: upstream["fixed"])
    end

    # The newest tag past `current`, and at or past `fixed`. A prerelease
    # counts only when what runs is one (Coolify's v4 betas).
    def pick(tags, current:, fixed:)
      floor = Versions.parse(Versions.from_tag(current) || current)
      fix = Versions.parse(Versions.from_tag(fixed) || fixed)
      prerelease_ok = floor&.prerelease? || fix&.prerelease?
      candidates = tags.filter_map do |tag|
        version = Versions.parse(Versions.from_tag(tag))
        next if version.nil? || (version.prerelease? && !prerelease_ok)
        next if floor && version <= floor
        next if fix && version < fix

        [ version, tag ]
      end
      version, tag = candidates.max_by(&:first)
      tag && { "tag" => tag, "version" => version.to_s, "at" => Time.current.utc.iso8601 }
    end

    def github_tags(repository)
      json("https://api.github.com/repos/#{repository}/tags?per_page=100", { "Accept" => "application/vnd.github+json" })
        .then { |rows| Array(rows).filter_map { |row| row["name"] if row.is_a?(Hash) } }
    end

    def dockerhub_tags(repository)
      json("https://hub.docker.com/v2/repositories/#{repository}/tags?page_size=100&ordering=last_updated", { "Accept" => "application/json" })
        .then { |data| Array(data.is_a?(Hash) ? data["results"] : nil).filter_map { |row| row["name"] if row.is_a?(Hash) } }
    end

    def json(url, headers)
      response = Web.get("url" => url, "headers" => headers, "raw" => true, "max_chars" => Web::MAX_CHARS)
      raise Ward::Error, "#{url}: HTTP #{response['status']}" unless response["ok"]
      raise Ward::Error, "#{url}: the answer was too long to read whole" if response["body_truncated"]

      JSON.parse(response["body"].to_s)
    rescue Web::Error => e
      raise Ward::Error, "#{url}: #{e.message}"
    rescue JSON::ParserError
      raise Ward::Error, "#{url}: not JSON"
    end
  end
end
