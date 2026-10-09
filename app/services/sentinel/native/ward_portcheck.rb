require "socket"

module Sentinel
  module Native
    # hob.ward.portcheck (WARD.md): one TCP connect check from the ward
    # worker's own network, so an agent can verify an exposure finding
    # without shell access to the house. `host` is never taken on the
    # agent's word: it must already be one of the literal addresses in
    # HOB_WARD_SCAN_TARGETS, the household's own list of what ward scans
    # (set alongside it, never by an agent). Because that list holds
    # addresses, not names, no DNS is ever resolved here — there is nothing
    # to rebind. One connect, up to two seconds of passive reading capped
    # at 256 bytes, then closed; nothing is sent, and nothing ward tracks
    # (findings, runs, schedules) is touched. The call itself, allowed or
    # rejected, is the sentinel request row — hob's audit log already.
    class WardPortcheck < Base
      # Raised when `host` is not in ward's inventory; "NotATarget" is the
      # word the spec and the agent should see in the failed request.
      class NotATarget < Error; end

      CAPABILITY = {
        "name" => "hob.ward.portcheck",
        "description" => "Run one TCP connect check from ward's vantage point against a host already in ward's scan " \
                         "inventory and a single port. Returns open, closed, or filtered, with an optional short " \
                         "passive banner.",
        "kind" => "read",
        "realm" => "personal",
        "input_schema" => {
          "type" => "object",
          "required" => %w[host port],
          "properties" => {
            "host" => { "type" => "string", "description" => "A host or address present in ward's configured exposure-scan targets" },
            "port" => { "type" => "integer", "minimum" => 1, "maximum" => 65_535 },
            "timeout" => { "type" => "integer", "default" => 10, "minimum" => 1, "maximum" => 30 },
            "finding_id" => { "type" => "string", "description" => "Optional ward finding this check verifies" }
          },
          "additionalProperties" => false
        }
      }.freeze

      KNOWN_ARGUMENTS = %w[host port timeout finding_id].freeze
      DEFAULT_TIMEOUT = 10
      MAX_TIMEOUT = 30
      BANNER_WAIT = 2     # seconds of passive reading
      BANNER_BYTES = 256  # kept at most
      NOTICE = "Checked from inside the household network; a public-IP check may hairpin and not reflect true " \
               "external exposure.".freeze

      # Tests inject a lambda (host, port, timeout) -> socket-like, raising
      # the same Errno a real connect would; nil means a real Socket.tcp.
      mattr_accessor :opener

      def self.scan_targets
        ENV["HOB_WARD_SCAN_TARGETS"].to_s.split(",").map { |h| h.strip.downcase }.reject(&:blank?)
      end

      def call
        known!
        host = target!(require_argument(:host))
        port = valid_port!(require_argument(:port))
        timeout = valid_timeout!(arguments["timeout"])

        state, banner = check(host, port, timeout)
        result = { "host" => host, "port" => port, "state" => state, "banner" => banner, "notice" => NOTICE,
                   "vantage" => vantage, "checked_at" => Time.current.utc.iso8601 }
        result["finding_id"] = arguments["finding_id"] if arguments["finding_id"].present?
        result
      end

      private

      def known!
        unknown = arguments.keys - KNOWN_ARGUMENTS
        raise Error, "unknown argument #{unknown.join(', ')} (known: #{KNOWN_ARGUMENTS.join(', ')})" if unknown.any?
      end

      # Never a name hob resolves: `host` must match, literally, an address
      # in HOB_WARD_SCAN_TARGETS. Anything else is not a target.
      def target!(host)
        host = host.to_s.strip
        raise NotATarget, "#{host.inspect} is not in ward's scan-target inventory (HOB_WARD_SCAN_TARGETS)" unless self.class.scan_targets.include?(host.downcase)

        host
      end

      def valid_port!(value)
        return value if value.is_a?(Integer) && (1..65_535).cover?(value)

        raise Error, "port must be a single integer between 1 and 65535, not #{value.inspect}"
      end

      def valid_timeout!(value)
        return DEFAULT_TIMEOUT if value.nil?
        return value if value.is_a?(Integer) && (1..MAX_TIMEOUT).cover?(value)

        raise Error, "timeout must be an integer between 1 and #{MAX_TIMEOUT} seconds, not #{value.inspect}"
      end

      def vantage
        "#{ENV.fetch('HOB_WARD_PRINCIPAL', 'ward')}@hob (internal)"
      end

      # One connect; a refusal is closed, a timeout (a dropped SYN, from in
      # here, looks like one) is filtered, and anything else that answers is
      # open. Nothing is ever written to the socket.
      def check(host, port, timeout)
        socket = open_socket(host, port, timeout)
        [ "open", passive_read(socket) ]
      rescue Errno::ECONNREFUSED
        [ "closed", nil ]
      rescue SystemCallError, IO::TimeoutError, Timeout::Error
        [ "filtered", nil ]
      ensure
        socket&.close
      end

      def open_socket(host, port, timeout)
        return self.class.opener.call(host, port, timeout) if self.class.opener

        Socket.tcp(host, port, connect_timeout: timeout)
      end

      def passive_read(socket)
        return nil unless IO.select([ socket ], nil, nil, BANNER_WAIT)

        data = socket.read_nonblock(BANNER_BYTES)
        return nil if data.blank?

        data.b.force_encoding("UTF-8").scrub
      rescue IO::WaitReadable, EOFError, Errno::ECONNRESET
        nil
      end
    end
  end
end
