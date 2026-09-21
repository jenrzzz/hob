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
  (`Sentinel::Native::HANDLERS`) visible at the connection's clearance. A
  capability built for outside agents, by hand or by the forge, is a tool in
  Claude Code the day it is deployed.
- **The plugin** (`plugins/hob`) is thin on purpose: where hob is, a key, a
  clearance cap, and skills that teach method. It has no tool list to fall
  out of date.

## The endpoint

MCP's streamable HTTP transport, with no session and no stream. Each POST is
one JSON-RPC message; the answer is one JSON body. hob answers `initialize`,
`ping`, `tools/list`, and `tools/call`; a notification gets a 202; GET and
DELETE get a 405, since there is no stream to open and no session to end.
Batches are refused.

**A person's key only** (`require_trusted!`). An agent's key is turned away
like everywhere else outside the sentinel, and so are workers and surfaces.

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
| capability rows, `venue: native`, enabled, realm ≤ clearance | everything the household's agents can be granted | `todo_list`, `todo_create`, `ward_status`, `hob_usage`, ... |
| `Mcp::Tools` | what a person's key may do and no agent is offered | `todo_delete`, `ward_findings`, `ward_ack`, `ward_unack` |

- A tool's name is the capability's with the dots turned to underscores
  (`todo.list` → `todo_list`); the dotted name is its `title`.
- Description, schema, kind, and realm come from the **row**, so disabling a
  capability or raising its realm holds here too. `kind: read` becomes
  `readOnlyHint`.
- `hob.agent.message` is left out (`Mcp::AGENTS_ONLY`): mail between agents
  means nothing from a person.
- Webhook and poll capabilities are not served. They are other surfaces'
  tools, signed for and queued on an agent's behalf; a person's assistant can
  reach those surfaces itself.

A handler is given an `Mcp::Call` where the sentinel would give it a request:
the same `arguments`, `principal`, `surface`, `realm`, and `capability`, and a
nil `id` and `ref`, since there is no request row. A handler that needs a real
request belongs in `AGENTS_ONLY`.

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

## Open questions

1. **No ledger.** A person's direct calls are not written down, here or on
   `/v1/todos`. If Claude Code starts doing enough on its own (scheduled
   sessions, the forge), an audit row per `tools/call` is cheap to add.
2. **Descriptions say "the agent".** They were written for the sentinel's
   callers. They read fine to Claude Code, but a capability could carry a
   second sentence for people's tools if it starts to matter.
3. **OAuth.** A bearer key in a header suits Claude Code. claude.ai's
   connectors want OAuth, which hob does not speak.
