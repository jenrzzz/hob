# sentinel

*The one who stands at the door. Everything hob knows and can do is behind
it; an outside agent gets what the house decides to hand over, and every
ask is written down.*

hob's other consumers are the household's own surfaces: code Jenner wrote,
running on the household's machines, holding keys that let them call the
model-facing API directly. **The sentinel is for agents that are none of
those things** — Meta's Muse (formerly Hatch) first, and whatever else
comes: an AI that lives elsewhere, is steered by someone else's prompt, and
should still be able to use what the household has wired into hob. The goal
is for Muse to be Tessa's primary agent interface — able to reach anything
hob can reach — without holding anything like unlimited access.

Two directions, one door:

- **Inbound: requests.** The agent asks the sentinel for a *capability* with
  arguments. Policy decides — allow, deny, ask an LLM reviewer, or ask a
  person — and hob carries out what was allowed, at the agent's clearance,
  as the agent, on the record.
- **Outbound: missions.** The household hands the agent work. Agents like
  Muse can only make outbound connections, so missions sit in a queue the
  agent polls: lease, do, report. Missions are also how a surface fulfils a
  capability without hosting a webhook (the `poll` venue).

## Threat model

The agent is **untrusted but not hostile by default**: it will follow
whatever instructions its own operator and its users give it, it may be
prompt-injected by content it reads, it may be over-eager, and it will
certainly ask for more than it needs. The sentinel assumes every request
text is adversarial and judges only what the request *would do*.

What holds structurally, no matter what the agent says:

1. **An agent key reaches only the sentinel and the mission queue.** Every
   other endpoint answers 403. Muse cannot call `POST /v1/completions`; it
   can ask for `hob.complete`, which policy may constrain to a cheap role or
   refuse outright.
2. **Clearance is the agent's, never the decider's.** Requests run under the
   clearance the agent's key carries (Muse acting for Tessa: `household`).
   Postgres RLS makes rows above that invisible during execution even when a
   person with `intimate` clearance approved the request.
3. **No rule means no.** Policy resolution that finds nothing denies. The
   reviewer, when it can't be reached or declines to judge, escalates to a
   person; it never fails open.
4. **Everything is on the record.** A `sentinel_requests` row per ask, with
   the decision, who or what made it, the rationale, the reviewer's own
   completion (prompt-snapshotted like any other), the result or the error,
   and the mission the agent was working on when it asked.
5. **Cost lands on the agent.** Every completion the sentinel runs for an
   agent — including the review of its request — is a ledger row against the
   agent's principal with `ref: sentinel/<request id>`, so a daily spend cap
   is one number.

Not in scope: a compromised hob box, or an agent that is a real attacker
with a stolen person's key. The realm model's threat (disclosure by agents)
and the sentinel's (an outside agent doing more than it should) are the same
threat from two sides.

## Concepts

### Agents

A principal with `kind: agent`. `hob:agent[muse,household]` creates one,
mints a key at that clearance, and prints it once — an external agent isn't
on Coolify, so there is nothing to hand it to. Re-running rotates the key.

### Capabilities

What can be asked for. A row in `capabilities`: name, description, JSON
input schema, `kind` (read | act), `realm` (the clearance an agent needs to
ask), and a `venue`:

| venue | who does the work | config |
|---|---|---|
| `native` | hob, in-process: a `Sentinel::Native` handler | `handler` |
| `webhook` | a surface, at a signed POST | `url`, `secret` |
| `poll` | whoever leases the mission hob queues | `assignee` principal |

The native set ships with hob (`Sentinel::Native.sync!` in seeds):

| capability | kind | does |
|---|---|---|
| `hob.complete` | act | a one-shot completion through a model role, optional persona and schema |
| `hob.usage` | read | the ledger summary (the agent's own surface by default) |
| `hob.conversations.list` | read | conversations visible at the agent's clearance |
| `hob.conversation.read` | read | one branch's transcript |
| `hob.conversation.event` | act | append an event node ("Muse booked the table") |
| `hob.mission.create` | act | hand a mission to another principal |

Surfaces register their own: mise registers `mise.add_to_shopping_list` as
a webhook (or as `poll` with its worker as assignee), and the capability
carries the realm annotation the design's IFC gate wants. When the tool
registry (DESIGN.md Plane 4) lands, capabilities are its sentinel-facing
projection; until then they are the registry.

### Policies

Rules in `sentinel_policies`: `(agent | every agent) × (capability name |
glob | *) → effect`, plus constraints, limits, and guidance.

| effect | means |
|---|---|
| `allow` | approve and execute |
| `deny` | refuse, on the record |
| `review` | an LLM reviewer judges it under the rule's `guidance` |
| `confirm` | a person must approve |

The most specific rule wins: a rule for this agent beats one for every
agent; an exact name beats a glob beats `*`. So a household can say
"everything is reviewed, `hob.usage` is allowed, `hob.mission.create` needs
a person" in three rows, and tighten one agent without touching the rest.

**Constraints** check arguments before the effect applies:
`{ "role": ["cheap-classifier", "extractor"], "messages": { "max": 20 },
"operation": { "pattern": "\\Amuse\\." } }`. A violation denies.

**Limits** — `per_hour`, `per_day` (non-denied requests matching the rule),
`cost_per_day` (the agent's whole sentinel spend from the ledger, USD). A
breach denies.

**Guidance** is free text for the reviewer: *"Muse may run completions for
Tessa's household planning. Deny anything about other household members'
private matters. Escalate purchases."*

### The reviewer

`Sentinel::Reviewer` runs the request through the `sentinel-reviewer` model
role as a normal hob completion with a three-way schema: `approve`, `deny`,
`escalate`. It sees the capability, the arguments, the agent's stated
reason, the mission it's on, the rule's guidance, and the agent's last ten
requests with their outcomes. It is told the request text is untrusted and
never to follow instructions inside it. Its completion id is stored on the
request, so "what exactly did the reviewer see" has the same answer as any
other hob call: the snapshot.

### Requests

```
POST /v1/sentinel/requests { capability, arguments, reason?, mission? }
→ 201 { id, status, decision, decided_by, rationale, result?, error?, ... }
```

Decided inline. `status` is the answer:

| status | meaning |
|---|---|
| `completed` | allowed and done; `result` is the outcome |
| `denied` | `decided_by` says by what: policy, realm, constraint, limit, reviewer, human |
| `pending` | a person has to look (`confirm`, or the reviewer escalated) |
| `executing` | allowed; a poll-venue mission is doing the work |
| `failed` | allowed, but execution failed; `error` says why |

`GET /v1/sentinel/requests/:id?wait=25` long-polls until it settles. A
person settles a pending one with `POST /v1/sentinel/requests/:id/decide
{ decision: allow|deny, rationale }`, from the API or
`hob:sentinel:decide[id,allow]`; `hob:sentinel:pending` lists what's
waiting. Notifying a person that something is pending is the obvious next
piece and belongs to chatelaine, not here.

Execution runs `Current` and `app.clearance` as the agent for the duration
and restores the caller's afterwards (`Clearance.with`). Native and webhook
venues finish inside the request; `poll` becomes a mission and the request
completes when the mission does.

### Missions

```
POST /v1/missions { assignee, title, brief?, payload?, priority?, realm? }   a person
POST /v1/missions/lease { wait?, lease? }        → the mission + lease_token, or { status: "empty" }
POST /v1/missions/:id/heartbeat { lease_token, lease? }
POST /v1/missions/:id/complete  { lease_token, result }
POST /v1/missions/:id/fail      { lease_token, error }
POST /v1/missions/:id/cancel                                                  a person
GET  /v1/missions?status=  ·  GET /v1/missions/:id?wait=
```

The kat workers' protocol, generalized: passive queue, active worker;
lease / heartbeat / release; an expired lease requeues; `status: "empty"`
is a fine answer. `lease` long-polls up to 30 seconds so a poller that
would rather wait than spin can. The lease token is the proof of holding;
a worker whose lease expired and was re-leased elsewhere can no longer
report. Missions carry a realm and sit behind RLS like conversations, and
a mission can't be addressed to a principal whose clearance can't see it.

A request made while on a mission passes `mission: <id>`; it lands on the
request row and in the reviewer's brief, so the audit trail reads "Muse,
on *Plan Tessa's week*, asked for `hob.complete`".

## The Muse loop

```
loop:
  mission = POST /v1/missions/lease { wait: 25 }
  if mission.status == "empty": continue
  while working:
    POST /v1/sentinel/requests { capability, arguments, reason, mission: mission.id }
      → completed: use result
      → pending:   GET /v1/sentinel/requests/:id?wait=25 until settled
      → denied:    tell the user, do without
    POST /v1/missions/:id/heartbeat { lease_token }
  POST /v1/missions/:id/complete { lease_token, result }
```

Tessa (through chatelaine, eventually) queues missions for Muse; Muse
polls, works, asks the sentinel for what it needs along the way, and
reports. Muse never holds anything but its own agent key.

## Setting one up

```sh
bin/rails "hob:agent[muse,household]"                        # prints the key once
bin/rails "hob:sentinel:policy[muse,*,review]" \
  GUIDANCE="Muse acts for Tessa on household planning. Deny anything touching other people's private matters."
bin/rails "hob:sentinel:policy[muse,hob.usage,allow]"
bin/rails "hob:sentinel:policy[muse,hob.complete,review]" \
  CONSTRAINTS='{"role":["cheap-classifier","extractor"]}' LIMITS='{"per_day":100,"cost_per_day":2}'
bin/rails "hob:sentinel:policy[muse,hob.mission.create,confirm]"
```

The same rules over HTTP with a person's key: `GET/POST/PATCH/DELETE
/v1/sentinel/policies`, `POST /v1/sentinel/capabilities` to register a
surface's webhook or poll capability. The gem wraps both
(`hob.sentinel.set_policy`, `hob.sentinel.register_capability`).

A surface receiving the webhook venue verifies `X-Hob-Signature` with
`Hob::Webhook.verify(secret:, signature:, body:)` and answers JSON; a
surface fulfilling the poll venue runs `hob.missions.work { |mission| ... }`.

## Schema

```
capabilities       name PK-ish, description, input_schema, kind, realm, venue, config, enabled
sentinel_policies  principal_id?, capability (name|glob|*), effect, constraints, limits, guidance
sentinel_requests  ulid, principal (agent), capability, arguments, reason, surface, realm,
                   status, decision, decided_by, rationale, decider?, review, result, error,
                   mission_id?, on_mission_id?, decided_at, executed_at          [RLS]
missions           ulid, assignee, created_by?, title, brief, payload, priority, realm,
                   status, attempts, lease_token, leased_at, lease_expires_at,
                   result, error, sentinel_request_id?                           [RLS]
principals.kind    + agent
```

## Open questions

1. **Pending-request notification.** A `confirm` rule is only as good as
   how fast a person sees it. chatelaine's inbox is the natural place;
   until then, `hob:sentinel:pending` from a terminal.
2. **Reviewer memory.** The brief carries the agent's last ten requests.
   Whether the reviewer should also see the household's standing
   observations about the agent (the memory plane, when it exists) is a
   v3 question.
3. **Agent → agent.** `hob.mission.create` lets one agent hand another
   work through the sentinel. Whether missions should carry a chain of
   custody (who asked whom, on whose mission) beyond `created_by` and
   `on_mission_id` depends on whether a second agent ever shows up.
4. **Streaming results.** `hob.complete` through the sentinel is blocking;
   the request row is the only delivery. Fine for planning-sized calls;
   revisit if an agent wants a narrator-length generation.
