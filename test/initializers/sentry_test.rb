require "test_helper"
require "sentry/test_helper"

# config/initializers/sentry.rb: what reaches Sentry, and what never does.
class SentryTest < ActionDispatch::IntegrationTest
  include Sentry::TestHelper

  setup do
    processors = Sentry::Scope.global_event_processors.dup
    setup_sentry_test
    @restore = -> { Sentry::Scope.global_event_processors.replace(processors) } # teardown_sentry_test clears them
  end

  teardown do
    teardown_sentry_test
    @restore.call
  end

  test "nothing that carries a prompt or a reply is collected" do
    config = Sentry.configuration
    assert_equal [], config.data_collection.http_bodies
    assert_equal :off, config.data_collection.url_query_params.mode
    assert_equal :off, config.data_collection.cookies.mode
    assert_equal :off, config.data_collection.stack_frame_variables.mode
    assert_not config.data_collection.database_query_data
    assert_empty config.breadcrumbs_logger
    assert_not config.propagate_traces, "no sentry-trace headers on calls to providers"
    assert_nil config.traces_sample_rate
  end

  test "an unhandled error is an event: tagged with who asked, without what they said" do
    @fake.fail(RuntimeError.new("boom"))
    assert_raises(RuntimeError) do
      post "/v1/completions?note=private", params: { role: "chat-default", messages: [ { role: "user", content: "a private thought" } ] },
           headers: auth, as: :json
    end

    event = sentry_events.sole
    assert_equal "RuntimeError", event.exception.values.first.type
    assert_equal @principal.name, event.tags[:principal]
    assert_equal "intimate", event.tags[:clearance]
    assert event.tags[:surface].present?
    assert_nil event.request.data
    assert_nil event.request.query_string
    assert_not_includes JSON.generate(event.to_h), @token
    # The stack trace quotes this file's source, the word below included, so look everywhere but there.
    assert_no_match(/private/, JSON.generate(event.to_h.except(:exception)))
  end

  test "an error rescued onto a stream is an event too; a gateway outcome is not" do
    @fake.fail(RuntimeError.new("boom"))
    post "/v1/completions", params: { role: "chat-default", messages: [ { role: "user", content: "hi" } ] },
         headers: auth("Accept" => "text/event-stream"), as: :json
    assert_equal "error", sse_events.last["type"]
    assert_equal "hob.stream", sentry_events.sole.tags[:source]

    clear_sentry_events
    @fake.fail(Gateway::RateLimited.new("429", retry_after: 30))
    post "/v1/completions", params: { role: "chat-default", messages: [ { role: "user", content: "hi" } ] },
         headers: auth("Accept" => "text/event-stream"), as: :json
    assert_equal "rate_limited", sse_events.last["status"]
    assert_empty sentry_events
  end
end
