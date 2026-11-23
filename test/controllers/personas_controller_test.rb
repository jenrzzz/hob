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

  test "a persona keeps who she is talking to beside who she is, and a corpus may be kept for someone" do
    Records.create_collection({ "name" => "archive", "key" => "chunk", "description" => "DMs", "realm" => "personal" }, owner: @principal)
    post "/v1/personas", params: { key: "robyn", name: "Robyn", prompt: {
      system_core: "You are Robyn.", relations: { "principal:tester" => "Her oldest friend.", "*" => "Not him." }
    }, tools: { corpora: [ { tool: "recall_archive", collection: "archive", with: [ "principal:tester" ] } ] } }, headers: auth, as: :json
    assert_response :created
    assert_equal({ "principal:tester" => "Her oldest friend.", "*" => "Not him." }, body.dig("prompt", "relations"))
    assert_equal [ "principal:tester" ], body.dig("tools", "corpora", 0, "with")

    post "/v1/conversations", params: { realm: "personal" }, headers: auth, as: :json
    convo = body["id"]
    @fake.reply("who are you")
    post "/v1/conversations/#{convo}/chat", params: { content: "hi", persona: "robyn", with: { name: "Claude", about: "works on the house" } },
                                            headers: auth, as: :json
    assert_response :ok
    assert_includes @fake.calls.last.system, "Claude: a guest"
    assert_includes @fake.calls.last.system, "Not him."
    assert_empty Array(@fake.calls.last.tools)

    @fake.reply("rar")
    post "/v1/conversations/#{convo}/chat", params: { content: "hi", persona: "robyn" }, headers: auth, as: :json
    assert_includes @fake.calls.last.system, "Her oldest friend."
    assert_equal [ "recall_archive" ], @fake.calls.last.tools.map { |t| t["name"] }

    patch "/v1/personas/robyn", params: { prompt: { system_core: "x", relations: { "jenner" => "no ref" } } }, headers: auth, as: :json
    assert_response :unprocessable_entity
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

  test "a push replaces the corpora and keeps the agent link, which it cannot set" do
    agent("meluzina", clearance: "personal")
    agent("skipsy", clearance: "personal")
    persona = Persona.create!(key: "mel", name: "Mel", prompt: { "system_core" => "x" }, tools: { "agent" => "meluzina" })

    patch "/v1/personas/mel", params: { tools: { agent: "skipsy", corpora: [ { tool: "recall_archive", collection: "archive" } ] } },
                              headers: auth, as: :json
    assert_response :ok
    assert_equal "meluzina", persona.reload.tools["agent"], "a push neither moves nor drops the link"
    assert_equal "recall_archive", persona.tools["corpora"].first["tool"]
  end
end
