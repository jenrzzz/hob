# hob

The household spirit: a personal LLM substrate. One backing service through
which every LLM interaction in the household flows — providers, conversations,
personas, memory, tools, compute, voice. See [DESIGN.md](DESIGN.md) for the
full design and [CHATELAINE.md](CHATELAINE.md) for the chat frontend.

## Running

Rails 8 API + Postgres 16 with pgvector. Row-level security enforces realm
clearance from day one, so the app must connect as a non-superuser role.

```sh
bin/rails db:prepare db:seed   # seeds print a dev API key once
ANTHROPIC_API_KEY=sk-... bin/rails server
```

Providers resolve API keys from env at request time (`ANTHROPIC_API_KEY`,
`HOB_OPENAI_COMPAT_KEY` + `HOB_OPENAI_COMPAT_BASE`). A model role with no
available provider fails with a 422, and new models are config rows in
`model_roles` — never code changes.

## API sketch

```
POST /v1/completions                   { role, operation, system | persona, messages,
                                         schema, tools, tool_choice, max_iterations,
                                         params, metadata, ref, realm }
                                       → { id, status: success|refused|tool_calls, content,
                                           parsed, tool_calls, usage, model, provider,
                                           snapshot, node }
                                       Accept: text/event-stream → delta… retry? tool_call… usage done
                                       { id, tool_results: [{ id, content }] }   # resume after tool calls
GET  /v1/completions/:id               a pipeline conversation's single turn (+ pending tool_calls)
POST /v1/conversations                 { title, realm }
GET  /v1/conversations?kind=chat|pipeline|all
GET  /v1/conversations/:id?branch=main
POST /v1/conversations/:id/chat        { content?, branch, persona | personas[], context,
                                         instruction, role, preset, regenerate_at,
                                         tools, tool_choice, tool_results, max_iterations }
                                       Accept: text/event-stream → delta… tool_call… usage done
                                       no content: the assistant speaks at the branch head
                                       context: string | hash | [{ name, body, budget, volatile }]
POST /v1/conversations/:id/events      { content, branch, meta }   # role: event node
POST /v1/conversations/:id/branches    { name, at: <node hash> }   # fork = ref
GET  /v1/usage?ref=&role=&operation=&since=&surface=
GET  /v1/personas · /v1/models · /v1/snapshots/:hash
```

Tools are client-session: `tools: [{ name, description, input_schema }]`
declares what the *caller* can run. When the model calls one, hob appends a
`tool_call` node per call, answers with `status: tool_calls`, and ends the
request. The caller executes and posts `tool_results: [{ id, content }]` to
the same endpoint (with the completion's `id`, or the conversation's next
turn); hob appends `tool_result` nodes and asks the model again. Past
`max_iterations` rounds (default 10) the tools stay declared but the model
may not call them, so it has to answer.

A refusal is HTTP 200 with `status: refused` (the call happened and was
metered). Upstream rate limits and outages are 503 with `Retry-After` when
known. Every gateway attempt, including failures, is a `usage_events` row;
cost comes from `model_prices` (USD per million tokens, prefix-matched).

```
bin/rails test                         # Gateway::Fake stands in for providers
cd clients/ruby && rake test           # the Ruby client gem (clients/ruby, `gem "hob"`)
```

The Ruby client is the `hob` gem in [clients/ruby](clients/ruby/README.md):
`Hob::Client#complete` / `#chat` / `#conversations` / `#usage`, with
`Hob::Fake` for the apps' tests.

Auth is `Authorization: Bearer <key>`; `X-Hob-Clearance` can cap a request's
realm clearance downward (never up). Postgres RLS makes rows above the
request's clearance structurally invisible.
