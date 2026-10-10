require "test_helper"
require "socket"

# hob.ward.portcheck (WARD.md): one TCP connect check from ward's own
# network, against ward's own inventory of scan targets — never the
# agent's word for what a target is.
class WardPortcheckNativeTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @butler, _ = agent("butler", clearance: "personal")
    policy!(nil, "hob.ward.portcheck", "allow")
    @prior_targets = ENV["HOB_WARD_SCAN_TARGETS"]
  end

  teardown do
    ENV["HOB_WARD_SCAN_TARGETS"] = @prior_targets
    Sentinel::Native::WardPortcheck.opener = nil
  end

  def submit(arguments, agent: @butler, realm: "personal")
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: "hob.ward.portcheck", arguments: arguments) }
  end

  def targets!(*hosts)
    ENV["HOB_WARD_SCAN_TARGETS"] = hosts.join(",")
  end

  test "sync! registers it as a personal read with a closed schema" do
    cap = Capability.find_by!(name: "hob.ward.portcheck")
    assert_equal [ "read", "personal", "native", "ward_portcheck" ], [ cap.kind, cap.realm, cap.venue, cap.config["handler"] ]
    assert_equal %w[host port], cap.input_schema["required"]
    refute cap.input_schema["additionalProperties"]
  end

  test "1: a host not in ward's scan inventory is rejected with NotATarget, and no connection is made" do
    targets!("203.0.113.7")
    Sentinel::Native::WardPortcheck.opener = ->(*) { flunk "connected to a host outside the inventory" }

    request = submit({ "host" => "10.0.0.9", "port" => 22 })
    assert_equal "failed", request.status
    assert_match(/\ANotATarget:/, request.error)
    assert_match(/not in ward's scan-target inventory/, request.error)
  end

  test "2: a port outside 1-65535, a range, or a list is rejected by the handler" do
    targets!("203.0.113.7")

    [ 0, 65_536, -1, [ 80, 443 ], "80-443", nil ].each do |bad_port|
      request = submit({ "host" => "203.0.113.7", "port" => bad_port }.compact)
      assert_equal "failed", request.status, bad_port.inspect
      assert_match(/port (is required|must be a single integer between 1 and 65535)/, request.error)
    end
  end

  test "3: a timeout above 30 is rejected" do
    targets!("203.0.113.7")
    Sentinel::Native::WardPortcheck.opener = ->(*) { flunk "connected despite a bad timeout" }

    request = submit({ "host" => "203.0.113.7", "port" => 80, "timeout" => 31 })
    assert_equal "failed", request.status
    assert_match(/timeout must be an integer between 1 and 30/, request.error)
  end

  test "4: an open listener returns open with a banner of at most 256 bytes, and the handler sends no bytes" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    sent_to_server = +""
    accepted = Thread.new do
      client = server.accept
      begin
        sent_to_server << client.read_nonblock(4096)
      rescue IO::WaitReadable, EOFError
        nil
      end
      client.write("PLEX MEDIA SERVER: ready\r\n" + ("x" * 500))
      client.close
    end

    targets!("127.0.0.1")
    request = submit({ "host" => "127.0.0.1", "port" => port, "finding_id" => "wf_01" })
    accepted.join(5)

    assert_equal "completed", request.status, request.error.to_s
    result = request.result
    assert_equal "open", result["state"]
    assert result["banner"].present?
    assert_operator result["banner"].bytesize, :<=, 256
    assert_equal "wf_01", result["finding_id"]
    assert_equal "", sent_to_server, "the handler must send nothing"
    assert_match(/\(external\)\z/, result["vantage"])
    assert_equal Sentinel::Native::WardPortcheck::NOTICE, result["notice"]
  ensure
    server&.close
  end

  test "5a: a refused connect returns closed" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close

    targets!("127.0.0.1")
    request = submit({ "host" => "127.0.0.1", "port" => port })
    assert_equal "completed", request.status, request.error.to_s
    assert_equal "closed", request.result["state"]
    assert_nil request.result["banner"]
  end

  test "5b: a dropped SYN returns filtered within the timeout" do
    targets!("203.0.113.7")
    Sentinel::Native::WardPortcheck.opener = ->(*) { raise Errno::ETIMEDOUT }

    request = submit({ "host" => "203.0.113.7", "port" => 32_400, "timeout" => 1 })
    assert_equal "completed", request.status, request.error.to_s
    assert_equal "filtered", request.result["state"]
    assert_nil request.result["banner"]
  end

  test "6: every call, including a rejected one, writes a sentinel request — the audit entry" do
    targets!("203.0.113.7")
    before = SentinelRequest.count

    submit({ "host" => "not-a-target", "port" => 22, "finding_id" => "wf_02" })

    assert_equal before + 1, SentinelRequest.count
    entry = SentinelRequest.recent.first
    assert_equal @butler, entry.principal
    assert_equal "butler", entry.surface
    assert_equal "not-a-target", entry.arguments["host"]
    assert_equal 22, entry.arguments["port"]
    assert_equal "wf_02", entry.arguments["finding_id"]
    assert_match(/NotATarget/, entry.error)
  end

  test "7: ward findings, schedules, and reports are unchanged after a call" do
    WardCheck.create!(slug: "exposure", description: "the audit")
    Ward::Ingest.call(check: "exposure", lines: "FAIL cadance 203.0.113.7:32400: unexpected public TCP port\n", exit_code: 1, triage: false)
    finding = WardFinding.last
    finding_before = finding.attributes
    schedule_count = Schedule.count
    run_count = WardRun.count

    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    accepted = Thread.new { server.accept.close }

    targets!("127.0.0.1")
    request = submit({ "host" => "127.0.0.1", "port" => port, "finding_id" => finding.id })
    accepted.join(5)

    assert_equal "completed", request.status, request.error.to_s
    assert_equal finding_before, finding.reload.attributes
    assert_equal schedule_count, Schedule.count
    assert_equal run_count, WardRun.count
  ensure
    server&.close
  end

  test "an unknown argument is rejected" do
    targets!("203.0.113.7")
    request = submit({ "host" => "203.0.113.7", "port" => 80, "sweep" => true })
    assert_equal "failed", request.status
    assert_match(/unknown argument sweep/, request.error)
  end

  test "a household agent is stopped by the realm before policy" do
    muse, = agent("muse", clearance: "household")
    request = submit({ "host" => "203.0.113.7", "port" => 80 }, agent: muse, realm: "household")
    assert_equal "denied", request.status
    assert_equal "realm", request.decided_by
  end
end
