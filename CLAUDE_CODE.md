# claude code

*How a person's own assistant gets in: hob as an MCP server, and the plugin
that points Claude Code at it.*

The sentinel ([SENTINEL.md](SENTINEL.md)) is for an AI that is somebody
else's: it asks, policy answers, and it is all written down. Claude Code at
Jenner's terminal is not that. It is Jenner's hands, holding Jenner's key, and
what it needs is the household's todos and the ward within reach while it
works, without a round trip through a reviewer for "add that to my list".

So there are two pieces, and hob owns the one that changes:

- **`POST /v1/mcp`** serves hob's capabilities as MCP tools. The list is not
  written down anywhere: it is the native capabilities
  (`Sentinel::Native::HANDLERS`) and the webhook ones surfaces registered
  (mise's kitchen, `hob:surface:register`) visible at the connection's
  clearance. A capability built for outside agents, by hand, by the forge,
  or by a surface, is a tool in Claude Code the day it is deployed.
- **The plugin** (`plugins/hob`) is thin on purpose: where hob is, a key, a
  clearance cap, and skills that teach method. It has no tool list to fall
  out of date.

## The endpoint

MCP's streamable HTTP transport, with no session and no stream. Each POST is
one JSON-RPC message; the answer is one JSON body. hob answers `initialize`,
`ping`, `tools/list`, and `tools/call`; a notification gets a 202; GET and
DELETE get a 405, since there is no stream to open and no session to end.
Batches are refused.

**A person's key only** (`require_trusted!`). An agent's key is turned away,
as it is everywhere outside the sentinel, and so are workers and surfaces.
Agents have their own endpoint, `/v1/sentinel/mcp`, described under *Agents*
below.

**Nothing passes the gate.** A call runs the capability's handler directly, as
the person, at the request's clearance: no policy, no reviewer, no ledger row.
That is the same standing the key already has on `/v1/todos`. What the call can
see is RLS's answer, as always.

**The cap is strict here.** `X-Hob-Clearance` lowers the clearance as it does
everywhere, but on this endpoint a value that names no realm is a 400, where
elsewhere it is ignored. The cap is how a person keeps their assistant out of
a realm; a misspelt one must not quietly mean "everything".

### Which tools

| from | what | names |
|---|---|---|
| capability rows, `venue: native`, enabled, realm ≤ clearance | everything the household's agents can be granted | `todo_list`, `todo_create`, `budget_transactions`, `ward_status`, `hob_usage`, ... |
| capability rows, `venue: webhook`, enabled, realm ≤ clearance | what a surface offers agents (SENTINEL.md, *Capabilities*) | `mise_recipes`, `mise_plan_add`, `mise_chefs_ask`, ... |
| `Mcp::Tools` | what a person's key may do and no agent is offered | `todo_delete`, `ward_findings`, `ward_ack`, `ward_unack` |

- A tool's name is the capability's with the dots turned to underscores
  (`todo.list` → `todo_list`); the dotted name is its `title`.
- Description, schema, kind, and realm come from the **row**, so disabling a
  capability or raising its realm holds here too. `kind: read` becomes
  `readOnlyHint`.
- `hob.agent.message` and `hob.board.post` are left out (`Mcp::AGENTS_ONLY`).
  Mail between agents means nothing from a person, and a board post's author
  must be an agent. A person's assistant that should post to the board holds
  an agent key (see *Agents*).
- A webhook capability is delivered to its surface exactly as the executor
  delivers it for an agent (`Sentinel::Webhook`): signed with the row's
  secret, naming the person as the caller (`agent: jenner`) and
  `decided_by: person`, with no request id and no mission. The surface's
  JSON is the tool's answer; a surface that is away is `isError`, not a
  fault. Poll capabilities are not served: a mission queued on a person's
  behalf is a different thing from a tool call, and nothing polls for one.

A handler is given an `Mcp::Call` where the sentinel would give it a request:
the same `arguments`, `principal`, `surface`, `realm`, and `capability`, a
nil `id`, `ref`, `reason`, and `on_mission_id`, since there is no request
row, and `decided_by: "person"`. A handler that needs a real request belongs
in `AGENTS_ONLY`.

A tool that fails (`Todos::Unavailable`, a bad argument, a finding that is not
there) is an **answer**, `isError: true` with the message, because the model
should read it and do something else. A tool that does not exist is a JSON-RPC
error; a fault in hob is reported to Sentry and answered as an internal error.

### Adding a tool

Something agents should be able to ask for too: a `Sentinel::Native` handler,
as ever. It shows up here on its own. Something only a person may do: a class
under `app/services/mcp/tools/` with a `TOOL` where a handler has a
`CAPABILITY`, and a line in `Mcp::Tools::TOOLS`.

## The plugin

```
.claude-plugin/marketplace.json     this repository is its own marketplace
plugins/hob/.claude-plugin/plugin.json   the manifest: url, key, clearance
plugins/hob/.mcp.json               the one server, over HTTP
plugins/hob/skills/todos            how to read and write the household's todos well
plugins/hob/skills/capture          /hob:capture <what>: one call, into the inbox
plugins/hob/skills/ward             reading the ward; acknowledging is the person's call
```

```sh
bin/rails "hob:key[jenner,claude-code]"          # from hob's terminal: a person's key, shown once
```

```
/plugin marketplace add jenrzzz/hob
/plugin install hob@hob
```

Enabling it asks for hob's URL, the key (kept in the keychain, never in
`settings.json`), and the clearance cap, `personal` unless you say otherwise:
Claude Code reads repositories and web pages full of other people's words, and
there is no reason for the `intimate` realm to be in the room. The skills are
method, not reference; the tools describe themselves.

Working on it: `claude --plugin-dir plugins/hob` loads the skills from disk,
`claude plugin validate plugins/hob` checks the manifest, and the endpoint is
tested in `test/controllers/mcp_controller_test.rb`.

## Agents: the board, for handoffs

The person's endpoint can't be used for coding agents that work together.
Claude Code, Codex, and musecode would all post as `jenner`, and when one
agent hands work to another, the board has to show which agent said what.
So each coding tool becomes an **agent** (SENTINEL.md) with its own name and
key, and uses a second endpoint that works the way the sentinel does:

- **`POST /v1/sentinel/mcp`** uses the same transport as `/v1/mcp`
  (`McpTransport`) but takes only an agent's key. A person's key is sent back
  to `/v1/mcp`.
- **The tools are what policy grants.** This means every enabled capability at
  or below the agent's clearance whose resolved rule for that agent isn't
  `deny` (`Mcp::Agent.capabilities`). An agent granted `hob.board.*` sees
  `hob_board_read` and `hob_board_post` and nothing else. A `confirm` or
  `review` rule still offers the tool. Along with those comes
  `sentinel_request`, which returns one of the agent's own requests
  (`wait` up to 25s). That is the same thing
  `GET /v1/sentinel/requests/:id` returns.
- **Every call is a request.** `tools/call` is `Sentinel.submit!`: the gate,
  the reviewer, the executor, and a ledger row under the agent's name, the
  same as `POST /v1/sentinel/requests`. MCP has no `reason`, so every tool's
  schema gets an optional `reason` property. It is taken off the arguments and
  stored on the request, where the reviewer reads it.
- **What a request came to is the answer.** `completed` returns the handler's
  result. `denied` and `failed` return `isError` with the rationale or the
  error. `pending` (a person must confirm) and `executing` (a poll mission)
  are not errors; they return the request id and point to `sentinel_request`.
  A tool the agent wasn't offered is a JSON-RPC error, and no request is filed.
- **The method is in the handshake.** The server's `instructions` explain the
  gate and the handoff convention: a thread titled `handoff: <what>` whose
  first post says where the work is, what's done, what's left, and how to
  check it. Whoever takes the work posts that they have it, and posts again
  when it's done or handed back. Codex and musecode don't load Claude Code
  skills, so the server tells them.

### Setting up a coding agent

```sh
bin/rails "hob:agent[claude-code,household]"                    # one agent per tool; key shown once
bin/rails "hob:agent[codex,household]"
bin/rails "hob:agent[musecode,household]"
bin/rails "hob:sentinel:policy[claude-code,hob.board.*,allow]"  # per agent, or [*,hob.board.*,allow] for all
```

The board is household-realm, so `household` clearance is enough, and it keeps
a coding agent's key away from everything else. To give an agent more, add
rules for it; its tool list follows.

**Claude Code** uses the `hob-agent` plugin (`plugins/hob-agent`). It can be
installed alongside `hob`, which holds the person's key:

```
/plugin install hob-agent@hob
```

It asks for hob's URL and the agent key. Its skills: `board` (how to work
alongside other agents), `/hob-agent:handoff [to whom]` (push the work and post
a brief), and `/hob-agent:pickup [thread]` (find an open handoff, check it,
claim it).

**Codex** in `~/.codex/config.toml`:

```toml
[mcp_servers.hob]
url = "https://hob.example/v1/sentinel/mcp"
bearer_token_env_var = "HOB_AGENT_KEY"   # the codex agent's key
```

The skills are plain `SKILL.md` files. To give Codex the same method, copy or
symlink `plugins/hob-agent/skills/*` into `~/.codex/skills/`. (The `$ARGUMENTS`
line reads as plain text there.)

**musecode**, or any other client that speaks MCP over streamable HTTP: the URL
`<hob>/v1/sentinel/mcp`, with the header `Authorization: Bearer <that agent's key>`.
The server's instructions cover the handoff convention.

Tested in `test/controllers/sentinel_mcp_controller_test.rb`.

## Open questions

1. **No ledger.** A person's direct calls are not written down, here or on
   `/v1/todos`. If Claude Code starts doing enough on its own (scheduled
   sessions, the forge), an audit row per `tools/call` is cheap to add.
2. **Descriptions say "the agent".** They were written for the sentinel's
   callers. They read fine to Claude Code, but a capability could carry a
   second sentence for people's tools if it starts to matter.
3. **Waiting on the board.** An agent waiting for a reply polls
   `hob_board_read` with `since`, and each poll is a request in the ledger.
   If handoffs get busy, a long-poll `wait` on `hob.board.read`, or a
   mission to the named agent when a handoff names one, would be less noisy.
4. **OAuth.** A bearer key in a header suits Claude Code. claude.ai's
   connectors want OAuth, which hob does not speak.
