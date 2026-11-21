module Shells
  module Backends
    # What an adapter answers. Shells (the façade) has already checked what
    # arrives. `exec` is the one thing a kind must do; reading and writing a
    # file are commands built on it here, which a kind may replace.
    #
    #   exec(command, stdin:, timeout:, limit:)
    #       → { "exit" => Integer or nil, "stdout", "stderr", "truncated" => bool, "timed_out" => bool }
    #         `limit` is the bytes kept of each stream (Shells::Capture)
    #   read(path, offset:, limit:)   → { "content" => bytes, "bytes" => the file's size }
    #   write(path, content, append:, mode:) → { "bytes" => written }
    #   check                          → { "reachable" => true, ... } or raises
    #
    # Paths arrive absolute or relative to the login's home, never with a
    # leading ~. An adapter raises Shells::NotFound, Invalid, Forbidden, or
    # Unavailable and nothing else.
    class Base
      IO_TIMEOUT = 30

      attr_reader :host

      # Problems with a row's config, as sentences; none by default.
      def self.config_errors(_config)
        []
      end

      def initialize(host)
        @host = host
      end

      def exec(_command, stdin: nil, timeout:, limit:)
        raise NotImplementedError, "#{self.class.name} does not implement exec"
      end

      def check
        raise NotImplementedError, "#{self.class.name} does not implement check"
      end

      # The file's size on the first line, then up to `limit` bytes from
      # `offset`.
      def read(path, offset:, limit:)
        file = quote(path)
        command = "wc -c < #{file} && tail -c +#{offset + 1} -- #{file} | head -c #{limit}"
        result = exec(command, timeout: IO_TIMEOUT, limit: [ limit + 64, 4_000 ].max)
        raise Shells::NotFound, refusal(result, "could not read #{path}") unless result["exit"]&.zero?

        size, _, content = result["stdout"].to_s.b.partition("\n")
        raise Shells::Unavailable, "could not read #{path}: the host answered #{size.inspect} for its size" unless size.strip.match?(/\A\d+\z/)

        { "content" => content, "bytes" => size.strip.to_i }
      end

      # Makes the directory when it is missing; the content goes in on stdin,
      # so nothing in it meets a shell.
      def write(path, content, append:, mode:)
        file = quote(path)
        directory = File.dirname(path)
        steps = []
        steps << "mkdir -p -- #{quote(directory)}" unless directory == "."
        steps << "cat #{append ? '>>' : '>'} #{file}"
        steps << "chmod #{mode} -- #{file}" if mode
        result = exec(steps.join(" && "), stdin: content, timeout: IO_TIMEOUT, limit: 4_000)
        raise Shells::Invalid, refusal(result, "could not write #{path}") unless result["exit"]&.zero?

        { "bytes" => content.bytesize }
      end

      private

      def quote(path)
        Shellwords.escape(path)
      end

      def refusal(result, fallback)
        return "#{fallback}: the host did not answer within #{IO_TIMEOUT} seconds" if result["timed_out"]

        result["stderr"].to_s.strip.presence&.truncate(400) || fallback
      end
    end
  end
end
