require "test_helper"

class PingTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @smoke, _ = agent("smoke-test")
    policy!(nil, "hob.ping", "allow")
  end

  def submit(arguments = {}, agent: @smoke, realm: "household")
    as(agent, realm: realm) do
      Sentinel.submit!(agent: agent, capability: "hob.ping", arguments: arguments)
    end
  end

  test "sync! registers hob.ping as a native read at household" do
    cap = Capability.find_by!(name: "hob.ping")
    assert cap.native?
    assert_equal Sentinel::Native::Ping, cap.handler
    assert_equal "ping", cap.config["handler"]
    assert_equal "read", cap.kind
    assert_equal "household", cap.realm
    assert_nil cap.input_schema["required"]
    assert cap.input_schema["properties"].key?("echo")
  end

  # 1. With no arguments the result is { pong: true, at: <ISO 8601 UTC time> } and has no echo key.
  test "with no arguments returns pong and a UTC timestamp with no echo key" do
    request = submit
    assert_equal "completed", request.status, request.error.to_s
    assert_equal true, request.result["pong"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, request.result["at"])
    assert_not request.result.key?("echo"), "echo must be absent when not given"
  end

  # 2. With echo: "hello" the result includes echo: "hello".
  test "with echo the argument is returned unchanged" do
    request = submit({ "echo" => "hello" })
    assert_equal "completed", request.status, request.error.to_s
    assert_equal true, request.result["pong"]
    assert_equal "hello", request.result["echo"]
    assert request.result["at"].present?
  end

  # 3. An echo longer than 200 characters fails with a Sentinel::Native::Error naming the limit.
  test "an echo longer than 200 characters fails naming the limit" do
    request = submit({ "echo" => "x" * 201 })
    assert_equal "failed", request.status
    assert_match(/exceeds 200 characters/, request.error)

    ok = submit({ "echo" => "y" * 200 })
    assert_equal "completed", ok.status
    assert_equal "y" * 200, ok.result["echo"]
  end

  # 4. A non-string echo fails with a Sentinel::Native::Error.
  test "a non-string echo fails with a clear error" do
    request = submit({ "echo" => 42 })
    assert_equal "failed", request.status
    assert_match(/echo must be a String/, request.error)
  end
end
