# hob

*The household spirit that does the chores overnight, keeps the pots warm
beside the fire, and knows everything about the house — provided you leave
the milk out.*

hob is a personal LLM substrate: one backing service through which every LLM
interaction in a household flows. This gem is its Ruby client.

```ruby
gem "hob"
```

```ruby
hob = Hob::Client.new(base: ENV["HOB_URL"], key: ENV["HOB_KEY"])
```

`HOB_ADDR` (or `ipaddr:`) pins the connection to an address — hob's tailnet
IP — while `HOB_URL`'s host still goes out as Host and SNI, so the
certificate check is unchanged and the request never leaves the tailnet.
hob's `hob:provision` task sets all three on an app.

## complete

One call, usually structured. The role names a model chain configured in
hob; the app never sees a model ID.

```ruby
recipe = hob.complete(
  role: "extractor", operation: "recipe.extract",
  system: "Extract the recipe.", messages: [{ role: "user", content: page_text }],
  schema: RECIPE_SCHEMA, metadata: { recipe: recipe.id }, ref: "recipe/#{recipe.id}"
)
recipe.parsed        # => { "title" => "Soup", ... }
recipe.usage.cost    # => 0.00045 (USD; nil when the model is unpriced)
recipe.id            # the pipeline conversation hob kept; hob.completion(id) reads it back
```

A block streams: `hob.complete(...) { |event| print event.content if event.delta? }`.

### Tools

Tools are client-session: you declare what you can run, hob stops when the
model asks for one, you execute and resume by id. Every step is in hob's DAG.

```ruby
TOOLS = [{ name: "fetch_articles", description: "Fetch article bodies",
           input_schema: { type: "object", properties: { ids: { type: "array" } }, required: ["ids"] } }]

c = hob.complete(role: "extractor", messages: msgs, tools: TOOLS, schema: SUMMARIES, max_iterations: 10)
while c.tool_calls?
  results = c.tool_calls.map { |call| call.result(Article.bodies(call.arguments["ids"])) }
  c = hob.complete(id: c.id, tool_results: results)
end
c.parsed
```

## chat

A turn on a conversation branch. hob assembles the prompt (persona, context
blocks, history within budget, instruction), calls the model, appends the
nodes, and returns them.

```ruby
convo = hob.conversations.create(title: "Dinner", realm: "household")

turn = hob.chat(conversation: convo, content: "what's for dinner?",
                personas: %w[saffron maggie],
                context: [{ name: "plan", body: plan_text },
                          { name: "recent", body: recent_text, volatile: true, budget: 800 }],
                tools: COMPANION_TOOLS) { |event| broadcast(event.content) if event.delta? }

turn.assistants        # one node per speaker in an ensemble reply
turn.tool_calls?       # the model stopped to ask for a tool
hob.chat(conversation: convo, tools: COMPANION_TOOLS, tool_results: [call.result("added")])
hob.chat(conversation: convo, persona: "interviewer")   # no content: the assistant speaks at the head
hob.conversations.event(convo.id, content: "Added soup to the plan")  # a side effect, in the timeline
```

`hob.conversations` also has `show`, `list`, `branches`, `fork(id, name:, at:)`,
`set_head(id, head:)`, and `siblings(id, hash)`.

## usage

```ruby
hob.usage(ref: "recipe/7").cost
hob.usage(since: 1.day.ago, surface: "all").by_role
```

## sentinel and missions

An outside agent's key reaches only these (see hob's SENTINEL.md). Ask for
a capability; read the decision; long-poll a pending one.

```ruby
caps = hob.sentinel.capabilities                       # what this key may ask for, with the effect to expect
r = hob.sentinel.request(capability: "hob.complete", reason: "summarize Tessa's list",
                         arguments: { role: "cheap-classifier", messages: [{ role: "user", content: text }] },
                         mission: mission.id)
r = hob.sentinel.wait(r) if r.pending?                 # a person is deciding
r.completed? ? r.result["content"] : r.rationale
```

Missions are work hob queues for a principal that polls. The worker loop
leases, yields, completes with the block's value, and fails on an exception:

```ruby
hob.missions.work(wait: 25) { |mission| Kitchen.run(mission.payload) }
```

A person's key queues and decides:

```ruby
hob.missions.create(assignee: "muse", title: "Plan the week", brief: "Groceries and dinners")
hob.sentinel.list(status: "pending").each { |r| hob.sentinel.decide(r.id, decision: "allow") }
hob.sentinel.set_policy(agent: "muse", capability: "hob.complete", effect: "review", guidance: "...")
hob.sentinel.register_capability(name: "mise.add_to_shopping_list", description: "Add an item",
                                 venue: "webhook", config: { url: url, secret: secret })
```

A surface receiving a webhook delivery verifies it with
`Hob::Webhook.verify(secret:, signature: request.headers["X-Hob-Signature"], body: request.raw_post)`.
`Hob::Fake` scripts the sentinel (`fake.sentinel.allow(result)`, `.deny`,
`.hold`) and keeps an in-memory mission queue.

## Errors

`Hob::Refused` (the model declined; `error.completion` carries the id and
usage), `Hob::RateLimited` (`retry_after` seconds when known),
`Hob::Unavailable` (no provider, upstream down, hob unreachable),
`Hob::Unauthorized`, `Hob::Invalid`, `Hob::NotFound`; all `< Hob::Error`.

## Testing your app

Inject the client and swap in `Hob::Fake`:

```ruby
Llm.client = Hob::Fake.new.reply('{"title": "Soup"}')
Llm.client.calls.last.args[:schema]

fake.refuse                                  # raises Hob::Refused on the next call
fake.call_tool("fetch_articles", { ids: [1] }).reply('{"summaries": []}')
fake.fail(Hob::Unavailable.new("down"))
fake.conversations.show(id).messages         # the transcript the fake kept
```

Streams work too: `fake.complete(...) { |e| }` yields deltas, tool calls,
usage, and done, in that order.

## Development

```
cd clients/ruby && rake test
```
