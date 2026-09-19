# hob

The household spirit: a personal LLM substrate. One backing service through
which every LLM interaction in the household flows — providers, conversations,
personas, memory, tools, compute, voice. See [DESIGN.md](DESIGN.md) for the
full design, [CHATELAINE.md](CHATELAINE.md) for the chat frontend, and
[SENTINEL.md](SENTINEL.md) for how outside agents get in.

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

## Onboarding a surface

Every app that talks to hob is a *surface* with its own API key. hob mints
the key and hands it to the app itself, so the raw token goes from hob's
database into the app's environment on Coolify and is never shown to anyone.
From hob's terminal in Coolify:

```sh
bin/rails "hob:provision[airing,<coolify app uuid>]"            # clearance personal, principal jenner
bin/rails "hob:provision[kat,<uuid>,intimate]"                   # a higher-clearance surface
RESTART=0 bin/rails "hob:provision[parboil,<uuid>]"              # set the env, don't restart
```

The app receives `HOB_URL`, `HOB_ADDR` and `HOB_KEY` and is restarted.
Re-running rotates the key: the new one is pushed first, then the surface's
older keys are deleted. hob needs these in its own environment:

| var | value |
|---|---|
| `COOLIFY_URL` | the Coolify instance, e.g. `https://cool.example` |
| `COOLIFY_TOKEN` | an API token with write access to the target apps |
| `HOB_CLIENT_URL` | the name surfaces call hob by, e.g. `https://hob.amber.place` |
| `HOB_CLIENT_ADDR` | optional: hob's tailnet address; surfaces pin the connection to it (`Hob::Client` `ipaddr:`) so calls never leave the tailnet while the certificate check stays on the public name |

## Outside agents: the sentinel

An external AI (Meta's Muse, say) gets an *agent* key, which reaches only
the sentinel and the mission queue — never the model-facing API. It asks
for capabilities; policy allows, denies, has an LLM reviewer judge, or
holds the request for a person; hob does what was allowed at the agent's
clearance and writes it all down. Missions are the other direction: work
the household queues for an agent that can only poll. When nothing on
offer fits, the agent *petitions* for it: the steward grants an existing
capability it can be trusted with, has the forge (Claude Code on a coder
box) build a new one as a pull request for you to merge, or pings you.

```sh
bin/rails "hob:agent[muse,household]"                    # an agent principal + key, shown once
bin/rails "hob:sentinel:policy[muse,*,review]" GUIDANCE="Muse plans Tessa's week; nothing private."
bin/rails "hob:sentinel:policy[muse,hob.complete,allow]" CONSTRAINTS='{"role":["cheap-classifier"]}' LIMITS='{"cost_per_day":2}'
bin/rails "hob:sentinel:charter[muse,allow]" GUIDANCE="Grant planning reads; ask me about anything private." LIMITS='{"builds_per_day":2}'
bin/rails "hob:forge:setup[forge]"                        # the builder's key; then on the coder box: HOB_URL= HOB_KEY= bin/forge
bin/rails hob:sentinel:pending                            # requests and petitions a person needs to decide
bin/rails "hob:sentinel:decide[<id>,allow]"
bin/rails "hob:sentinel:petition[<id>,grant]" EFFECT=review
```

Model prices are rows, not code: `bin/rails "hob:price[claude-opus-5,5,25]"`
sets one (USD per million tokens, cache rates defaulting to 0.1x and 1.25x
of input) and reprices the ledger rows it covers; `bin/rails hob:prices`
lists them with the models the ledger has seen unpriced. Every ledger row
carries `cost: null` rather than zero until its model has a price, and
`GET /v1/usage` reports `priced: false` while any such row is in view.

`HOB_NOTIFY_URL=https://ntfy.sh/<topic>` (plus `HOB_NOTIFY_TOKEN` for a
protected topic) makes hob ping you when a
petition needs a person, a build starts, a PR is ready, or a build fails.
Each principal can also have a channel of its own, `bin/rails
"hob:channel[skipsy,https://ntfy.sh/hob-skipsy]"`: a mission queued for it
is announced there, and a mission it queued reports its outcome there. Two
agents on one household get two channels, so neither wakes for the
other's work; `hob:channel` with no arguments lists them.

[SENTINEL.md](SENTINEL.md) is the design; [MUSE.md](MUSE.md) is the
connector brief an outside agent reads to wire itself up.

```
POST /v1/sentinel/requests             { capability, arguments, reason, mission }
                                       → { id, status: completed|denied|pending|executing|failed,
                                           decision, decided_by, rationale, result, error }
GET  /v1/sentinel/requests/:id?wait=25 long-poll until settled
POST /v1/sentinel/requests/:id/decide  { decision: allow|deny, rationale }      (a person)
GET  /v1/prices · PUT /v1/prices/:model { input, output, cache_read, cache_write, note }   USD per million; a PUT reprices the ledger (a person)
GET  /v1/sentinel/capabilities         what this agent may ask for, and the effect to expect
POST /v1/sentinel/petitions            { want, capability, arguments, reason, mission }
                                       → { id, status: granted|pending|building|proposed|denied, capability, effect, rationale }
POST /v1/sentinel/petitions/:id/decide { decision: grant|build|deny, effect, constraints, guidance }  (a person)
GET/POST/PATCH/DELETE /v1/sentinel/policies · POST /v1/sentinel/capabilities   (a person)
POST /v1/missions/lease                { wait, lease } → the next mission + lease_token, or { status: empty }
POST /v1/missions/:id/heartbeat|complete|fail   { lease_token, ... }
POST /v1/missions                      { assignee, title, brief, payload, priority, realm }  (a person)
```

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
