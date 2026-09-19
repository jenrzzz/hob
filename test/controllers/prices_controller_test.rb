require "test_helper"

class PricesControllerTest < ActionDispatch::IntegrationTest
  test "prices are readable, set by people, shown on models, and reprice the ledger" do
    UsageEvent.record(surface: "test", role: "chat-default", model: "claude-opus-5", status: "success",
                      units: { "input_tokens" => 2_000_000 })
    get "/v1/prices", headers: auth
    assert_response :ok
    assert_equal [ "claude-sonnet-5" ], body["prices"].map { |p| p["model"] }
    assert_equal [ "claude-opus-5" ], body["unpriced"]

    put "/v1/prices/claude-opus-5", params: { input: 5, output: 25, note: "Anthropic list 2026-06" }, headers: auth, as: :json
    assert_response :created
    assert_equal 0.5, body["cache_read"]
    assert_equal 1, body["repriced"]
    assert_equal 10.0, UsageEvent.find_by(model: "claude-opus-5").cost.to_f

    put "/v1/prices/claude-opus-5", params: { input: 5, output: 25, cache_read: 0.25 }, headers: auth, as: :json
    assert_response :ok
    assert_equal 0.25, body["cache_read"]

    get "/v1/prices/claude-opus-5-20260901", headers: auth
    assert_equal "claude-opus-5", body["model"], "prefix match"
    assert_equal "claude-opus-5-20260901", body["matched"]
    get "/v1/prices/gpt-nope", headers: auth
    assert_response :not_found

    ModelRole.create!(role: "steward-test", chain: [ { "provider" => "anthropic", "model" => "claude-opus-5" } ])
    get "/v1/models", headers: auth
    steward = body.find { |m| m["role"] == "steward-test" }
    assert_equal({ "model" => "claude-opus-5", "input" => 5.0, "output" => 25.0 }, steward["resolved"]["price"])

    put "/v1/prices/bad", params: { input: 1 }, headers: auth, as: :json
    assert_response :bad_request

    delete "/v1/prices/claude-opus-5", headers: auth
    assert_response :no_content
    assert_nil ModelPrice.find_by(model: "claude-opus-5")
  end

  test "surfaces read prices; agents and surfaces cannot set them" do
    surface = Principal.create!(name: "mise", kind: "surface", max_clearance: "household")
    token = ApiKey.issue!(principal: surface, surface: "mise", default_clearance: "household")
    get "/v1/prices", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :ok
    put "/v1/prices/claude-opus-5", params: { input: 5, output: 25 }, headers: { "Authorization" => "Bearer #{token}" }, as: :json
    assert_response :forbidden

    _muse, agent_token = agent("muse")
    get "/v1/prices", headers: { "Authorization" => "Bearer #{agent_token}" }
    assert_response :forbidden
  end
end
