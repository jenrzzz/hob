module Shells
  module Backends
    # An in-memory machine for tests: files in a hash, commands answered by
    # the first matching rule (exit 0 and nothing printed otherwise), and
    # every call it was sent. It is a kind only in the test environment
    # (Shells::Backends registers it there).
    #
    #   box = Shells::Backends::Fake.machine("meluzina-box")     # the row's name
    #   box.on(/\Auname/) { { "stdout" => "Linux 6.8\n" } }
    #   box.on(/sleep/) { { "timed_out" => true } }
    #   box.files["notes/a.txt"] = "hello"
    #   Shells::Backends::Fake.fail!("meluzina-box", Shells::Unavailable.new("the machine is off"))
    #   Shells::Backends::Fake.reset!                              # in teardown
    class Fake < Base
      class Machine
        attr_reader :files, :calls, :rules
        attr_accessor :error

        def initialize
          @files = {}
          @calls = []
          @rules = []
        end

        def on(pattern, &answer)
          rules << [ pattern, answer ]
        end
      end

      class << self
        def machines
          @machines ||= Hash.new { |machines, name| machines[name] = Machine.new }
        end

        def machine(name)
          machines[name]
        end

        def fail!(name, error)
          machines[name].error = error
        end

        def reset!
          @machines = nil
        end
      end

      def exec(command, stdin: nil, timeout:, limit:)
        machine.calls << [ :exec, command, { stdin: stdin, timeout: timeout }.compact ]
        raise machine.error if machine.error

        _, answer = machine.rules.find { |pattern, _| pattern === command }
        said = (answer ? answer.call(command, stdin) : {}).to_h.stringify_keys
        out = Shells::Capture.new(limit) << said["stdout"].to_s
        err = Shells::Capture.new(limit) << said["stderr"].to_s
        timed_out = said["timed_out"] == true
        { "exit" => timed_out ? nil : said.fetch("exit", 0), "stdout" => out.to_s, "stderr" => err.to_s,
          "truncated" => out.truncated? || err.truncated?, "timed_out" => timed_out }
      end

      def read(path, offset:, limit:)
        machine.calls << [ :read, path, { offset: offset, limit: limit } ]
        raise machine.error if machine.error

        content = machine.files[path] or raise Shells::NotFound, "cat: #{path}: No such file or directory"
        { "content" => (content.b.byteslice(offset, limit) || "".b), "bytes" => content.bytesize }
      end

      def write(path, content, append:, mode:)
        machine.calls << [ :write, path, { append: append, mode: mode }.compact ]
        raise machine.error if machine.error

        machine.files[path] = append ? "#{machine.files[path]}#{content}" : content.dup
        { "bytes" => content.bytesize }
      end

      def check
        raise machine.error if machine.error

        { "reachable" => true, "login" => "fake@#{host.name}", "system" => "Fake 1.0", "user" => "fake", "hostname" => host.name }
      end

      private

      def machine
        self.class.machine(host.name)
      end
    end
  end
end
