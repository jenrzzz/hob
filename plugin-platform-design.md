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

### 13. Open questions for Jenner

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
