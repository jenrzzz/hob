require "test_helper"

class SituationControllerTest < ActionDispatch::IntegrationTest
  test "a companion key writes a batch, reads it, and ends a facet" do
    token = ApiKey.issue!(principal: @principal, surface: "app:Test iPhone", default_clearance: "intimate")
    headers = { "Authorization" => "Bearer #{token}" }
    post "/v1/situation", params: { observations: [
      { kind: "location", value: { place: "home" } },
      { kind: "activity", value: { doing: "driving" } }
    ] }, headers: headers, as: :json
    assert_response :created
    assert_equal %w[sensed sensed], body["observations"].map { |row| row["basis"] }
    assert_equal %w[household personal], body["observations"].map { |row| row["realm"] }

    get "/v1/situation", headers: headers
    assert_response :ok
    assert_equal %w[activity location], body["people"].sole["facets"].map { |facet| facet["kind"] }

    post "/v1/situation/end", params: { kind: "activity" }, headers: headers, as: :json
    assert_response :ok
    assert_equal [ "activity" ], body["ended"].map { |row| row["kind"] }
    assert_equal [ "location" ], body.dig("situation", "people").sole["facets"].map { |facet| facet["kind"] }
  end

  test "invalid observation input is 422 and the batch is atomic" do
    post "/v1/situation", params: { observations: [
      { kind: "sleep", value: { state: "asleep" } },
      { kind: "mood", value: { text: "" } }
    ] }, headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/mood.text/, body["error"])
    assert_equal 0, SituationObservation.count
  end

  test "an agent cannot use the direct person endpoint" do
    _agent, token = agent
    get "/v1/situation", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :forbidden
  end
end
