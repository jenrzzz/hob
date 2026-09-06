require "test_helper"

class ChatTurnTest < ActiveSupport::TestCase
  test "a normal turn appends user and assistant nodes and advances the branch" do
    convo = conversation
    @fake.reply("Hello.", input_tokens: 12, output_tokens: 3)
    result = ChatTurn.new(conversation: convo, branch: convo.branch, content: "hi").call

    assert_equal "user", result.user_node.role
    assert_equal "Hello.", result.assistant_node.content
    assert_equal result.user_node.content_hash, result.assistant_node.parent_hash
    assert_equal result.assistant_node.content_hash, convo.branch.reload.head_hash
    assert_equal 3, result.assistant_node.meta["output_tokens"]
    assert_equal "claude-sonnet-5", result.assistant_node.meta["model"]
    assert_equal result.snapshot.digest, result.assistant_node.prompt_snapshot_hash
    assert_equal "conversation/#{convo.id}", UsageEvent.last.ref
    assert_equal result.snapshot.digest, UsageEvent.last.snapshot_digest
    assert_equal [ user_message("hi") ], @fake.calls.last.messages
  end

  test "the assistant speaks at the head with no content, chaining under its own node" do
    interviewer = persona("interviewer", instruction: "Ask the single most useful next question.")
    convo = conversation
    @fake.reply("What is the book about?")
    first = ChatTurn.new(conversation: convo, branch: convo.branch, personas: [ interviewer ]).call
    assert_nil first.user_node
    assert_equal MessageNode::ROOT, first.assistant_node.parent_hash
    assert_equal [ user_message("Ask the single most useful next question.") ], @fake.calls.last.messages

    # Stuck: step down under the assistant's own question, with a per-request instruction.
    @fake.reply("Smaller: who is it for?")
    step = ChatTurn.new(conversation: convo, branch: convo.branch, personas: [ interviewer ],
                        instruction: "The writer is STUCK. Ask something smaller.").call
    assert_equal first.assistant_node.content_hash, step.assistant_node.parent_hash
    assert_equal %w[assistant user], @fake.calls.last.messages.map { |m| m["role"] }
    assert_equal "The writer is STUCK. Ask something smaller.", @fake.calls.last.messages.last["content"]
    assert_equal step.assistant_node.content_hash, convo.branch.reload.head_hash
  end

  test "an answer that died before its question resumes from the user head" do
    convo = conversation
    answer = MessageNode.append!(conversation: convo, parent_hash: MessageNode::ROOT, role: "user", content: "It's about bees.")
    convo.branch.advance!(answer)
    @fake.reply("Which bees?")
    result = ChatTurn.new(conversation: convo, branch: convo.branch).call
    assert_equal answer.content_hash, result.assistant_node.parent_hash
  end

  test "nothing to answer is Invalid and calls no model" do
    convo = conversation
    assert_raises(Gateway::Invalid) { ChatTurn.new(conversation: convo, branch: convo.branch).call }
    assert_empty @fake.calls
  end

  test "an ensemble reply becomes a chain of speaker-attributed nodes" do
    saffron = persona("saffron", model_role: "chat-default")
    maggie = persona("maggie")
    convo = conversation
    @fake.reply("[saffron]\nSoup.\n[maggie]\nWith bread!", output_tokens: 9)
    result = ChatTurn.new(conversation: convo, branch: convo.branch, content: "dinner?", personas: [ saffron, maggie ]).call

    assert_equal %w[saffron maggie], result.assistant_nodes.map(&:speaker)
    assert_equal [ "Soup.", "With bread!" ], result.assistant_nodes.map(&:content)
    assert_equal result.assistant_nodes.first.content_hash, result.assistant_nodes.last.parent_hash
    assert_equal result.user_node.content_hash, result.assistant_nodes.first.parent_hash
    assert_nil result.assistant_nodes.first.meta["output_tokens"], "tokens land on the last node only"
    assert_equal 9, result.assistant_nodes.last.meta["output_tokens"]
    assert_equal [ 1, 2 ], result.assistant_nodes.map { |n| n.meta["segment"] }
    assert_equal result.assistant_nodes.last.content_hash, convo.branch.reload.head_hash
  end

  test "a single persona's self-tag is stripped" do
    hob = persona("hob")
    convo = conversation
    @fake.reply("[hob] Evening.")
    result = ChatTurn.new(conversation: convo, branch: convo.branch, content: "hi", persona: hob).call
    assert_equal "Evening.", result.assistant_node.content
    assert_equal "hob", result.assistant_node.speaker
  end

  test "regenerate_at replies again under the same node as a sibling" do
    convo = conversation
    @fake.reply("one").reply("two")
    first = ChatTurn.new(conversation: convo, branch: convo.branch, content: "hi").call
    second = ChatTurn.new(conversation: convo, branch: convo.branch, regenerate_at: first.user_node.content_hash).call
    assert_equal 2, first.assistant_node.siblings.count
    assert_equal second.assistant_node.content_hash, convo.branch.reload.head_hash
  end

  test "a refusal leaves the user node and raises" do
    convo = conversation
    @fake.refuse
    assert_raises(Gateway::Refused) { ChatTurn.new(conversation: convo, branch: convo.branch, content: "hmm").call }
    assert_equal [ "user" ], convo.message_nodes.pluck(:role)
    assert_equal "refused", UsageEvent.last.status
  end
end

class ChatTurnToolsTest < ActiveSupport::TestCase
  TOOLS = [ { "name" => "lookup", "description" => "Look something up", "input_schema" => { "type" => "object", "properties" => { "q" => { "type" => "string" } } } } ].freeze

  test "a tool call ends the turn at tool_call nodes; results resume it with the exchange in the prompt" do
    convo = conversation
    @fake.call_tool("lookup", { q: "bees" }, id: "call_1", content: "Let me check.")
    first = ChatTurn.new(conversation: convo, branch: convo.branch, content: "what about bees?", tools: TOOLS).call

    assert first.tool_calls?
    assert_equal "tool_calls", first.status
    assert_equal "Let me check.", first.assistant_node.content
    assert_equal [ { "id" => "call_1", "name" => "lookup", "arguments" => { "q" => "bees" } } ], first.tool_calls
    assert_equal first.assistant_node.content_hash, first.tool_call_nodes.first.parent_hash
    assert_equal first.tool_call_nodes.last.content_hash, convo.branch.reload.head_hash
    assert_equal TOOLS, @fake.calls.last.tools
    assert_nil @fake.calls.last.tool_choice
    assert_equal "success", UsageEvent.last.status

    @fake.reply("Bees are fine.")
    second = ChatTurn.new(conversation: convo, branch: convo.branch, tools: TOOLS,
                          tool_results: [ { "id" => "call_1", "content" => "bees: ok" } ]).call
    assert_equal "success", second.status
    assert_nil second.user_node
    messages = @fake.calls.last.messages
    assert_equal %w[user assistant assistant tool], messages.map { |m| m["role"] }
    assert_equal "call_1", messages[2]["tool_calls"].first["id"]
    assert_equal({ "role" => "tool", "tool_call_id" => "call_1", "content" => "bees: ok" }, messages.last)
    assert_equal "tool_result", second.assistant_node.parent.kind
    assert_equal %w[user assistant tool_call tool_result assistant], convo.branch.reload.timeline.map { |n| n.kind == "text" ? n.role : n.kind }
  end

  test "past the iteration cap the model may not call tools" do
    convo = conversation
    @fake.call_tool("lookup", { q: "1" }, id: "c1")
    ChatTurn.new(conversation: convo, branch: convo.branch, content: "go", tools: TOOLS, max_iterations: 1).call
    @fake.reply("done")
    ChatTurn.new(conversation: convo, branch: convo.branch, tools: TOOLS, max_iterations: 1,
                 tool_results: [ { id: "c1", content: "r" } ]).call
    assert_equal "none", @fake.calls.last.tool_choice
  end

  test "tool results with nothing pending, or alongside content, are Invalid" do
    convo = conversation
    assert_raises(Gateway::Invalid) do
      ChatTurn.new(conversation: convo, branch: convo.branch, tools: TOOLS, tool_results: [ { id: "x", content: "y" } ]).call
    end
    @fake.call_tool("lookup", {}, id: "c1")
    ChatTurn.new(conversation: convo, branch: convo.branch, content: "go", tools: TOOLS).call
    assert_raises(Gateway::Invalid) do
      ChatTurn.new(conversation: convo, branch: convo.branch, content: "more", tools: TOOLS, tool_results: [ { id: "c1", content: "y" } ]).call
    end
  end
end
