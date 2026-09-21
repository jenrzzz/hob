require "test_helper"

class PersonasControllerTest < ActionDispatch::IntegrationTest
  test "a persona's prompt keeps the keys of its contract and drops the rest" do
    post "/v1/personas", params: { key: "wren", name: "Wren", prompt: {
      system_core: "You are Wren.", instruction: "Stay in voice.", greetings: [ "Hello.", "Oh, it's you." ],
      examples: [ "Wren: Quite." ], avatar: "wren.png", nested: { anything: true }
    } }, headers: auth, as: :json
    assert_response :created
    assert_equal({ "system_core" => "You are Wren.", "instruction" => "Stay in voice.",
                   "greetings" => [ "Hello.", "Oh, it's you." ], "examples" => [ "Wren: Quite." ] }, body["prompt"])

    patch "/v1/personas/wren", params: { prompt: { system_core: "You are Wren, older now.", admin: true } }, headers: auth, as: :json
    assert_response :ok
    assert_equal({ "system_core" => "You are Wren, older now." }, body["prompt"])
    assert_equal "You are Wren, older now.", Persona.find_by!(key: "wren").system_core
  end

  test "an imported card is archived whole, whatever its shape" do
    card = { "spec" => "chara_card_v2", "data" => { "name" => "Pip", "description" => "{{char}} is a sparrow.", "first_mes" => "Cheep.",
                                                    "extensions" => { "depth_prompt" => { "depth" => 4 } } } }
    post "/v1/personas/import", params: { card: card }, headers: auth, as: :json
    assert_response :created
    assert_equal "pip", body["key"]
    assert_equal "Pip is a sparrow.", body.dig("prompt", "system_core")
    assert_equal card, Persona.find_by!(key: "pip").card_import
  end
end
