require_relative "test_helper"

class HTTPTest < Minitest::Test
  def test_sse_parser_handles_split_frames_and_multiline_data
    parser = Hob::HTTP::SSE.new
    seen = []
    parser.feed("data: {\"type\":\"delta\",\"content\":\"Hel\"}\n\ndata: {\"type\":\"del") { |e| seen << e }
    assert_equal 1, seen.size
    parser.feed("ta\",\"content\":\"lo\"}\n\n: comment\n\ndata: {\"type\":\"done\",\n") { |e| seen << e }
    parser.feed("data: \"status\":\"success\"}\n\n") { |e| seen << e }
    assert_equal %w[delta delta done], seen.map(&:type)
    assert_equal "lo", seen[1].content
    assert_equal "success", seen.last.status
  end

  def test_status_codes_map_onto_the_error_hierarchy
    errors = Hob::HTTP::Errors
    assert_instance_of Hob::Unauthorized, errors.for_response(401, { "error" => "unauthorized" })
    assert_instance_of Hob::NotFound, errors.for_response(404, {})
    assert_instance_of Hob::Invalid, errors.for_response(422, { "error" => "realm above clearance" })
    assert_instance_of Hob::Unauthorized, errors.for_response(502, { "error" => "provider rejected" })
    assert_instance_of Hob::Unavailable, errors.for_response(503, { "error" => "down", "status" => "unavailable" })
    limited = errors.for_response(503, { "error" => "429", "status" => "rate_limited" }, retry_after: 30)
    assert_instance_of Hob::RateLimited, limited
    assert_equal 30, limited.retry_after
    assert_equal "realm above clearance", errors.for_response(422, { "error" => "realm above clearance" }).message
    assert_equal 422, errors.for_response(422, {}).status
    assert_instance_of Hob::Unavailable, errors.for_response(500, {})
    assert_instance_of Hob::Error, errors.for_response(418, {})
  end

  def test_stream_error_events_map_too
    errors = Hob::HTTP::Errors
    assert_instance_of Hob::Unavailable, errors.for_event(Hob::Event.new("type" => "error", "status" => "unavailable", "message" => "x"))
    assert_instance_of Hob::Invalid, errors.for_event(Hob::Event.new("type" => "error", "status" => "invalid"))
    assert_instance_of Hob::Error, errors.for_event(Hob::Event.new("type" => "error", "status" => "error"))
  end

  def test_unreachable_host_is_unavailable
    http = Hob::HTTP.new(base: "http://127.0.0.1:1", key: "k", open_timeout: 1)
    assert_raises(Hob::Unavailable) { http.get("/v1/usage") }
  end
end
