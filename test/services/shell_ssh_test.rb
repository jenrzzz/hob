require "test_helper"

# The ssh adapter (SHELL.md) without a network: what a row's config must
# hold, how a key in an env var is read, the pin on the machine's key, and
# the commands reading and writing a file become.
class ShellSshTest < ActiveSupport::TestCase
  Ssh = Shells::Backends::Ssh
  KEY = "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n".freeze

  # An Ssh adapter whose exec is answered here, to see the commands.
  class Recorder < Ssh
    attr_reader :calls
    attr_accessor :answer

    def exec(command, stdin: nil, timeout:, limit:)
      (@calls ||= []) << [ command, stdin ]
      { "exit" => 0, "stdout" => "", "stderr" => "", "truncated" => false, "timed_out" => false }.merge(answer || {})
    end
  end

  def host(**config)
    ShellHost.new(name: "box", kind: "ssh", realm: "household", principal: @principal,
                  config: { "host" => "100.64.0.9", "user" => "meluzina", "key" => KEY }.merge(config.stringify_keys))
  end

  test "config: host, user, and a key are required, and each is checked for shape" do
    assert host.valid?
    assert_equal "meluzina@100.64.0.9", host.login
    assert_equal "meluzina@100.64.0.9:2222", host(port: 2222).login
    assert_match(/host is required/, host(host: "").tap(&:valid?).errors.full_messages.to_sentence)
    assert_match(/hostname or an address, nothing else/, host(host: "a b; rm").tap(&:valid?).errors.full_messages.to_sentence)
    assert_match(/user is a login name/, host(user: "-oProxyCommand=x").tap(&:valid?).errors.full_messages.to_sentence)
    assert_match(/key_env or key is required/, host(key: nil).tap(&:valid?).errors.full_messages.to_sentence)
    assert_match(/host_key is a fingerprint/, host(host_key: "ssh-ed25519 AAAAC3...").tap(&:valid?).errors.full_messages.to_sentence)
    assert host(host_key: "ssh-ed25519 SHA256:abc").valid?
  end

  test "the key: from the row or its env var, as text, with escaped newlines, or in base64; never shown" do
    assert_equal KEY, host.key
    ENV["HOB_TEST_SHELL_KEY"] = Base64.strict_encode64(KEY)
    row = host(key: nil, key_env: "HOB_TEST_SHELL_KEY")
    assert_equal KEY, row.key
    ENV["HOB_TEST_SHELL_KEY"] = KEY.gsub("\n", "\\n")
    assert_equal KEY, row.key
    ENV.delete("HOB_TEST_SHELL_KEY")
    assert_nil row.key

    assert_equal "set", host.as_json["config"]["key"]
    refute_includes host.as_json.to_json, "abc"
    refute_includes host.inspect, "abc"
  end

  test "the pin: only the trusted fingerprint passes; with nothing pinned nothing passes unless trusting" do
    key = Struct.new(:ssh_type).new("ssh-ed25519")
    pin = Ssh::Pin.new("ssh-ed25519 SHA256:good")
    assert pin.verify(key: key, fingerprint: "SHA256:good")
    refute pin.verify(key: key, fingerprint: "SHA256:evil")
    assert_equal "ssh-ed25519 SHA256:evil", pin.seen
    assert Ssh::Pin.new("SHA256:good").verify(key: key, fingerprint: "SHA256:good"), "a bare fingerprint"
    refute Ssh::Pin.new(nil).verify(key: key, fingerprint: "SHA256:any")
    assert Ssh::Pin.new(nil, accept: true).verify(key: key, fingerprint: "SHA256:any")
    assert_equal :checked, pin.verify_signature { :checked }
  end

  test "an untrusted host, or one with no key, is refused before any connection" do
    error = assert_raises(Shells::Forbidden) { Ssh.new(host).exec("ls", timeout: 1, limit: 100) }
    assert_match(/not trusted yet.*hob:shell:trust\[box\]/, error.message)
    error = assert_raises(Shells::Forbidden) { Ssh.new(host(key: nil, key_env: "HOB_TEST_NO_SUCH_KEY")).exec("ls", timeout: 1, limit: 100) }
    assert_match(/HOB_TEST_NO_SUCH_KEY is not set/, error.message)
  end

  test "read: size then a slice, every path quoted; a refusal is the machine's own words" do
    adapter = Recorder.new(host)
    adapter.answer = { "stdout" => "11\nhello" }
    assert_equal({ "content" => "hello", "bytes" => 11 }, adapter.read("my notes/it's.txt", offset: 6, limit: 5))
    assert_equal "wc -c < my\\ notes/it\\'s.txt && tail -c +7 -- my\\ notes/it\\'s.txt | head -c 5", adapter.calls.last.first

    adapter.answer = { "exit" => 1, "stderr" => "sh: 1: cannot open nope: No such file\n" }
    assert_match(/cannot open nope/, assert_raises(Shells::NotFound) { adapter.read("nope", offset: 0, limit: 5) }.message)
  end

  test "write: the content goes in on stdin, the directory is made, the mode set" do
    adapter = Recorder.new(host)
    assert_equal({ "bytes" => 9 }, adapter.write("site/a b.html", "$(rm -rf)", append: false, mode: "644"))
    assert_equal [ "mkdir -p -- site && cat > site/a\\ b.html && chmod 644 -- site/a\\ b.html", "$(rm -rf)" ], adapter.calls.last
    adapter.write("log.txt", "x", append: true, mode: nil)
    assert_equal "cat >> log.txt", adapter.calls.last.first

    adapter.answer = { "exit" => 1, "stderr" => "sh: 1: cannot create /etc/x: Permission denied\n" }
    assert_match(/Permission denied/, assert_raises(Shells::Invalid) { adapter.write("/etc/x", "x", append: false, mode: nil) }.message)
  end
end
