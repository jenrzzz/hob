require "net/http"

module Email
  module Backends
    # What an adapter answers, and what every adapter wants: config checks
    # and the wire. Email (the façade) has already validated what arrives
    # here: times are Times, addresses are { "name", "email" }, and message
    # and mailbox ids are the backend's own (native), with hob's "<backend>:"
    # prefix taken off. A mailbox may also arrive as a name, a path
    # ("Receipts/2026"), or a role ("inbox"), which the adapter resolves.
    # What goes back is the normalized shape in MAIL.md, string-keyed, with
    # the prefix put back on (`prefixed`).
    #
    #   mailboxes                               → [mailbox]
    #   search(filter, limit)                   → { "messages" => [summary], "total" => n }, newest first; each
    #                                             summary carries "_received" (a Time) the façade merges by
    #   message(id, headers:)                   → message: a summary with its body, headers, and attachments; with
    #                                             headers (:all, or lowercase names), its raw header fields too
    #   poll(state, mailbox)                    → { "state", "messages" => [summary], "more", "reset" }; a nil
    #                                             state is a first look: the state now, and no messages
    #   create_mailbox(name, parent)            → mailbox
    #   move(ids, to:, add:, remove:)           → { "messages" => [summary], "failed" => [{ id, error }] }
    #   send_message(to:, cc:, bcc:, subject:, body:, from:)            → summary of what was sent
    #   reply(id, body:, reply_all:, cc:, bcc:, quote:, from:)          → summary of what was sent
    #   check                                   → { "reachable" => true, ... } or raises
    #
    # An adapter raises Email::NotFound, Invalid, Forbidden, or Unavailable
    # and nothing else.
    class Base
      # Tests inject a lambda (verb, url, body, headers) -> [status, body, headers]
      # here, as they do with Calendars::Backends::Base.transport, so nothing
      # in the suite touches the network. One for every mail adapter.
      class_attribute :transport

      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 30
      MAX_BYTES = 20 * 1024 * 1024
      MAX_REDIRECTS = 3
      ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/

      attr_reader :backend

      # Problems with a row's config, as sentences.
      def self.config_errors(_config)
        []
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

      def initialize(backend)
        @backend = backend
      end

      %i[mailboxes search message poll create_mailbox move send_message reply check].each do |operation|
        define_method(operation) { |*, **| raise NotImplementedError, "#{self.class.name} does not implement #{operation}" }
      end

      private

      def prefixed(native)
        native.presence && "#{backend.name}:#{native}"
      end

      # The wire. Whatever goes wrong on the way there is the same answer:
      # not now. Redirects are followed for GETs (a session URL may bounce),
      # never for anything else. `max_bytes` only bounds hob's own `http`
      # fallback; a test's injected transport answers whatever it answers.
      def deliver(verb, url, body: nil, headers: {}, redirects: MAX_REDIRECTS, max_bytes: MAX_BYTES)
        status, response, response_headers =
          self.class.transport ? self.class.transport.call(verb, url, body, headers) : http(verb, url, body, headers, max_bytes)
        location = response_headers.to_h.transform_keys(&:downcase)["location"]
        if verb == "GET" && status.to_i.between?(301, 308) && location.present?
          raise Email::Unavailable, "#{backend.name}: too many redirects" if redirects.zero?

          return deliver(verb, URI.join(url, location).to_s, headers: headers, redirects: redirects - 1, max_bytes: max_bytes)
        end
        [ status.to_i, response.to_s ]
      rescue SocketError, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError, URI::InvalidURIError => e
        raise Email::Unavailable, "#{backend.name} unreachable: #{e.class.name.demodulize}: #{e.message}"
      end

      # No retries: Net::HTTP would quietly send a request a second time
      # after a read timeout, and a send sent twice is a message sent twice.
      # The body is read up to `max_bytes` and no further.
      def http(verb, url, body, headers, max_bytes = MAX_BYTES)
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
              raise Email::Unavailable, "#{backend.name} answered with more than #{max_bytes / 1024 / 1024} MB" if buffer.bytesize > max_bytes
            end
            return [ response.code, buffer, response.to_hash.transform_values(&:first) ]
          end
        end
      end
    end
  end
end
