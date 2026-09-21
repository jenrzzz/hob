require "test_helper"

# The places hob rescues an error and carries on still say so through
# Rails.error (config/initializers/sentry.rb subscribes Sentry to it).
class ErrorReportsTest < ActiveSupport::TestCase
  test "a ledger write that fails is reported and still never raises" do
    report = assert_error_reported(ActiveRecord::RecordInvalid) do
      assert_nil UsageEvent.record(status: "nonsense", surface: "test", role: "chat-default", model: "claude-sonnet-5")
    end
    assert_equal "hob.ledger", report.source
  end

  test "a sentinel request that fails on a fault in hob is reported; one that answers the agent is not" do
    native_capabilities!
    muse, _token = agent("muse")
    policy!(muse, "hob.usage", "allow")
    submit = -> { as(muse, realm: "household") { Sentinel.submit!(agent: muse, capability: "hob.usage", arguments: {}) } }

    usage_raising(RuntimeError.new("boom")) do
      report = assert_error_reported(RuntimeError) { assert_equal "failed", submit.call.status }
      assert_equal "hob.sentinel", report.source
      assert_equal "hob.usage", report.context[:capability]
    end

    usage_raising(Todos::Unavailable.new("away")) do
      assert_no_error_reported { assert_equal "failed", submit.call.status }
    end
  end

  test "a ping that doesn't go out is reported as a warning" do
    Notify.transport = ->(*) { raise SocketError, "no route" }
    report = assert_error_reported(SocketError) { assert_not Notify.post_to("https://ntfy.example/t", title: "t", body: "b") }
    assert_equal :warning, report.severity
  ensure
    Notify.transport = nil
  end

  private

  # hob.usage's handler, failing; put back afterwards.
  def usage_raising(error)
    handler = Sentinel::Native::Usage
    original = handler.instance_method(:call)
    handler.define_method(:call) { raise error }
    yield
  ensure
    handler.define_method(:call, original)
  end
end
