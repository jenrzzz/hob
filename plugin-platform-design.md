# A plugin platform for hob

*Feasibility and design investigation. No implementation, no code changes. This document is the
deliverable.*

Jenner's ask: today every app integration requires defining capabilities inside hob itself (mail,
todo, mise, ward, budget, records — all either native Ruby inside this repo or a webhook row a
person registers by hand). The next phase should let different apps expose new capabilities
themselves, with those capabilities showing up in hob automatically, without a hob code change.

This document first describes hob's current capability flow as found in the repository, then
proposes a plugin model that extends it.

---

## Part 1 — How capabilities work today

### The catalog is one table, three venues

Every capability — mail, calendar, budget, mise's recipes, hob's own `hob.complete` — is a row in
`capabilities` (`app/models/capability.rb`): a name, a description, a JSON input schema, a `kind`
(`read` or `act`), a `realm` (the minimum clearance an agent needs to even ask), and a `venue`:

| venue | who does the work | how it's added |
|---|---|---|
| `native` | hob, in-process, a `Sentinel::Native` handler class | a Ruby class is written in this repo, listed in `Sentinel::Native::HANDLERS`, and upserted by `Sentinel::Native.sync!` (run at boot) |
| `webhook` | a surface (an app the household runs), at a signed POST | a person runs `bin/rails hob:surface:register[...]`, which fetches the surface's own manifest and upserts one `Capability` row per entry |
| `poll` | whoever leases the resulting mission | the same manifest/registration path, with an `assignee` principal instead of a URL |

**Native is the overwhelming majority today.** Mail, calendar, todo, budget, records, ward,
people, browse, http, and hob's own completion/conversation/mission/schedule primitives are all
`Sentinel::Native` handlers — about 90 of them (`app/services/sentinel/native/*.rb`). Each is a
small Ruby class with a `CAPABILITY` constant (name, description, schema, kind, realm,
`requires_person`) and a `#call`. **Adding one is, definitionally, a hob code change**: a new file,
a new `HANDLERS` entry, a deploy, then `sync!` upserts the row. The backend behind a native
capability is often itself an external system (Fastmail over JMAP for mail, OmniFocus for todos,
a bank feed for budget — see `mail_backends`, `todo_backends`, `calendar_backends`), but the
*capability* — the thing an agent asks hob for — is still hob's own code talking to that system.

**Webhook is the one venue where the app owns the implementation.** The only production example is
mise, the household's kitchen app. The mechanism (`app/services/surface_capabilities.rb`,
`SurfaceCapabilities`):

1. mise serves a manifest at `GET /hob/capabilities`: `{ surface: "mise", capabilities: [{ name,
   description, kind, realm, input_schema }, ...] }`, every name prefixed `mise.`.
2. A person runs `bin/rails "hob:surface:register[mise,https://mise.example.com]"
   APP=<coolify-app-uuid>`. hob fetches the manifest, validates each entry (name prefix, required
   fields), mints an HMAC-SHA256 secret, pushes it to mise's Coolify app as
   `HOB_WEBHOOK_SECRET`, and upserts a `Capability` row per entry (`venue: webhook`, `config: {url,
   secret, surface}`).
3. From then on, an allowed request is delivered as a signed POST
   (`Sentinel::Webhook.deliver` / `.verify`, `X-Hob-Signature: t=<ts>,v1=<hmac>`, 300-second
   tolerance) to `https://mise.example.com/hob/capabilities/<name>`; mise answers 2xx with a JSON
   result of any shape, which hob stores as-is, or a non-2xx with `{error}`.
4. Re-running the same rake task is how mise's capabilities stay in sync: new manifest entries are
   added, descriptions/schemas follow the manifest, an entry no longer listed is **disabled, not
   deleted** (`disable_missing`), and the secret rotates. `realm`, `kind`, and `enabled` are
   deliberately **left alone** on a row that already exists — a household can tune what the app
   proposed, and a re-registration cannot silently loosen it.

This is already close to a plugin mechanism in shape — an app's own manifest determines what
shows up — but it is **pull-based and person-triggered**: hob only learns about a change when a
person remembers to re-run the rake task. There is no scheduled or event-driven refresh, and the
flow assumes the app is a household-run Coolify deployment (the secret is pushed through hob's own
Coolify API token, `Provision::Coolify`).

### Policy is independent of venue

`sentinel_policies` (`app/models/sentinel_policy.rb`) rules are `(agent | every agent) ×
(capability name | glob | *) → effect (allow | deny | review | confirm)`, plus constraints,
limits, and free-text guidance. The gate (`app/services/sentinel/gate.rb`) resolves the most
specific matching rule, checks the capability's `realm` against the request's clearance,
evaluates constraints and limits, and for `review` hands off to an LLM
(`Sentinel::Reviewer`) carrying the rule's guidance and the agent's recent history. **A capability
whose config says `requires_person: true` cannot be loosened past `confirm`/`deny` by any policy
row** — this floor holds regardless of venue, and regardless of who wrote the capability. This
separation (an app proposes a capability; a household's policy decides who may use it and how) is
already the right shape for a plugin platform and needs no change.

### Realms gate who may even ask

Every capability carries a minimum `realm` (`household` ⊆ `personal` ⊆ `intimate`, clearance reads
downward-inclusive). A webhook capability defaults to `household` if the manifest omits a realm,
and — as above — that default is frozen on the row once created, even if the manifest later says
otherwise. There is currently no notion of a capability's *sink* realm (where its effects become
visible, as opposed to who may call it) — `DESIGN.md`'s planned IFC gate for the (not-yet-built)
general tool registry has one, but today's `capabilities` table doesn't.

### The only existing path to a genuinely new capability still ends in a hob code change

When an agent wants something nothing currently offers, it **petitions**
(`POST /v1/sentinel/petitions`). `Sentinel::Steward`, an LLM under a per-agent "charter" policy
rule, answers `grant` (an existing capability, a new policy row), `build` (drafts a complete spec
and dispatches a `forge.capability` mission), `refer` (a person decides), or `deny`. A `build`
verdict sends the spec to **the forge** — a sandboxed Claude Code agent (in an agentbox/Coder
workspace) that writes a new `Sentinel::Native` handler **inside this repository**, runs the test
suite, and opens a pull request. A person must merge it; only after merge and deploy does
`hob:capabilities:sync` (run on every boot) pick up the row, at which point any petitions waiting
on that name are granted automatically (`Capability#after_create` → `Petition.fulfil!`).

So today, every way a capability that doesn't already exist gets created — whether a person writes
it or an LLM-steward-triggered forge build writes it — results in a PR against hob's own codebase.
The webhook venue lets an *existing* app add capabilities without a hob PR, but only for apps the
household already runs on its own infrastructure, registered by a person, by hand, with no
automatic refresh.

### One relevant planned-but-unbuilt venue

`DESIGN.md`'s Plane 4 describes a fourth tool venue, not yet implemented: an **MCP bridge**, where
hob acts as an MCP client to external MCP servers and discovers their tools via `list_tools`
instead of a hob-code declaration — "existing MCP servers plug in without hob-specific code." This
is the one place hob's own design already anticipated exactly the problem Jenner is now asking
about, for tools generally rather than sentinel capabilities specifically. It's a natural point of
contact for this proposal rather than something to duplicate.

---

## Part 2 — Design proposal

The proposal generalizes the webhook venue — the one place an app already owns its own
implementation — into a first-class `plugin` venue, while deliberately keeping the gate, policy,
realm, and audit machinery untouched. Nothing here replaces native capabilities for hob's own
first-party data (mail, calendar, budget, etc.); it is additive, for apps that are not hob.

### 1. How an app registers and advertises capabilities

Keep the manifest shape mise already serves, generalized and versioned:

```json
{
  "plugin": "feedreader",
  "version": "2026-10-01",
  "capabilities": [
    {
      "name": "feedreader.entries",
      "version": 1,
      "kind": "read",
      "realm": "household",
      "description": "Unread entries across subscribed feeds, newest first.",
      "input_schema": { "...": "..." },
      "output_schema": { "...": "..." },
      "errors": ["invalid_argument", "unavailable"]
    }
  ]
}
```

Registration still has two triggers:

- **Bootstrap (unchanged in spirit):** a person runs a registration command once, pointing hob at
  the plugin's manifest URL. Establishing *initial* trust is a human act today (mise's
  `APP=<coolify-app-uuid>`) and should stay one — this mirrors every other place hob refuses to
  auto-promote trust (realm promotion, petition charters: "nothing auto-promotes, nothing
  auto-demotes" is already a load-bearing hob principle, SENTINEL.md/DESIGN.md).
- **Ongoing self-announcement:** once bootstrapped, the plugin may ping a small authenticated
  endpoint ("my manifest changed") to queue an immediate refresh, and hob additionally polls every
  registered plugin's manifest on a schedule (reusing the existing `schedules`/Solid Queue
  machinery from SCHEDULES.md). Both paths run the same reconcile-and-upsert logic
  `SurfaceCapabilities` already has today (new entries created, changed descriptions/schemas
  follow the manifest, entries no longer listed disabled-not-deleted).

### 2. The capability schema: names, inputs, outputs, errors

Keep `name` (`plugin.verb`, validated against the plugin's own prefix, exactly as today),
`description`, `input_schema` (JSON Schema), `kind` (`read`/`act`), `realm`. Add two things that
are missing today:

- **`output_schema`.** Today a webhook result is "any shape; stored as-is"
  (`Sentinel::Webhook.deliver`'s own comment). That's a real gap for a plugin platform: neither the
  calling agent, the reviewer, nor a household member auditing a request can know what a
  capability is supposed to return. Require `output_schema` in the manifest and validate results
  against it on delivery; a mismatch fails the request with a structured error rather than
  silently storing malformed JSON.
- **`errors`.** A small enum per capability (`not_found`, `invalid_argument`, `rate_limited`,
  `unavailable`, `unauthorized_upstream`, …), mirroring the distinction
  `Sentinel::Executor::ANSWERS` already draws between "an answer the agent should hear" (bad
  argument, backend down) and "a fault in hob." A plugin's failures should land in this enum so a
  reviewer or agent gets something it can act on, not a free-text string plucked out of an HTTP
  body.

Both are additive to mise's existing manifest shape and can be phased in with a grace period
(below) rather than demanded on day one.

### 3. Discovery without hob changes

Discovery already happens in two complementary ways once a plugin is bootstrapped, and this
proposal keeps both:

- **Catalog growth:** the scheduled refresh (section 1) means a plugin adding, changing, or
  retiring a capability in its manifest shows up in hob's `capabilities` table without anyone
  touching hob's own code or deploying it — the thing Jenner is asking for, achieved by turning
  `SurfaceCapabilities`'s existing manual trigger into a scheduled + self-service one.
- **Prompt/agent-facing growth:** `hob.capability.search` already exists
  (`Sentinel::Native::CapabilitySearch`) as a keyword search over the live catalog, filtered to
  the caller's clearance — so an agent doesn't need hob's *system prompt* rewritten to learn about
  a new capability either. These two forms of "no hob change" already compose; the plugin
  platform's job is only to make the first one automatic.

### 4. Authentication and trust

Today's model is a single long-lived HMAC secret, handed to the surface once over its own Coolify
environment, trust-on-first-registration (whoever answers the manifest URL at the moment a person
runs the rake task is trusted from then on). That's adequate for mise — code the household wrote,
deployed on infrastructure the household controls — but not for a plugin the household didn't
build.

Proposal:

- Every plugin gets its own `Principal` (`kind: plugin`, parallel to today's `agent`/`worker`),
  carrying an **inbound key** (verifies the plugin's self-announce pings are really from it) and an
  **outbound signing secret** (hob → plugin, same HMAC scheme and rotation `SurfaceCapabilities`
  already implements).
- A plugin key reaches **only** plugin-management endpoints (manifest push/self-announce) — never
  the sentinel, never a conversation, never another plugin's data. This is the same structural
  rule the sentinel already holds for agents ("an agent key reaches only the sentinel and the
  mission queue") applied one level over.
- **Containment of a compromised or misbehaving plugin** reuses machinery hob already built for a
  different trust failure: an agent whose authorization claim was proven fabricated gets its
  capabilities **frozen** (`principals.capabilities_frozen_at`/`_reason` — every new request denied
  at the gate until a person clears it). Generalize that freeze to plugin principals as an explicit
  quarantine action: one toggle denies every capability the plugin offers, instead of a person
  having to hand-disable rows one at a time.
- What this does **not** need to be: cryptographic attestation of the plugin's code. hob's own
  stated non-goal is "a trusted service, not cryptographic isolation between realms"; a plugin the
  household chose to trust is the same bet, one level out.

### 5. Sentinel policy and per-capability approval

No change to the policy model itself — this is the strongest argument for the design. A plugin's
capabilities are rows with `venue: plugin`; `SentinelPolicy.resolve` and `Sentinel::Gate` don't
care what venue a capability has. A household still writes (or a steward still grants, via the
existing petition flow) `allow`/`review`/`confirm`/`deny` rows exactly as for mise today, and
`requires_person` remains an unbypassable floor regardless of who authored the capability.

One addition: a brand-new capability from a scheduled refresh currently lands with **no** policy
row, which the gate already treats safely ("no rule means no" — every request for it is denied
until someone writes a rule) but silently. Make that loud: pipe `SurfaceCapabilities`'s existing
`created` count into the same `Notify.person` hook the steward and petitions already use ("mise's
new capability `mise.pantry.scan` just appeared, unreviewed, nobody can use it yet"), so automatic
discovery doesn't mean automatic invisibility to the person who should decide whether it's worth
a policy at all.

### 6. Realm handling for personal versus household capabilities

Keep the existing rule that a capability's `realm` is set from the manifest once, then **left
alone** on updates — a household's own tuning always wins over what the app claims about itself,
exactly as today.

New: not every plugin is a shared household app. `todo_backends`, `calendar_backends`, and
`mail_backends` already carry a `principal_id` for exactly this reason — a backend can be one
person's own. Extend capabilities the same way: a plugin may register as scoped to one principal
(a person's own self-hosted reader, say), and its capabilities should only be offerable to agents
acting for that principal or above its clearance, rather than assuming every plugin is
household-shared the way webhook capabilities implicitly do today.

Separately, this is the right forcing function to add a **sink realm** to the `capabilities`
table — today's `realm` only gates who may *ask*; nothing records where a capability's *effects*
become visible, which is exactly the IFC concept `DESIGN.md`'s Plane 4 already specifies for the
general tool registry (`sink_realm`, gated against conversation taint). A plugin platform is a
good occasion to finally add it rather than inventing a second mechanism later when the general
tool registry arrives.

### 7. Versioning and deprecation

Capability names are the compatibility boundary today, and nothing stops a plugin from changing an
existing capability's `input_schema` in place, silently breaking every caller and invalidating any
`SentinelPolicy` constraints written against the old argument names. Proposal:

- The manifest entry carries an explicit `version` (an integer or date). Multiple versions of a
  base capability may coexist as separate `Capability` rows (`plugin.verb` at version 1 and 2
  simultaneously) for as long as the plugin's manifest lists both.
- On sync, hob diffs a same-name, same-version entry's schema; a change that narrows required
  fields or changes a type is treated as a breaking change and **refused for that one entry**
  (quarantined, not the whole plugin) rather than silently applied — forcing the plugin to mint a
  new version name instead.
- Retiring a version is the same `disable_missing` path mise already exercises today — no longer
  listed in the manifest, disabled not deleted, history preserved.
- A capability nearing retirement carries `deprecated_at`/`sunset_at`, surfaced through
  `hob.capability.search` so a caller gets a warning before a hard cutover, not just a future
  "unknown capability."

### 8. Failure isolation and sandboxing

Today's webhook delivery has flat timeouts (10s open / 60s read, `Net::HTTP` defaults in
`Sentinel::Webhook`), no retries, no rate limiting beyond each *agent's* own `per_hour`/`per_day`
sentinel policy limits, and no tracking of a plugin's health — a failing delivery fails that one
request (`Sentinel::Executor` catches `Webhook::Error` and marks it `failed`) and nothing more, but
there's also no mechanism that notices a plugin is *consistently* failing until a person does.

Proposal, layered on the existing executor/webhook path without changing its wire format:

- **Per-capability timeout**, manifest-declared, bounded by a hob-wide ceiling, replacing today's
  one-size-fits-all values.
- **Retries** only for `read`-kind capabilities on a transient network error (never for `act` —
  the `kind` field already distinguishes exactly the cases where a retry is safe from the ones
  where it would double a side effect).
- **A circuit breaker per plugin**, tracking rolling success/failure the same way
  `Sentinel::Gate#limit_exceeded` already counts requests over a window: a consistently-failing
  plugin trips the breaker and new requests fail fast with a structured `unavailable` error
  instead of queueing up timeouts one at a time.
- **An output that doesn't match its declared `output_schema`, or a response that looks like it's
  lying about what it did, counts against the breaker too** — "misbehaving" is a trust signal, not
  just a liveness one, and should be able to trigger the same quarantine path as a key compromise
  (section 4).
- **Process isolation stays outside hob.** A plugin that needs its own failure domain runs its own
  process, the way mise already does — hob does not need a per-plugin worker pool or sandbox of
  its own; the sentinel's job is to fail fast and keep every other capability's requests
  unaffected, which the circuit breaker achieves without new infrastructure.

### 9. What hob core must still own

- **The catalog's authority and the gate's decision** (`capabilities`, `sentinel_policies`,
  `Sentinel::Gate`). A plugin proposes a capability; it never decides who may call it.
- **Realm assignment and RLS.** A manifest may suggest a realm; the household's data boundary is
  hob's to set and hold, exactly as "realm, kind, and enabled are left alone" already encodes.
- **The reviewer and the authorization-claim rubric** (`Sentinel::Reviewer`,
  `Sentinel::Claims::Rubric`). Judgment calls about a specific request's legitimacy stay inside
  hob's trust boundary; a plugin never gets to self-attest "the user said yes."
- **The audit log** (`sentinel_requests`, `authorization_claims`) — every decision and delivery is
  recorded by hob regardless of venue.
- **Identity and secrets.** Plugin principals, keys, and signing secrets are hob-minted and
  hob-rotated; a plugin never picks its own id or secret.
- **The native/forge path for first-party data.** Mail, calendar, budget, records, ward, people,
  todo stay native. The plugin platform is additive, for apps that are not hob, not a replacement
  for how hob extends its own surface.
- **Cost accounting.** Anything a plugin capability triggers that spends hob-side compute (asking
  hob to run a completion, say) still lands in the usage ledger under the calling agent's
  principal, exactly as `ref: sentinel/<request id>` does today.

### 10. Mapping existing integrations

- **Mise (recipes, meal plan, shopping list, chefs, preferences).** Already the reference case —
  no mechanical change needed beyond migrating its registration from the manual rake trigger to
  scheduled self-service refresh, and mise adding `output_schema`/`errors`/`version` to its
  manifest (mise's own follow-up work, on the migration timeline in section 12). Its `webhook`
  venue becomes the `plugin` venue in name; the wire format doesn't change shape.
- **A Miniflux-style read-only feed reader.** A clean *first* adopter of the genuinely new parts of
  this platform, rather than a migration — Miniflux is third-party software the household didn't
  write, which makes it the right proving ground for the identity/trust model in section 4 (mise
  never tested it, since the household wrote and deploys mise itself). Two shapes:
  - a small first-party bridge (household code, deployed the way mise is) that speaks Miniflux's
    REST API and exposes a hob plugin manifest with `read`-only capabilities
    (`feedreader.feeds`, `feedreader.entries`) — the same shape `calendar_backends`/`mail_backends`
    already use to wrap a third-party protocol behind a hob-native capability, just exposed as a
    plugin instead of folded into hob's own code; or
  - the planned MCP-bridge venue (`DESIGN.md` Plane 4), if a community MCP server for Miniflux
    exists, in which case this integration is also the test of whether a plugin manifest and an
    MCP server's `tools/list` response should collapse into one mechanism (open question 5).

  Being low-stakes and read-only, its capabilities are a good exercise of "default `allow` with
  limits" policy without much downside if the review is wrong.
- **Mail and calendar.** Stay native. These are exactly the security-sensitive, often
  `requires_person`-gated (`mail.send`, `mail.reply`) first-party capabilities section 9 argues
  should never move off the venue hob itself controls end to end. The plugin platform's relevance
  here, if any, is narrower than "replace the native handler": a household member's own narrowly
  scoped automation (not a vendor app) could register as a personal plugin the way
  `calendar_contributors` already lets one agent push events for one owner — the mailbox/calendar
  read-write primitives themselves don't move.

### 11. Tradeoffs versus the current approach

- **Security.** More principals carry signing keys; more of "what a capability means" is a claim
  in a manifest rather than Ruby a person can read in a PR diff. The forge's `build` path is
  reviewable in a way a plugin's self-declared schema is not — that's a real loss this design
  doesn't erase, only mitigates (output validation, the breaker, quarantine).
- **Operational burden.** Trades "write and merge a Rails PR, deploy hob" for "run and monitor
  another small service, keep its secret rotated, watch its circuit-breaker state." Net burden
  drops when a household is already running the app anyway (mise, plausibly a feed reader); it
  rises for a one-off integration nobody else reuses, which argues for keeping "petition the forge
  for a native handler" as the right answer below some threshold, not something this plan retires.
- **Review load.** The *shape* of per-capability policy review doesn't change; the *volume* can,
  because any bootstrapped plugin can mint new capability names on its own schedule now. The "new
  capability, unreviewed" notification (section 5) is load-bearing, not a nice-to-have — without
  it, review load either explodes (someone must police every sync) or silently lapses (new
  capabilities sit un-policied and therefore unusable, safe but pointless).
- **Reversibility.** Removing a native capability needs a second PR; removing a plugin capability
  is the plugin's own manifest change or a person's quarantine action — easier to add safely, but
  also easier for a compromised plugin to change its own surface without the PR-review checkpoint
  that gates every new hob capability today.

### 12. A phased rollout that keeps existing integrations working

- **Phase 0 — naming, not mechanism.** Document mise's existing webhook registration as "the
  plugin venue, v0." Add the "new capability, unreviewed" notification to `SurfaceCapabilities`.
  No trust-model or schema changes; nothing about mise's own code needs to move.
- **Phase 1 — scheduled discovery.** Add `PluginRefreshJob` (Solid Queue, reusing the `schedules`
  machinery) alongside the existing manual rake task; add `output_schema`/`errors` to the manifest
  shape, accepted but optional during a grace period so mise's current manifest keeps working
  unmodified.
- **Phase 2 — plugin identity.** Introduce `Principal(kind: plugin)`, the inbound key, the
  self-announce endpoint, and the quarantine action generalized from
  `capabilities_frozen_at`. Migrate mise onto it first, since it's already in production and the
  bootstrap step (a person running a one-time command) doesn't get harder.
- **Phase 3 — versioning and the breaker.** Manifest `version` field, multi-row coexistence,
  schema-narrowing diff guard, per-plugin circuit breaker and health tracking — exercised first
  against mise, since it's low-risk to iterate on a plugin already in daily use.
- **Phase 4 — a genuinely external plugin.** The feed-reader bridge (or equivalent), as the proving
  ground for identity/trust against software the household didn't write, and for personal- (not
  just household-) scoped realm handling.
- **Phase 5 — reconcile with the planned MCP bridge.** Decide whether `DESIGN.md`'s Plane 4 MCP
  venue and this plugin venue are one mechanism or two, now that there's a real external plugin to
  compare against.

At every phase, mail/calendar/todo/budget/records/ward/people stay native and unmodified, and
mise's wire format changes only by gaining optional fields — nothing here requires a flag day.

### 13. Test cases against real capability gaps

Jenner's call: validate this design against five real gaps in what hob can do today, rather than
refine it further in the abstract. Three of these gaps already have a name in this repo —
`calendar_push.rb`'s own comment says "availability queries are a separate capability and a
separate decision" (`app/services/sentinel/native/calendar_push.rb:11-13`); CLIMATE.md is a
drafted-but-unbuilt proposal that already improvises a worse version of the plugin venue
("Interim path — records.\*, before the native build"); WARD.md's host inventory already reads a
server's kernel version through Coolify's read-only API
(`app/services/ward/inventory.rb:10-23`) but nothing reads a host's own distro facts directly. The
other two (contacts, notes/docs) are gaps with no existing proposal at all. Each case below is
written against sections 1–12 above; none of it changes those sections.

| # | app | capabilities | kind | realm |
|---|---|---|---|---|
| 1 | contacts (CardDAV) | `contacts.card.get/search/changes` | read | household, or personal (section 6) |
| 2 | family calendar + presence | `presence.current/history`, `familycal.events` | read | household |
| 3a | nursery climate bridge | `climate.reading.report` (scoped), `climate.current/history/summary` | act (scoped push) / read | household |
| 3b | per-host facts | `hostfacts.report` (scoped), `hostfacts.current/history` | act (scoped push) / read | personal (matches `ward.status`) |
| 4 | Miniflux | `miniflux.feeds/entries/counters` | read | household, or personal (section 6) |
| 5 | notes/docs | `notes.search/get/list` | read | household, with a personal/intimate hard edge |

#### 1. People and contacts

hob already owns a native relationship module (PEOPLE.md): `Person` rows with `display_name`,
`handles`, `circles`, `key_dates` (`app/models/person.rb`), built almost entirely by *deriving*
identity from message traffic — a person is "named as the Mac's Contacts name them" the first
time a text arrives (PEOPLE.md, "Where events come from"). There is no canonical contact-card
source: no address, company, photo, or notes field, and no app whose job is "who someone really
is" rather than "who texted whom." A CardDAV contacts app (iCloud, Nextcloud, a self-hosted
address book) is the real gap.

- **Capabilities.** `contacts.card.get` (read, one card by handle or the app's own id),
  `contacts.card.search` (read, by name or handle), `contacts.changes` (read, a cursor like
  `Records.changes`, so hob polls only what moved). All read — no write-back to the address book
  proposed for v1.
- **Realm.** A shared family address book registers `household`. Section 6's personal-scoping
  extension is what this case actually needs in practice: Jenner's own iCloud contacts and the
  household's shared book are two registrations of the same plugin, exactly the way
  `jenner-fastmail` and `house-fastmail` are two `calendar_backends` rows on one account
  (CALENDARS.md). Realm is set from the manifest once, then left alone, per section 6 — a contacts
  app's manifest claiming `household` when the household wants `personal` is the bootstrap step's
  job to catch, not an automatic one.
- **Policy before use.**
  ```sh
  bin/rails "hob:sentinel:policy[muse,contacts.card.get,allow]"
  bin/rails "hob:sentinel:policy[muse,contacts.card.search,allow]" LIMITS='{"per_hour":60}'
  bin/rails "hob:sentinel:policy[muse,contacts.changes,allow]"
  ```
  No `requires_person` floor needed — these are reads, and nothing here writes into `people_events`
  or `people_notes`.
- **Discovery and versioning.** Standard: bootstrap registration, then scheduled refresh (section
  1) picks up new manifest fields (an address, say) as an additive schema change (section 7).
- **If it goes down or misbehaves.** hob's own People module — open loops, event history, cadence
  — is untouched; it never reads from this plugin, so losing it only loses the richer card detail,
  never the Rolodex. A card that lies about whose number a handle is is just data: PEOPLE.md already
  treats a sender's Contacts name as "data, not instructions," and the same notice applies here. A
  consistently wrong card trips the circuit breaker (section 8) as a trust signal, same as anywhere
  else.
- **Hard edge — the one case with a hob-native twin.** Every other test case below describes data
  hob has nowhere else; this one does not. Miniflux entries, climate readings, and notes don't
  collide with an existing native store; a CardDAV card describes the *same person* `people.get`
  already has an opinion about, under a different name (`contacts.*` vs. `people.*`), with no
  reconciliation between them. Section 9 says the native/forge path for first-party data "stays
  native... not a replacement," which settles that a plugin should never write into `people_events`
  directly — but it does not say what an agent is supposed to do when `contacts.card.get` and
  `people.get` disagree about the same handle. PEOPLE.md's own rule — "identity is a person's call,"
  merges are `requires_person`, "a merge does not rewrite the log" — argues a plugin-sourced card
  should never auto-merge into a `Person` row, only sit beside it under its own name. **Open question
  for Jenner, not a design change**: should a plugin like this ever be allowed to *propose* a
  `people.merge` (the existing `requires_person` capability, same as an agent proposing one today),
  or should `contacts.*` stay a permanently separate, unreconciled namespace?

#### 2. A unified family calendar and presence layer

CALENDARS.md's own capabilities are read-only per-backend merges (`calendar.calendars`,
`calendar.events`); its open question 4 names exactly this gap ("when are Jenner and Tessa both
free on Saturday... one function over what is already here"), and `calendar_push.rb`'s comment
is more direct still: there is no availability query across people at all today, by design, left
for a later decision. "Presence" — who is actually home right now — doesn't exist in hob in any
form.

- **Capabilities.** `presence.current` (read, coarse home/away per household member),
  `presence.history` (read, recent transitions), `familycal.events` (read, a family-organizer
  app's own events, if the household runs one outside its existing `calendar_backends`).
- **Realm.** Household — the point of a presence layer is shared visibility, the opposite of
  personal. But precise presence (exact GPS) is more sensitive than coarse home/away the way a
  calendar's contents are more sensitive than its free/busy shape; CALENDARS.md's
  `visibility: free_busy` masking ("hands out when, and whether busy, and nothing that says what")
  is the right model to copy — a presence plugin should expose coarse state only, never a location
  trace, as a manifest-level design choice, not a policy one.
- **Policy before use.**
  ```sh
  bin/rails "hob:sentinel:policy[skipsy,presence.current,allow]"
  bin/rails "hob:sentinel:policy[skipsy,presence.history,allow]" LIMITS='{"per_hour":60}'
  bin/rails "hob:sentinel:policy[skipsy,familycal.events,allow]"
  ```
- **Discovery and versioning.** Standard; little expected schema churn (presence states are a
  small enum).
- **If it goes down or misbehaves.** The native calendar reads (CALENDARS.md) are completely
  unaffected — this plugin is a separate source, not a wrapper over `calendar_backends`, so losing
  it loses presence, not the calendar. Wrong presence data is read the way a wrong calendar event
  title is: "anyone who can send an invitation can write one" (CALENDARS.md) applies equally to
  "anyone whose phone can lie about where it is."
- **Hard edge — a plugin that would need to read hob, not just supply hob.** "Unified calendar and
  presence" most naturally means *merging* the presence signal with the household's existing
  CalDAV calendars (`calendar.events`) into one availability answer — but section 4's structural
  rule is that "a plugin key reaches only plugin-management endpoints... never the sentinel," the
  same wall the sentinel already holds between an agent and another agent's data, one level over.
  A plugin cannot call `calendar.events` to compute availability itself. This is a genuine gap this
  test case is the first to expose, not just an open question dressed as one: **the design needs a
  decision**, either (a) merging calendars and presence into one availability view is native work —
  finally building `calendar.free_busy` per CALENDARS.md's own open question 4, with the presence
  plugin only supplying the presence half for that native code to combine — or (b) the plugin model
  grows a second, narrower principal shape that can call *into* the sentinel as a read-only caller
  under its own policy rows, which is a materially different trust posture than section 4 describes
  today and would need its own section. Recommend (a): it keeps section 4's "never the sentinel"
  rule intact and matches section 9's "hob core must still own" first-party data — but it is a real
  decision, not a someday question, since "family calendar and presence" was the test case asked
  for and (a) is not what a literal reading of it produces on its own.

#### 3. Read-only home and host facts, with no execution grant

Two sources, same shape, chosen because WARD.md already refuses host execution on principle — the
ward "does not scan from where hob runs," it scans from outside, and its only two live
capabilities today are a status read and a TCP connect check with a literal, pre-registered host
list (`HOB_WARD_SCAN_TARGETS`), never a shell. Neither sensor exists as a capability anywhere
today: the nursery climate sensor is CLIMATE.md's own drafted, unbuilt proposal, whose only
present-day path into hob is the shoehorn its "Interim path" section names and dislikes
("Collection `nursery-climate`... worth it for the first weeks... not a substitute for building
this"). Per-host distro facts are a gap even inside what ward already has: ward reads a server's
*kernel version* through Coolify's read-only API today (`app/services/ward/inventory.rb:10-23`),
but Coolify's API carries nothing about the distro name, uptime, or package state beyond the
patches check it already runs — there is no path to a host's own OS facts other than asking the
host, which is exactly what a host-local push avoids having to do over exec.

- **Capabilities.**
  - `climate.reading.report` (act, but a passive data push, never a command) — scoped to the
    bridge's own registered sensors, exactly CLIMATE.md's own proposed shape. `climate.current`,
    `climate.history`, `climate.summary` (read) for household agents.
  - `hostfacts.report` (act, same passive-push shape) — scoped to the one host principal reporting
    it; rejects facts for any host not its own, mirroring `climate.reading.report`'s "rejects
    sensors not registered to that bridge." `hostfacts.current`, `hostfacts.history` (read).
  - Neither plugin offers anything named `*.exec`, `*.run`, or `*.shell`. There is no capability in
    this test case that lets a caller ask a host to *do* something — only ever to say what it
    already is. **This is the explicit point of the test case**: the direction of every call is
    host → hob (a push), never hob → host (a pull that could become a command), the same
    "hob never reaches into the house; the house reports out" rule CLIMATE.md states for the
    climate bridge, extended to host facts.
- **Realm.** Climate: household — both partners' agents see the same rooms, per CLIMATE.md. Host
  facts: `personal`, matching `ward.status`'s own reasoning — "an agent that can ask `ward.status`
  learns the household's exposure. That is sensitive" (WARD.md). A host's kernel and distro state
  is the same class of exposure information, so it sits at the same floor, with no policy granting
  it by default.
- **Policy before use.**
  ```sh
  bin/rails "hob:sentinel:policy[climate-bridge,climate.reading.report,allow]"
  bin/rails "hob:sentinel:policy[skipsy,climate.current,allow]"
  bin/rails "hob:sentinel:policy[cadance-hostfacts,hostfacts.report,allow]" CONSTRAINTS='{"host":["cadance"]}'
  bin/rails "hob:sentinel:policy[ward,hostfacts.current,allow]"
  ```
  One reporting principal (and one constrained policy row) per host, the same granularity
  `climate-bridge` gets per sensor — a facts collector that could report "for any host" would be a
  bigger grant than the single-host collector this case is built around.
- **Discovery and versioning.** Standard manifest refresh; little expected churn, since kernel,
  distro, and uptime are a stable fact shape.
- **If it goes down or misbehaves.** A dead collector makes that host's (or that sensor's) facts
  stale, the same "a scanner that stopped must not look like a clean house" treatment WARD.md
  already gives a missed audit run — it does not touch ward's existing exposure/patches checks,
  which come from a different worker (`security/ward.py`) reading Coolify directly. A lying
  collector — a host claiming a patched kernel it doesn't have — can only misstate facts about
  itself; because no execution capability exists anywhere in this path, there is nothing a
  compromised reporter can *do*, only something it can say, and a mismatch against Coolify's own
  patches check (WARD.md) is exactly the kind of `sensor_disagreement` signal CLIMATE.md already
  uses for the Nanit-vs-W100 delta, available here for free.
- **Hard edge.** This case validates the design cleanly rather than breaking it — CLIMATE.md
  independently arrived at the plugin venue's own shape (a scoped principal, a push-only write, a
  read side for everyone else) before this platform existed to offer it, and its "Interim path"
  section is a worse version of exactly this plugin, built because nothing better existed. The one
  real gap: section 2's schema distinguishes `read` from `act` to decide retry safety (section 8),
  but nothing distinguishes a *passive* act like `hostfacts.report` from an act that could plausibly
  mean "run this on a host" — both would be declared `kind: act` in the same manifest field, and
  nothing at the schema level stops a future plugin from proposing an exec-shaped capability; only
  policy (no default allow, a person's rule, realm) stands between a manifest and a request. Given
  how central "ward watches, it does not act" is to the household's threat model (WARD.md), this is
  worth an **open question for Jenner**: does a plugin manifest need a schema-level marker
  (something like `grants_execution: false`, checked at registration, refusing to even create the
  row without an explicit opt-in) rather than relying on policy alone to keep an exec-shaped
  capability out — or is "no policy grants it by default" (as already holds for every capability)
  already sufficient because no human would write the `allow` rule?

#### 4. Miniflux feed reads

Already this design's own first-adopter pick (section 10): "a clean first adopter of the
genuinely new parts of this platform." This case makes it concrete rather than hypothetical.

- **Capabilities.** `miniflux.feeds` (read, subscribed feeds), `miniflux.entries` (read, entries
  filterable by feed/status/date — the exact shape section 1's own manifest example used),
  `miniflux.counters` (read, Miniflux's own unread/read counts per feed, for a cheap check that
  doesn't pull entry bodies).
- **Realm.** Household by default; section 6's personal-scoping extension applies the same way it
  does for contacts and calendars if the household ever runs one shared Miniflux instance and one
  person's own.
- **Policy before use.**
  ```sh
  bin/rails "hob:sentinel:policy[muse,miniflux.feeds,allow]"
  bin/rails "hob:sentinel:policy[muse,miniflux.entries,allow]" LIMITS='{"per_hour":60}'
  bin/rails "hob:sentinel:policy[muse,miniflux.counters,allow]"
  ```
  Default-allow-with-limits, no `requires_person` — section 11 already argues this case is "a good
  exercise of 'default allow with limits' policy without much downside if the review is wrong."
- **Discovery and versioning.** The cleanest exercise of section 7 among all five cases: Miniflux's
  own REST API is stable, but a first-party bridge wrapping it (section 10's first option) is
  household code that will grow fields over time, making this the real test of the
  additive-with-grace-period schema evolution sections 2 and 12 propose, rather than a one-time
  migration like mise's.
- **If it goes down or misbehaves.** Reads fail `unavailable` (section 2's error enum); the breaker
  (section 8) trips on repeated timeouts; nothing else in hob depends on feed data, so nothing else
  degrades. A mismatched `output_schema` is caught before storage (section 2); entry content is
  data, never instruction, the same notice calendar and mail content already carry.
- **Hard edge.** Already named, not newly discovered: section 10's second bullet and open question
  5 both flag that Miniflux could instead arrive through the planned MCP-bridge venue if a
  community MCP server for it exists. Picking Miniflux as the literal first plugin — rather than a
  hypothetical one — means open question 5 has to be answered *before* Phase 4 actually ships, not
  "worth settling in principle" on its own schedule: if a Miniflux MCP server gets used instead of
  the first-party bridge, sections 2 and 4 were validated against the wrong venue. No design change
  from this case; it sharpens the existing open question's urgency and ties it to a concrete
  decision point instead of a someday one.

#### 5. Notes and docs reads

RECORDS.md is explicit that it is not this: "Records are not memory either... a record is a
document written for lookup," and its collections are schema'd structured evidence (an Amazon
order), not freeform prose. PEOPLE.md's notes are relationship-scoped only. Nothing in hob reads a
household's actual running notes or documents today — a self-hosted wiki or notes app (Joplin, an
Obsidian sync server, Nextcloud Notes) is a genuine gap with no existing proposal to lean on,
unlike the other four cases.

- **Capabilities.** `notes.search` (read, keyword search over titles and bodies), `notes.get`
  (read, one note or document's content by id), `notes.list` (read, recently updated first). No
  `act` in v1 — no "edit the household wiki," matching the read-first posture every other new
  integration in this document starts from.
- **Realm.** Household for a shared family wiki is the easy case. The hard one: a personal notes
  app (a private journal, therapy notes) is exactly the kind of source likely to contain
  `intimate`-realm material by its nature, more than any other case here — Miniflux's worst leak is
  reading habits, climate's is a nursery temperature, this one's is a diary. Section 6's rule that
  the household's own realm tuning "always wins... left alone on updates" is necessary but not
  sufficient: if a personal vault's manifest claims `household` — through a bug, or because the
  app's manifest template has no idea hob's realm vocabulary exists — nothing auto-detects that the
  content looks intimate. The bootstrap step (a person running the registration command, section 1)
  is the only backstop, same as it is everywhere else, but the cost of it being wrong is higher
  here than in any other case in this document.
- **Policy before use.**
  ```sh
  bin/rails "hob:sentinel:policy[muse,notes.search,allow]" LIMITS='{"per_hour":60}'
  bin/rails "hob:sentinel:policy[muse,notes.get,allow]"
  bin/rails "hob:sentinel:policy[jenners-notes-reader,notes.*,review]"
  ```
  Given the sensitivity, a household may reasonably choose `review` over blanket `allow` for any
  agent reaching a personal-realm notes plugin even though every capability is a read — WARD.md
  already establishes that "read-only" and "low-stakes" are not the same thing (`ward.status` is
  read-only and still sits behind a person's rule by default). This is a policy choice this design
  leaves to the household, not something it forces.
- **Discovery and versioning.** Standard; little schema churn expected (titles, bodies, a search
  result shape).
- **If it goes down or misbehaves.** Nothing else in hob depends on it, same isolation as every
  other case. A misbehaving case here is sharper than the others: if the notes app's own
  per-person access control has a bug and a household-realm search returns another person's
  private note, hob has no way to detect that from its own side — it trusts the plugin's own
  backend the same way it trusts mise's today ("not cryptographic isolation... a plugin the
  household chose to trust is the same bet," section 4).
- **Hard edge — a finer grain than hob's realm can see.** Every other case in this document is
  either about one undifferentiated dataset per realm (Miniflux, calendar, climate, host facts) or
  about one plugin's own self-reported facts. A household notes app is the first case where, inside
  one `household`-realm registration, the plugin's own backend plausibly has its own finer-grained
  per-person access control (my notebook, your notebook, both nominally household) that hob's
  capability-level `realm` has no way to see or express — hob's realm gates the whole capability
  row, the same grain Records' per-collection realm uses, not a grain inside one plugin's answer.
  **Open question for Jenner**: should a plugin request ever carry the calling principal's identity
  through to the plugin itself, so a notes app could enforce its own per-person ACL against a
  stable "who's asking" hob attests to — or does a household register one plugin per person for
  anything with per-person access control, the same workaround CALENDARS.md already uses today
  (`jenner-fastmail` vs. `house-fastmail`, two rows on one account)? Nothing here argues for a
  design change on its own; it is a real, newly-surfaced question this case is the first to raise.

### 14. Open questions for Jenner

1. **Scope of "apps."** Does "apps expose capabilities themselves" mean household-run apps only
   (mise-shaped: Jenner's own code, Coolify-hosted), or genuinely third-party software the
   household doesn't operate (a feed reader, a bank, a smart-lock vendor)? **Decision needed:** how
   strong the identity/trust model in section 4 has to be on day one — TOFU-over-HTTPS is fine for
   the former, not for the latter. This determines almost everything else in the trust section.
2. **Silent vs. loud new capabilities.** Should a brand-new plugin capability stay `enabled: true`
   with no policy row by default (today's behavior — safe because "no rule means no," but mute
   until someone tries it), or `enabled: false` until a person flips it on? **Decision needed:**
   whether automatic discovery means "available but denied until policied" or "not available at
   all until approved" — changes how loud section 5's notification needs to be, and whether it's
   enough on its own.
3. **Who may register a plugin.** Only Jenner (today's model — registration needs someone running
   a rake task), or should Tessa be able to register her own personal plugin without a terminal?
   **Decision needed:** whether an admin-UI registration flow is a v1 requirement or can wait, and
   whether "personal" realm-scoped plugins (section 6) matter before that UI exists.
4. **Manifest contract strictness.** Is the `output_schema`/error-taxonomy addition (section 2) a
   hard requirement from day one, or a soft migration with a grace period (as phased)?
   **Decision needed:** whether mise's own `docs/HOB.md` contract and code need to change before
   Phase 1 ships, since mise is the only existing consumer today.
5. **One mechanism or two with MCP.** Should this plugin platform grow into `DESIGN.md`'s planned
   MCP-bridge venue, or stay deliberately separate (plugin manifests for anything the household's
   policy model should govern tightly; MCP for lower-stakes, mostly-read pulls from the wider
   ecosystem)? **Decision needed** before Phase 5, but worth settling in principle now, since it
   affects whether section 2's schema should be designed as a strict superset of MCP's
   `tools/list` shape from the start.
6. **How much plugin health Jenner wants to see.** Does failure isolation (section 8) need its own
   `/admin` surface (plugin health, breaker state, recent failures), or is existing logging
   (`Rails.error.report`, the sentinel request log) enough? **Decision needed:** how much of
   Phase 3 is backend-only versus UI work.
