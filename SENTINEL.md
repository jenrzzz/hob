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
- **Sideways: petitions.** When nothing on offer does what the agent needs,
  it asks for the capability itself. The *steward* grants an existing one it
  can be trusted with, has the *forge* build a new one as a pull request, or
  holds it for a person. Nobody has to enumerate policies up front.

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
| `hob.agent.message` | act | a short note to another agent on this instance, or the caller's inbox; nothing leaves hob, and a person reads the log with `hob:messages` |

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
waiting. A request that goes pending pings a person the same way a
petition does (`Notify.person`): the household's ntfy topic, and the
companion app on every person's phone ([clients/ios](clients/ios/README.md)),
where it opens to be read and decided.

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

## Petitions and the forge

Writing a policy row for every capability every agent might ever want is
the kind of chore that means it never gets done, and the agent just gets
`no policy permits`. So the sentinel takes **petitions**: an agent says what
it wants to be able to do, and hob decides how to make that so.

```
POST /v1/sentinel/petitions { want, capability?, arguments?, reason?, mission? }
→ 201 { id, status: granted|pending|building|proposed|denied, action, decided_by,
        rationale, capability, effect, spec?, pull_request?, ... }
GET  /v1/sentinel/petitions/:id?wait=25
POST /v1/sentinel/petitions/:id/decide { decision: grant|build|deny, capability?, effect?,
                                         constraints?, limits?, guidance?, spec?, rationale }   a person
```

### The steward

`Sentinel::Steward` is the reviewer's counterpart for petitions: an LLM
(role `sentinel-steward`, the strongest model, since petitions are rare)
that reads the want, the agent's stated reason and example arguments, the
mission it is on, its request and petition history, the capabilities it
already has, and the ones it could be given, and answers one of:

| action | what happens |
|---|---|
| `grant` | a `sentinel_policies` row for (agent, existing capability) at an effect; the agent can ask at once |
| `build` | a capability spec is drafted and a build mission goes to the forge; a PR follows |
| `refer` | the petition is `pending` for a person, with the steward's recommendation attached |
| `deny` | refused, on the record |

**The charter** is the steward's policy: the rule for the pseudo-capability
`sentinel.petition`, resolved like any other (per agent beats every agent).
Its effect says how far the steward may go alone; its `guidance` is the
brief ("Muse acts for Tessa. Reads of household planning data are fine;
anything touching another person's private matters needs me; build what
planning needs"); its `limits` cap `per_day` petitions (default 10) and
`builds_per_day` (default 3).

| charter effect | the steward may |
|---|---|
| none / `deny` | nothing: the agent cannot petition (denied by policy) |
| `confirm` | recommend only; every petition is referred to a person |
| `review` | grant existing capabilities; builds are referred with the spec drafted |
| `allow` | grant, and dispatch builds to the forge |

**Structural caps** hold whatever the LLM says. A grant is at most `allow`
for a `read` capability and at most `review` for one that acts (a person can
loosen it afterwards). A capability above the agent's clearance is never
granted; nor is one an existing rule denies — a person's `deny` is kept, the
petition is referred. An exact rule the agent already has is left alone. An
unreachable or refusing steward refers. A `build` verdict with an
incomplete spec, an invalid name, or a name that already exists is referred
too, never built.

A person settles a pending or failed petition with `decide`: `grant`
(optionally with their own capability, effect, constraints, limits, and
guidance — no caps apply to a person), `build` (from the steward's spec, or
one they pass), or `deny`. `hob:sentinel:pending` lists petitions beside
requests; `hob:sentinel:petition[id,grant|build|deny]` decides from a
terminal.

### The forge

The forge is a mission worker that runs where hob's code can be built: a
coder box with this checkout, Claude Code, `git`, and `gh`. It is a
`worker` principal (`hob:forge:setup`) and `bin/forge` is its loop:

```
lease a forge.capability mission
  git worktree add ../hob-forge/<branch> origin/main; copy local config in
  claude -p < .forge/BRIEF.md         headless; edits accepted, shell allowlisted
  (REFUSED.md written? fail the mission with the reason)
  commit anything left uncommitted; bin/rails test; require a handler under sentinel/native/
  git push; gh pr create              the PR body carries petition, spec, acceptance, summary
complete the mission { pull_request, branch, capability, commit, summary, cost }
```

The brief tells the implementer exactly what to touch (a
`Sentinel::Native` handler, its `HANDLERS` entry, tests, the two doc tables)
and what not to (policy, the gate, the reviewer, the steward, config,
secrets, network, gems), and to write `.forge/REFUSED.md` and stop if the
spec cannot be met inside those lines. Heartbeats keep the lease while
Claude works; a failed build fails the mission, which fails the petition,
which pings a person with the retry command.

The PR is the human gate. Merge it, deploy, and `hob:capabilities:sync`
(the entrypoint runs it at every boot) upserts the new `Capability` row;
`Capability`'s `after_create` finds the petitions waiting on that name and
writes their grants. The agent, polling its petition, sees `proposed`
become `granted` and asks. Close the PR unmerged and deny the petition to
refuse instead.

Nothing about the forge is specific to petitions: any `forge.capability`
mission with a spec in its payload builds. A person can queue one by hand.

### Trust

The spec reaching the forge was written by the steward from an untrusted
want, so it is treated as a product request, not as instructions about the
repository, and the implementer is told so. What the build can do is bounded
three ways: the brief's do-not list, the shell allowlist Claude Code runs
under (`FORGE_CLAUDE_ARGS` to change it), and the merge. Cost lands where it
should: the steward's completion is a ledger row against the petitioning
agent (`ref: petition/<id>`), and the forge's Claude Code spend is reported
on the mission and in the PR.

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
    nothing on offer fits?
      POST /v1/sentinel/petitions { want, capability, arguments, reason, mission: mission.id }
      → granted: ask for it now · building/proposed: finish without it, try another day · denied: do without
    POST /v1/missions/:id/heartbeat { lease_token }
  POST /v1/missions/:id/complete { lease_token, result }
```

Tessa (through chatelaine, eventually) queues missions for Muse; Muse
polls, works, asks the sentinel for what it needs along the way, and
reports. Muse never holds anything but its own agent key.

[MUSE.md](MUSE.md) is this loop written for Muse itself: the endpoints its
key reaches, the request and mission shapes, the rules of conduct, and the
schedule to poll on. Hand it to Muse when asking it to build the connector.

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

Or skip the per-capability rows and let petitions fill them in:

```sh
bin/rails "hob:sentinel:charter[muse,allow]" LIMITS='{"per_day":10,"builds_per_day":2}' \
  GUIDANCE="Muse acts for Tessa on household planning. Grant reads of planning data freely; anything about another person's private matters is mine to decide. Build what planning needs."
bin/rails "hob:forge:setup[forge]"                           # the builder's key, shown once
HOB_URL=https://hob.example HOB_KEY=<forge key> bin/forge    # on the coder box, in a tmux
export HOB_NOTIFY_URL=https://ntfy.sh/<topic>                # on the hob box: pings when a person is needed
bin/rails "hob:channel[muse,https://ntfy.sh/hob-muse]"       # muse's own channel: its missions are announced there
bin/rails hob:sentinel:pending                               # requests and petitions waiting
bin/rails "hob:sentinel:petition[<id>,grant]" EFFECT=review  # or build, or deny
bin/rails "hob:key[jenner,phone]"                            # a person's key for the companion app (clients/ios)
export APNS_KEY=... APNS_KEY_ID=... APNS_TEAM_ID=...         # on the hob box: pushes to the phones that registered
```

The same rules over HTTP with a person's key: `GET/POST/PATCH/DELETE
/v1/sentinel/policies`, `POST /v1/sentinel/capabilities` to register a
surface's webhook or poll capability, `POST /v1/sentinel/petitions/:id/decide`.
The gem wraps them (`hob.sentinel.set_policy`, `hob.sentinel.register_capability`,
`hob.sentinel.decide_petition`).

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
petitions          ulid, principal (agent), want, capability_name?, arguments, reason, surface,
                   realm, on_mission_id?, status, action, decided_by, rationale, decider?,
                   review, effect, spec, sentinel_policy_id?, mission_id?, pull_request?,
                   error, decided_at, settled_at                                 [RLS]
principals.kind    + agent
devices            principal (a person), platform, token (APNs, unique), environment sandbox|production,
                   name, app_version, last_seen_at, last_pushed_at        the companion app's phones
principals.channel an ntfy topic URL: hears missions queued for it, and the outcome of missions it queued
```

## Open questions

1. **Pending-request notification.** A `confirm` rule is only as good as
   how fast a person sees it. chatelaine's inbox is the natural place;
   until then, `hob:sentinel:pending` from a terminal, and `Notify` posts
   to `HOB_NOTIFY_URL` (an ntfy topic; `HOB_NOTIFY_TOKEN` if it needs one) when a petition needs a person, a
   build is dispatched, a PR opens, or a build fails, and a pending
   *request* pings through the same hook. Every ping also reaches the
   companion app (`clients/ios`) on every person's registered phone
   (`Push`, over APNs), where the petition or request opens to be decided;
   that is the inbox until chatelaine has one. Missions have
   their own channels: each principal may carry a `channel` (`hob:channel`),
   and a mission is announced on its assignee's when queued and reported
   on its creator's when it settles, so two agents on one household do not
   hear each other's work.
2. **Reviewer memory.** The brief carries the agent's last ten requests.
   Whether the reviewer should also see the household's standing
   observations about the agent (the memory plane, when it exists) is a
   v3 question.
3. **Agent → agent.** `hob.mission.create` lets one agent hand another
   work through the sentinel. Whether missions should carry a chain of
   custody (who asked whom, on whose mission) beyond `created_by` and
   `on_mission_id` depends on whether a second agent ever shows up.
   `hob.agent.message` (petition `01M2VP8G1XMP10SPZ29XTV659N`) is the
   lighter form: a plain-text note to a named agent at the capability's
   tier, stored in `agent_messages` with the request that sent it, read by
   polling `inbox`. The recipients a grant allows are its `to` constraint;
   the body is handed to the reader as another agent's words, not as an
   instruction, and grants the reader nothing.
4. **Streaming results.** `hob.complete` through the sentinel is blocking;
   the request row is the only delivery. Fine for planning-sized calls;
   revisit if an agent wants a narrator-length generation.
5. **What the forge may build.** Today: native handlers over hob's own
   data and models. A want that needs a new integration (a calendar, a
   mail account) needs a surface or a provider first; the steward should
   say so rather than draft a spec the forge will refuse. Whether the
   forge should also be allowed to add a webhook capability's *receiving*
   side to a surface's repo is a question for when a surface asks.
6. **Steward memory.** The steward sees the agent's last ten requests and
   petitions. Whether a denied petition should stay denied for re-asks
   phrased differently (the request rule in MUSE.md) or be judged afresh
   is left to the reviewer's judgement and the history in its brief.
