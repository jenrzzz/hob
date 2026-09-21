# hob

The household spirit: a personal LLM substrate. One backing service through
which every LLM interaction in the household flows — providers, conversations,
personas, memory, tools, compute, voice. See [DESIGN.md](DESIGN.md) for the
full design, [CHATELAINE.md](CHATELAINE.md) for the chat frontend,
[SENTINEL.md](SENTINEL.md) for how outside agents get in,
[TODOS.md](TODOS.md) for the household's todos, and
[WARD.md](WARD.md) for the watch it keeps over the household's exposure.

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

With `SENTRY_DSN` set, errors go to Sentry: unhandled ones, and the ones hob
rescues and carries on from (a failed stream, a sentinel request or petition
that errored, a ledger write, a ping that didn't go out). Events carry the
principal, surface, and clearance, never request bodies, query strings, or
SQL (`config/initializers/sentry.rb`). An exception's own message does go.

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
capability it can be trusted with, has the forge (Claude Code in a fresh
sandboxed workspace) build a new one as a pull request for you to merge, or
pings you.

```sh
bin/rails "hob:agent[muse,household]"                    # an agent principal + key, shown once
bin/rails "hob:sentinel:policy[muse,*,review]" GUIDANCE="Muse plans Tessa's week; nothing private."
bin/rails "hob:sentinel:policy[muse,hob.complete,allow]" CONSTRAINTS='{"role":["cheap-classifier"]}' LIMITS='{"cost_per_day":2}'
bin/rails "hob:sentinel:charter[muse,allow]" GUIDANCE="Grant planning reads; ask me about anything private." LIMITS='{"builds_per_day":2}'
bin/rails "hob:forge:setup[forge]"                        # the builder's key; then HOB_URL= HOB_KEY= CODER_URL= CODER_SESSION_TOKEN= bin/forge --coder
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

The same pings reach your phone through the companion app in
[clients/ios](clients/ios/README.md): a petition or request that needs a
person arrives as a push notification and opens in the app, where you
comment and grant, build, allow, or deny. The app registers its phone with a
person's key (`bin/rails "hob:key[jenner,phone]"` mints one); hob sends
through APNs with the same token-auth key kat uses:

| var | value |
|---|---|
| `APNS_KEY` | the `.p8` contents (newlines may be `\n`-escaped, collapsed or quoted; or `APNS_KEY_PATH`) |
| `APNS_KEY_ID` | the key id from the developer portal |
| `APNS_TEAM_ID` | the team id |
| `APNS_BUNDLE_ID` | `place.amber.hob` (the default) |

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

## Todos

hob owns one normalized todo contract; where the todos actually live is a
*backend*, and backends are rows, not code. The first kind is `omnifocus`,
which talks to [tally](TODOS.md#tally-and-omnifocus), an HTTP wrapper
around the OmniFocus app on the Mac mini. A backend has a realm, and RLS
hides it from any request below that clearance, so a household agent
cannot see a `personal` list. To share one folder of OmniFocus with
household agents, register a second backend on the same tally with a key
tally has *scoped* to that folder, at realm `household`.

```sh
export TALLY_KEY=... TALLY_HOUSEHOLD_KEY=...                # tally's bearer keys, in hob's environment
bin/rails "hob:todos:backend[jenner-omnifocus,omnifocus,http://mini.tailnet.ts.net:8377,personal]" KEY_ENV=TALLY_KEY PRIMARY=1
bin/rails "hob:todos:backend[house-omnifocus,omnifocus,http://mini.tailnet.ts.net:8377,household]" KEY_ENV=TALLY_HOUSEHOLD_KEY
bin/rails hob:todos:backends                                # what is registered, and whether each answers
bin/rails "hob:todos:check[house-omnifocus]"
bin/rails "hob:sentinel:policy[muse,todo.*,review]"         # agents reach todos through the sentinel: todo.list, todo.create, ...
```

`OWNER=` (default jenner), `ADDR=` (pin the connection to the mini's
tailnet address), `KEY=` (store the key in the row instead of naming an
env var), and `ENABLED=0` are the other knobs. A backend's key is never
shown again: responses say `key: "set"` or name the env var.
[TODOS.md](TODOS.md) is the design.

## Keeping watch: the ward

The ward ([WARD.md](WARD.md)) is where hob keeps the household's security
posture: infra's `security/audit.py` runs weekly on agentbox and posts its
report; hob turns the lines into findings that persist across runs (one
finding per drift, not one alarm per week), resolves what a *complete* run
no longer reports, notices when the scanner itself has gone quiet, and has
a model (role `ward-triage`) tell you what changed and what to do, on the
same ntfy topic and phones as the sentinel. A person acknowledges a
finding with a note and an expiry; that is the reviewed-decision line of
`SECURITY.md` with a clock on it.

```sh
bin/rails "hob:ward:setup[ward]"                    # the worker's key, shown once; registers the exposure check
bin/rails hob:ward:status                           # checks, open and acknowledged findings, the latest triage
bin/rails "hob:ward:ack[<id>]" NOTE='reviewed: intentional' UNTIL=2026-12-01
bin/rails "hob:ward:note[cadance]" BODY='8888 is nordlynx; auth required on it'
bin/rails hob:ward:sweep                            # hourly, as a Coolify scheduled task on the hob app
bin/rails "hob:sentinel:policy[butler,ward.status,allow]"   # let an agent ask how the house stands
```

```
POST /v1/ward/runs                     { check, exit_code, lines | output, started_at, finished_at, mission }   (the worker)
GET  /v1/ward/status · GET /v1/ward/findings?state=open|acknowledged|resolved|all · GET /v1/ward/runs
POST /v1/ward/findings/:id/ack         { note, until }  · POST …/unack
GET/POST /v1/ward/notes                { subject, body }                                                  (a person)
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
GET  /v1/todos?backend=&status=open|done|dropped|all&actionable=&list=&tag[]=&flagged=
              &due_before=&due_after=&start_before=&q=&updated_after=&sort=&limit=
                                       → { todos: [{ id: "<backend>:<id>", backend, title, notes, status,
                                           actionable, blocked, flagged, due_at, start_at, planned_at,
                                           completed_at, tags, list, parent_id, has_children,
                                           estimate_minutes, repeats, url, created_at, updated_at }],
                                           unavailable: [{ backend, error }] }
GET  /v1/todos/:id
POST /v1/todos                         { title, notes, flagged, due_at, start_at, planned_at, estimate_minutes,
                                         tags, list, parent_id, backend }        unknown attributes are a 422
PATCH /v1/todos/:id                    the same, plus notes_append, add_tags, remove_tags; null clears a date
POST /v1/todos/:id/complete|reopen|drop · DELETE /v1/todos/:id
GET  /v1/todo_lists?backend=&status=&q= → { lists: [{ id, backend, name, kind: project|inbox, path, status, open_count }], unavailable }
GET/POST/PATCH/DELETE /v1/todo_backends[/:name] · POST /v1/todo_backends/:name/check   (a person)
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
`Hob::Client#complete` / `#chat` / `#conversations` / `#usage` / `#todos`,
with `Hob::Fake` for the apps' tests.

Auth is `Authorization: Bearer <key>`; `X-Hob-Clearance` can cap a request's
realm clearance downward (never up). Postgres RLS makes rows above the
request's clearance structurally invisible.
