require "net/ssh"

module Shells
  module Backends
    # A login over ssh (net-ssh), one connection per command. hob offers
    # only the row's key, reads no ssh config, agent, or known_hosts of the
    # box it runs on, and connects only to a machine whose own key matches
    # the one pinned in the row (`hob:shell:trust`).
    #
    # A command that outlives its timeout is left behind: hob closes the
    # connection and says so. Without a terminal the far side does not
    # necessarily stop, which is also how a caller leaves something running
    # on purpose.
    class Ssh < Base
      CONNECT_TIMEOUT = 10
      CHECK = "uname -sr; id -un; hostname".freeze

      # Answers net-ssh's question about the machine's key: is it the one
      # pinned? With nothing pinned it refuses, unless told to accept what
      # it sees (trusting a host for the first time). Either way `seen` is
      # what the machine showed.
      class Pin
        attr_reader :seen

        def initialize(expected, accept: false)
          @expected = expected.to_s.split.last
          @accept = accept
        end

        def verify(arguments)
          @seen = "#{arguments[:key].ssh_type} #{arguments[:fingerprint]}"
          return @accept if @expected.blank?

          ActiveSupport::SecurityUtils.secure_compare(arguments[:fingerprint].to_s, @expected)
        end

        def verify_signature
          yield
        end
      end

      def self.config_errors(config)
        errors = []
        errors << "host is required: a hostname or an address" if config["host"].blank?
        errors << "host is a hostname or an address, nothing else" if config["host"].present? && !config["host"].to_s.match?(/\A[A-Za-z0-9.:_-]+\z/)
        errors << "user is required: the login" if config["user"].blank?
        errors << "user is a login name" if config["user"].present? && !config["user"].to_s.match?(/\A[A-Za-z_][A-Za-z0-9._-]*\z/)
        errors << "port is a port number" if config["port"].present? && !config["port"].to_s.match?(/\A\d{1,5}\z/)
        errors << "key_env or key is required: hob's private key for this login" if config["key"].blank? && config["key_env"].blank?
        errors << "host_key is a fingerprint, like ssh-ed25519 SHA256:..." if config["host_key"].present? && !config["host_key"].to_s.split.last.start_with?("SHA256:")
        errors
      end

      def exec(command, stdin: nil, timeout:, limit:)
        out = Shells::Capture.new(limit)
        err = Shells::Capture.new(limit)
        status = nil
        timed_out = false
        connect do |ssh|
          deadline = now + timeout
          channel = ssh.open_channel do |ch|
            ch.exec(command) do |_, started|
              raise Shells::Unavailable, "#{host.name} would not start the command" unless started

              ch.on_data { |_, data| out << data }
              ch.on_extended_data { |_, _, data| err << data }
              ch.on_request("exit-status") { |_, buffer| status = buffer.read_long }
              ch.send_data(stdin) if stdin.present?
              ch.eof!
            end
          end
          ssh.loop(0.2) do
            timed_out = now > deadline
            channel.active? && !timed_out
          end
        end
        { "exit" => status, "stdout" => out.to_s, "stderr" => err.to_s, "truncated" => out.truncated? || err.truncated?,
          "timed_out" => timed_out }
      end

      def check
        result = exec(CHECK, timeout: CONNECT_TIMEOUT, limit: 2_000)
        raise Shells::Unavailable, "#{host.name} did not answer a command: #{result['stderr'].to_s.strip.truncate(200)}" unless result["exit"]&.zero?

        system, user, hostname = result["stdout"].lines.map(&:strip)
        { "reachable" => true, "login" => host.login, "system" => system, "user" => user, "hostname" => hostname }
      end

      # The machine's key as it shows it now, "type SHA256:...", after a
      # login with hob's key: what `hob:shell:trust` pins.
      def scan
        pin = Pin.new(nil, accept: true)
        connect(pin) { |ssh| ssh.exec!("true") }
        pin.seen
      end

      private

      def connect(pin = nil)
        key = host.key or raise Shells::Forbidden, "#{host.name} has no key: " \
          "#{host.config['key_env'].present? ? "#{host.config['key_env']} is not set in this environment" : 'the row holds none'}"
        if pin.nil?
          raise Shells::Forbidden, "#{host.name} is not trusted yet: a person runs bin/rails \"hob:shell:trust[#{host.name}]\"" if host.host_key.blank?

          pin = Pin.new(host.host_key)
        end
        session = Net::SSH.start(host.address, host.user, **options(key, pin))
        begin
          yield session
        ensure
          # Not close: a command left running holds its channel open, and a
          # polite close would wait for it.
          session.shutdown!
        end
      rescue Net::SSH::AuthenticationFailed
        raise Shells::Forbidden, "#{host.name} refused hob's key for #{host.user}"
      rescue Net::SSH::ConnectionTimeout, Errno::ETIMEDOUT, Timeout::Error
        raise Shells::Unavailable, "#{host.name} did not answer at #{host.address}:#{host.port}"
      rescue SocketError, SystemCallError, IOError, Net::SSH::Disconnect => e
        raise Shells::Unavailable, "#{host.name} could not be reached: #{e.message}"
      rescue Net::SSH::Exception, OpenSSL::PKey::PKeyError, ArgumentError, NotImplementedError => e
        if pin.seen && host.host_key.present? && pin.seen.split.last != host.host_key.split.last
          raise Shells::Forbidden, "#{host.name} showed a different key (#{pin.seen}) than the one hob trusted " \
                                   "(#{host.host_key}); nothing was sent. A person checks the machine, then trusts it again"
        end
        raise Shells::Forbidden, "#{host.name}: hob's key for #{host.user} could not be read: #{e.message}" unless e.is_a?(Net::SSH::Exception)

        raise Shells::Unavailable, "#{host.name}: #{e.message}"
      end

      def options(key, pin)
        type = host.host_key.to_s.split.then { |parts| parts.size > 1 ? parts.first : nil }
        {
          port: host.port, key_data: [ key ], keys: [], keys_only: true, auth_methods: %w[publickey], use_agent: false,
          non_interactive: true, config: false, timeout: CONNECT_TIMEOUT, verify_host_key: pin,
          user_known_hosts_file: "/dev/null", global_known_hosts_file: "/dev/null", keepalive: true, keepalive_interval: 15,
          logger: Logger.new(IO::NULL), host_key: type && [ type ]
        }.compact
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
