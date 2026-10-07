require "net/http"

module Calendars
  module Backends
    # What an adapter answers, and what every adapter wants: config checks
    # and the wire. Calendars (the façade) has already validated what
    # arrives here: `from` and `to` are Times, calendar ids are the
    # backend's own (native) ids with hob's "<backend>:" prefix taken off.
    # What goes back is the normalized shape in CALENDARS.md, string-keyed,
    # with the prefix put back on (`prefixed`).
    #
    #   calendars                     → [calendar]
    #   events(from, to, calendars)   → [event] overlapping from...to, each with "_starts" and "_ends"
    #                                   (Times) the façade sorts by; `calendars` is nil for all of them
    #   check                         → { "reachable" => true, ... } or raises
    #
    # An adapter raises Calendars::NotFound, Invalid, Forbidden, or
    # Unavailable and nothing else.
    class Base
      # Tests inject a lambda (verb, url, body, headers) -> [status, body, headers]
      # here, as they do with Budgets::Backends::Ynab.transport, so nothing in
      # the suite touches the network. One for every calendar adapter.
      class_attribute :transport

      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 30
      MAX_BYTES = 10 * 1024 * 1024 # a calendar's whole history as one file; past this it is not a calendar
      MAX_REDIRECTS = 3
      ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/
      SHARED_CONFIG = %w[time_zone visibility].freeze
      VISIBILITIES = %w[details free_busy].freeze

      attr_reader :backend

      # Problems with a row's config, as sentences.
      def self.config_errors(config)
        errors = []
        if config["time_zone"].present? && ActiveSupport::TimeZone[config["time_zone"].to_s].nil?
          errors << "time_zone is not a time zone hob knows (try America/Los_Angeles)"
        end
        if config["visibility"].present? && !VISIBILITIES.include?(config["visibility"])
          errors << "visibility is details or free_busy, not #{config['visibility'].inspect}"
        end
        errors
      end

      # `name` or `name_env`, exactly one. A `*_env` comes back out in every
      # response, so a secret put there by mistake would be published; the
      # value is not echoed in the error.
      def self.secret_errors(config, name, what, example)
        errors = []
        errors << "needs a #{name} or a #{name}_env: #{what}" if config[name].blank? && config["#{name}_env"].blank?
        errors << "takes a #{name} or a #{name}_env, not both" if config[name].present? && config["#{name}_env"].present?
        if config["#{name}_env"].present? && !config["#{name}_env"].to_s.match?(ENV_NAME)
          errors << "#{name}_env names an environment variable (like #{example}); the #{what} itself goes in #{name}"
        end
        errors
      end

      def self.unknown_errors(config, known)
        unknown = config.keys - known
        unknown.any? ? [ "has unknown keys #{unknown.join(', ')} (known: #{known.join(', ')})" ] : []
      end

      # A URL as it may be shown: scheme and host, nothing that could be a token.
      def self.redact(url)
        uri = URI(url.to_s.sub(/\Awebcal:/i, "https:"))
        uri.host ? "#{uri.scheme}://#{uri.host}/…" : "set"
      rescue URI::InvalidURIError
        "set"
      end

      def initialize(backend)
        @backend = backend
      end

      %i[calendars events check].each do |operation|
        define_method(operation) { |*| raise NotImplementedError, "#{self.class.name} does not implement #{operation}" }
      end

      private

      def prefixed(native)
        native.presence && "#{backend.name}:#{native}"
      end

      def zone
        backend.time_zone
      end

      # The wire. Whatever goes wrong on the way there is the same answer:
      # not now. Redirects are followed for GETs (feeds move, and webcal
      # links bounce), never for anything else.
      def deliver(verb, url, body: nil, headers: {}, redirects: MAX_REDIRECTS)
        status, response, response_headers = (self.class.transport || method(:http)).call(verb, url, body, headers)
        location = response_headers.to_h.transform_keys(&:downcase)["location"]
        if verb == "GET" && status.to_i.between?(301, 308) && location.present?
          raise Calendars::Unavailable, "#{backend.name}: too many redirects" if redirects.zero?

          return deliver(verb, URI.join(url, location).to_s, headers: headers, redirects: redirects - 1)
        end
        [ status.to_i, response.to_s ]
      rescue SocketError, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError, URI::InvalidURIError => e
        raise Calendars::Unavailable, "#{backend.name} unreachable: #{e.class.name.demodulize}: #{e.message}"
      end

      # No retries: a hung server should not hang a request twice over. The
      # body is read up to MAX_BYTES and no further.
      def http(verb, url, body, headers)
        uri = URI(url)
        req = Net::HTTPGenericRequest.new(verb, !body.nil?, verb != "HEAD", uri.request_uri)
        headers.each { |name, value| req[name] = value }
        req["Host"] = uri.host
        req.body = body if body
        connection = Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = OPEN_TIMEOUT
          http.read_timeout = READ_TIMEOUT
          http.max_retries = 0
        end
        connection.start do |session|
          session.request(req) do |response|
            buffer = +""
            response.read_body do |chunk|
              buffer << chunk
              raise Calendars::Unavailable, "#{backend.name} answered with more than #{MAX_BYTES / 1024 / 1024} MB" if buffer.bytesize > MAX_BYTES
            end
            return [ response.code, buffer, response.to_hash.transform_values(&:first) ]
          end
        end
      end

      # A feed or a calendar that has gone away is the backend's trouble, not
      # the caller's, so it is Unavailable (named in a merged read's
      # `unavailable`) rather than NotFound.
      def status_error(status, what)
        case status
        when 404, 410 then Calendars::Unavailable.new("#{what} found nothing there (HTTP #{status}): has it moved?")
        when 401, 403 then Calendars::Forbidden.new("#{what} refused #{backend.name}'s credentials (HTTP #{status})")
        when 429, 500..599 then Calendars::Unavailable.new("#{what} failed with HTTP #{status}")
        else Calendars::Unavailable.new("#{what} answered HTTP #{status}")
        end
      end
    end
  end
end
