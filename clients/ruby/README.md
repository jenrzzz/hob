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

## prices

Model prices (USD per million tokens) drive the ledger's `cost`. Anyone may
read them; a person's key sets them, and setting one reprices the ledger
rows it now covers:

```ruby
hob.prices                                              # { "prices" => [...], "unpriced" => ["claude-new-1"] }
hob.set_price(model: "claude-opus-5", input: 5, output: 25, note: "Anthropic list 2026-06")  # cache rates default to 0.1x / 1.25x
```

## todos

The household's todos through hob's one contract, whatever backend holds
them (OmniFocus, by way of tally). An id is `"<backend>:<native id>"`;
what a key can see is its clearance's business.

```ruby
hob.todos.list(actionable: true, tag: ["Phone"], sort: "due")     # => Hob::TodoListing of Hob::Todo
hob.todos.list(list: "house-omnifocus:inbox").map(&:title)
todo = hob.todos.create(title: "Call the plumber", due_at: 2.days.from_now, tags: ["Phone"], list: "House")
hob.todos.update(todo.id, notes_append: "Tried twice", due_at: nil)   # nil clears; only what is named changes
hob.todos.complete(todo.id)                                        # reopen(id), drop(id), delete(id)
hob.todos.lists(backend: "house-omnifocus")                        # projects and the inbox: Hob::TodoList
hob.todos.backends                                                 # a person's key
```

Filters: `backend`, `status` (`open` | `done` | `dropped` | `all`),
`actionable`, `list`, `tag`, `flagged`, `due_before`, `due_after`,
`start_before`, `q`, `updated_after`, `sort`, `limit`. With no `backend`
every visible one answers; a listing is `partial?` when one could not, and
`unavailable` names it. An unknown filter or attribute is `Hob::Invalid`,
never ignored. `Hob::Fake#todos` keeps todos in memory with the same
surface (`fake.todos.add_list("Garden")` makes a project to file them in).

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

When nothing on offer does what the agent needs, it petitions for it (hob's
SENTINEL.md, "Petitions and the forge"): the steward grants an existing
capability, has the forge build a new one, or holds it for a person.

```ruby
p = hob.sentinel.petition(want: "read the household calendar for the coming week",
                          capability: "hob.calendar.read", arguments: { from: "2026-09-21" },
                          reason: "planning Tessa's week", mission: mission.id)
p = hob.sentinel.wait_petition(p, timeout: 60) if p.pending?
case p.status
when "granted"            then hob.sentinel.request(capability: p.capability, arguments: { from: "2026-09-21" })
when "building", "proposed" then # a pull request is on its way; ask again another day
when "denied"             then p.rationale
end
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
hob.sentinel.petitions(status: "pending").each { |p| hob.sentinel.decide_petition(p.id, decision: "grant", effect: "review") }
hob.sentinel.set_policy(agent: "muse", capability: "hob.complete", effect: "review", guidance: "...")
hob.sentinel.register_capability(name: "mise.add_to_shopping_list", description: "Add an item",
                                 venue: "webhook", config: { url: url, secret: secret })
```

A surface receiving a webhook delivery verifies it with
`Hob::Webhook.verify(secret:, signature: request.headers["X-Hob-Signature"], body: request.raw_post)`.
`Hob::Fake` scripts the sentinel (`fake.sentinel.allow(result)`, `.deny`,
`.hold`), petitions (`.grant(name)`, `.build(name)`, `.hold_petition`,
`.deny_petition`), and keeps an in-memory mission queue.

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
