# A plugin platform for hob

*Feasibility and design investigation. **Phase 0 (section 12) is implemented**, and Phase 1 is
under way (its first part, installations and quarantine, is in); the rest of Phase 1 and Phases 2–5
are still proposals. Part 1 describes the code as it was before Phase 0; SENTINEL.md (*Capabilities*)
describes it as it is now.*

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

Three details of this path matter for what follows:

- **Every run rotates the secret and restarts the app.** `SurfaceCapabilities#call` mints a new
  secret, pushes it through Coolify, and restarts the surface *before* the capability rows are
  updated, so for a moment deliveries are signed with a secret the surface no longer holds. That's
  fine for a rare, by-hand run, and wrong for anything that runs on a schedule.
- **The only name check is the prefix.** An entry must start with `<surface>.`, and an existing
  native row can't be taken over. But nothing reserves a native *namespace*: a surface registered
  as `mail` or `hob` could add `mail.new_thing` or `hob.new_thing` next to the native ones.
- **The manifest's realm isn't checked when the manifest is read.** `validate!` checks name,
  description, kind, and input schema. An unknown realm only fails at `save!`, partway through
  the transaction.

Each delivery already tells the surface who is asking: the signed body carries `agent` (the
calling principal's name), `realm` (the request's clearance), `reason`, `decided_by`, and the
mission id.

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
already the right shape for a plugin platform.

Two parts of policy resolution reach capabilities that don't exist yet, and both matter once
capabilities can appear without a person in the loop:

- **Wildcard rules match new names.** A rule's `capability` can be `*` or a glob
  (`SentinelPolicy#matches?`), and SENTINEL.md's own setup gives muse `hob:sentinel:policy[muse,*,review]`.
  A capability that appears tomorrow is reachable by muse tomorrow, judged only by the reviewer.
  "No rule means deny" is true only for an agent with no wildcard rule.
- **A new capability fulfils petitions waiting on its name.** `Capability#after_create` calls
  `Petition.fulfil!`, which writes a rule with the petition's effect (which can be `allow`) for
  every petition in `proposed` or `building` with that capability name. Today the only things that
  create rows are a merged forge PR and a person's `hob:surface:register` run, so a person has always
  looked at the capability before the grant takes effect.

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
implementation — into a first-class `plugin` venue. The gate's decision logic, the policy model,
realms, and the audit log stay as they are. Three small additions are needed where they meet a
capability nobody has looked at yet (sections 4 and 5). Nothing here replaces native capabilities for hob's own
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

That reuse needs `SurfaceCapabilities` split in two first. **Refresh** fetches and reconciles the
manifest and never touches the secret. **Rotate** mints and pushes a new secret and restarts the
app, and runs only at bootstrap or when a person asks. As it stands, every call rotates and
restarts (Part 1), so a scheduled refresh would restart the plugin on every poll. Rotation must use an overlap: install the new verification key at the plugin while it still
accepts the old key, confirm readiness, switch hob to signing with the new key, and retire the old
key after the delivery window expires. Merely reversing the write/restart order moves the mismatch
window rather than eliminating it. A failed cutover retains the last working key.

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

Two checks move earlier, into manifest validation, so a bad entry is refused before anything is
written:

- **Realm.** A manifest `realm` must be a known realm (`Realm.rank_of`), checked in `validate!`
  rather than left to fail at `save!` partway through the transaction.
- **Reserved namespaces.** A plugin's name may not be the prefix of any native capability (`hob`,
  `mail`, `calendar`, `todo`, `budget`, `records`, `ward`, `people`, `browse`, `http`, …), derived
  from `Sentinel::Native::HANDLERS` at registration time rather than kept as a hand-written list.
  Today the only protection is that an existing native row can't be overwritten; nothing stops a
  plugin registered as `mail` from adding new names under `mail.`.

### 3. Discovery without hob changes

Discovery already happens in two complementary ways once a plugin is bootstrapped, and this
proposal keeps both:

- **Catalog growth:** the scheduled refresh (section 1) means a plugin adding, changing, or
  retiring a capability in its manifest shows up in hob's `capabilities` table without anyone
  touching hob's own code or deploying it — the thing Jenner is asking for, achieved by turning
  `SurfaceCapabilities`'s existing manual trigger into a scheduled + self-service one. A new
  capability arrives unaccepted (section 5): no hob change is needed, but a person still has to say
  yes before anyone can use it.
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

- Every plugin installation gets its own `Principal`, using the **`surface` kind that already exists**
  (`Principal::KINDS` is `human persona worker surface agent`; `trusted?` already treats surfaces
  as untrusted to decide requests or manage policy). There's no need for a new `plugin` kind. The
  principal carries an **inbound key** (verifies the plugin's self-announce pings are really from
  it) and an **outbound signing secret** (hob → plugin, same HMAC scheme and rotation
  `SurfaceCapabilities` already implements). Capability rows point at their plugin by principal id
  instead of the free-text `config.surface` they use today.
- **Authenticate the manifest itself.** An authenticated notification only authorizes a refresh;
  it does not authenticate the subsequent HTTP response. Bootstrap establishes a separate
  manifest-verification credential. Over HTTPS, the plugin signs the exact manifest body together
  with its installation id, a monotonic revision, and a hob-supplied refresh nonce. Hob verifies
  these before reconciliation and rejects replayed or conflicting revisions. Serialize reconciliation
  per installation so an older fetch cannot overwrite newer state. Credential changes require an
  authenticated rotation or human bootstrap, never a declaration in the fetched manifest. This
  protects against origin takeover without the credential; compromise of the plugin and its keys
  remains outside that guarantee. Existing unsigned integrations retain explicit HTTPS-origin
  trust until migrated and must not enter automatic discovery.
- A plugin key reaches **only** plugin-management endpoints (manifest push/self-announce) — never
  the sentinel, never a conversation, never another plugin's data. This is the same structural
  rule the sentinel already holds for agents ("an agent key reaches only the sentinel and the
  mission queue") applied one level over. It also means a plugin can't hold policy rules at all:
  `SentinelPolicy#principal_is_agent` refuses a rule for any principal that isn't an agent. Software
  that needs to *call* the sentinel (to push readings, say) is an agent, not a plugin, even if the
  same app also serves a plugin manifest (section 13.3).
- **Containment of a compromised or misbehaving plugin** borrows the shape of the existing agent
  freeze (`principals.capabilities_frozen_at`/`_reason`) but needs one new check, not just reuse.
  Today `Sentinel::Gate` checks `capabilities_frozen?` on the *calling agent*. Quarantining a
  plugin means denying requests *to* its capabilities, whoever calls: a new gate step that follows
  capability → plugin principal → frozen. It's a few lines, and it gives one switch that denies
  every capability the plugin offers instead of a person disabling rows one at a time.
- **Who is asking is already in every delivery.** The signed webhook body carries `agent` and
  `realm` (Part 1), so a plugin can already tell which agent is calling and at what clearance. What
  isn't decided is whether a plugin may *rely* on that for its own access control (section 13.5).
- What this does **not** need to be: cryptographic attestation of the plugin's code. hob's own
  stated non-goal is "a trusted service, not cryptographic isolation between realms"; a plugin the
  household chose to trust is the same bet, one level out.

### 5. Sentinel policy and per-capability approval

No change to how rules are written or resolved. A plugin's capabilities are rows with
`venue: plugin`; `SentinelPolicy.resolve` doesn't care what venue a capability has. A household
still writes (or a steward still grants, via the existing petition flow)
`allow`/`review`/`confirm`/`deny` rows exactly as for mise today, and `requires_person` remains a
floor no rule can get past, whoever wrote the capability.

What does change is what a capability that **no person has looked at yet** can do. Part 1 shows
that "no rule, so denied" doesn't hold for one: a wildcard rule like muse's `*` covers it the
moment it exists, and its creation can fulfil a waiting petition with an `allow` grant. Once
plugins can add capabilities on their own, that can't be left as it is. So:

- **A new plugin capability lands `enabled: false`, marked unaccepted.** On refresh it's created
  with `accepted_at: nil` and isn't offered or executable until a person accepts it, at which point
  its proposed realm and kind are confirmed or changed (section 6). This settles open question 2.
- **Wildcards don't reach an unaccepted capability, and petitions don't fire on it.** Accepting is
  the moment a person has looked, so `Petition.fulfil!` runs on acceptance rather than in
  `after_create` for plugin-venue rows. Native rows (a merged forge PR) and by-hand registration
  keep today's behavior, since a person already looked.
- **And it's loud.** Pipe the refresh's `created` count into the same `Notify.person` hook the
  steward and petitions already use ("mise offers a new capability, `mise.pantry.scan`; nobody can
  use it until you accept it"), so automatic discovery doesn't mean the person who decides never
  hears about it.

### 6. Realm handling for personal versus household capabilities

Keep the existing rule that a capability's `realm` is set from the manifest once, then **left
alone** on updates — a household's own tuning always wins over what the app claims about itself,
exactly as today.

Under scheduled refresh, "set once from the manifest" would mean that for every capability after
the first sync, the plugin alone picks the realm. Bootstrap only covers what the plugin offered on
day one. Acceptance (section 5) closes that gap: the manifest realm is a *proposal*, shown to the
person when they accept the capability, and it takes effect only once they've confirmed or
changed it.

New: distinguish a **plugin type** (such as contacts) from a **plugin installation** (the
household address book or Jenner's private address book). Each installation has its own surface
principal, credentials, endpoint, optional human owner, and immutable namespace. Capabilities
belong to that installation; refresh may never take over a row owned by another installation.

Keep globally unique capability names by assigning an installation namespace at bootstrap:
`contacts-house.card.get` and `contacts-jenner.card.get`, for example. The manifest declares local
operation names, which hob maps into that namespace; legacy mise names retain the `mise`
namespace. Store the remote operation separately so local naming does not dictate the wire route.

For personal installations, require both adequate realm clearance **and** authorization to act
for the installation's owner. Higher clearance alone never grants another person's data. Hob must
derive that owner authorization from trusted request context or explicit delegation, not from a
plugin claim or an agent-supplied owner argument, and enforce it in discovery and execution.
Until that delegation model exists, personal installations must remain unavailable to agents.
Acceptance confirms the owner as well as realm and kind.

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

- **A version is part of the name.** `Capability#name` is unique and every policy rule matches
  by name, so two versions can't share one. A breaking change gets a new name with a version
  suffix (`feedreader.entries` → `feedreader.entries.v2`), and both rows coexist for as long as the
  manifest lists both. The suffixed name is a new capability: it goes through acceptance (section
  5), and exact-name rules are not copied, because constraints written for v1's arguments may
  not mean the same thing for v2's. Existing wildcard rules still match the new name after
  acceptance; the acceptance view must show those effective grants and constraints. The manifest's `version` field records which
  version an entry is; it doesn't change the name.
- **On sync, hob diffs the schema of each name it already has** and **refuses that one entry**
  (not the whole plugin) when the change would break existing callers or rules: for
  `input_schema`, a field that becomes required, a removed field, a changed type, or a narrowed
  enum; for `output_schema`, a removed field or a changed type. Loosening changes (a new optional
  input, a new output field, a required input becoming optional) go through. A refused entry retains its old contract for audit but is suspended immediately and the
  person is notified: keeping the old schema in hob cannot make a changed remote endpoint obey it.
  The plugin must publish the new shape under a new versioned name. Continuing to execute the old
  version requires a separately bound endpoint that still serves its accepted contract and explicit
  verification before resuming. Check suspension and the accepted contract revision again at
  dispatch, including requests approved before refresh. Schema compatibility is not proof of
  unchanged semantics; changes to declared kind, realm, or routing also require renewed review.
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
- **An authenticated delivery whose output violates `output_schema` counts against the breaker.**
  Repeated attributable contract violations may trigger quarantine (section 4). Invalid signatures
  on self-announce pings are rejected, logged, and rate-limited separately; they must never count
  against a claimed plugin's health or quarantine threshold, since anyone can forge a bad ping. Whether a well-formed answer is
  *true* isn't something hob can check from its side, and this design doesn't pretend it can.
- **Bound shared execution resources.** Webhook execution currently holds a hob worker inline.
  A breaker cannot prevent concurrent slow requests from exhausting those workers before it trips.
  Enforce per-installation in-flight limits with bounded admission (fail fast when full), an aggregate
  plugin concurrency budget that leaves capacity for native work, maximum response bytes before
  parsing, and a total execution deadline covering connection, body reads, and retries. Use an
  isolated bounded delivery queue if these limits cannot preserve capacity in the inline path.
  Remote process isolation remains the plugin operator's responsibility.

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
  because any bootstrapped plugin can mint new capability names on its own schedule now. Acceptance
  plus its notification (section 5) is what keeps that safe. Without acceptance, wildcard rules
  and waiting petitions would grant new capabilities with nobody looking. Without the
  notification, accepting becomes a chore: someone has to check every sync, or new capabilities
  sit unaccepted, safe but useless.
- **Reversibility.** Removing a native capability needs a second PR; removing a plugin capability
  is the plugin's own manifest change or a person's quarantine action — easier to add safely, but
  also easier for a compromised plugin to change its own surface without the PR-review checkpoint
  that gates every new hob capability today.

### 12. A phased rollout that keeps existing integrations working

- **Phase 0 — naming and guard rails. Done.** `SurfaceCapabilities#register`/`#refresh`/`#rotate`
  (`hob:surface:register`, `:refresh`, `:rotate`); rotation overlaps by signing with both secrets
  for an hour, which an updated `Hob::Webhook.verify` (gem 0.3.1) accepts and an older one sees as
  today's behavior. Readiness is not confirmed, since the plugin has no endpoint to confirm it
  through until Phase 1. Acceptance is `capabilities.accepted_at`/`accepted_by`,
  `Capability#accept!`, `hob:capabilities:unaccepted`/`:accept`, and `POST
  /v1/sentinel/capabilities/:name/accept`. There is no admin page for it yet (open question 3).
  Document mise's existing webhook registration as "the
  plugin venue, v0." Split `SurfaceCapabilities` into refresh and rotate (section 1). Validate realm
  and reserve native namespaces at manifest time (section 2). Add acceptance: new rows land
  unaccepted, wildcards and petitions don't reach them until a person accepts, and the person is
  notified (section 5). None of this changes the trust model or the manifest shape, and nothing in
  mise's own code needs to move. It has to come first because every later phase creates
  capabilities with no person running the command.
- **Phase 1 — plugin identity.** Give each plugin a `Principal(kind: surface)`, add the inbound
  key, authenticated manifest responses, the self-announce endpoint, and the quarantine gate check
  (section 4). Establish installation namespaces and ownership checks (section 6). Add versioned
  contracts and suspension on incompatible refresh (section 7), plus bounded delivery resources
  (section 8), before enabling automatic discovery. Migrate mise first,
  since it's already in production and the bootstrap step (a person running a one-time command)
  doesn't get harder. This comes *before* scheduled discovery: polling a manifest URL whose only
  trust is "whoever answered when a person last ran the rake task" lets anyone who takes over that
  URL (DNS, an expired domain, a hijacked deploy) add capabilities with nobody watching.

  **Phase 1a — installations and quarantine. Done.** A `plugins` table: one row per installation,
  with its `Principal(kind: surface)` (named `plugin:<namespace>`), an immutable `namespace`,
  `plugin_type`, `base_url`, and an optional human `owner`. `capabilities.plugin_id` replaces
  `config.surface` as what a row belongs to (the config key stays, unread, for now); the migration
  makes an owner-less installation for every surface already registered. Ownership is checked by
  installation, so refresh can't take a row another installation, or a person by hand, put
  there. Quarantine (`Plugin#quarantine!`, `hob:surface:quarantine`/`:release`) freezes the
  installation's principal; `Capability#unavailable_to(caller)` is then checked at the gate (a
  new `decided_by: plugin`), again in `Sentinel::Webhook.deliver` (so it covers requests approved
  before the quarantine and a person's own MCP calls), and in SQL in every listing
  (`Capability.offered_to`). A quarantined installation is not refreshed. A personal installation
  (`OWNER=` at first registration) reaches only its owner. Until delegation exists, no agent can
  use it, which is the interim rule from section 6. Acceptance views now show the owner.

  Still to do in Phase 1, roughly in this order. 1b: the inbound key, signed manifests, the
  self-announce endpoint, and rotation readiness (needs the gem and mise). 1c: per-installation
  namespaces distinct from the plugin type, with local operation names mapped into them. 1d:
  versioned contracts and suspension on an incompatible refresh. 1e: bounded delivery resources.
- **Phase 2 — scheduled discovery.** Add `PluginRefreshJob` (Solid Queue, reusing the `schedules`
  machinery) alongside the existing manual rake task, running refresh only, never rotate. Add
  `output_schema`/`errors` to the manifest shape, accepted but optional during a grace period so
  mise's current manifest keeps working unmodified.
- **Phase 3 — health tracking and the breaker.** Add the per-plugin circuit breaker and health
  tracking on top of Phase 1's execution bounds and contract guards — exercised first
  against mise, since it's low-risk to iterate on a plugin already in daily use.
- **Phase 4 — a genuinely external plugin.** The feed-reader bridge (or equivalent), as the proving
  ground for identity/trust against software the household didn't write, and for personal- (not
  just household-) scoped realm handling.
- **Phase 5 — reconcile with the planned MCP bridge.** Decide whether `DESIGN.md`'s Plane 4 MCP
  venue and this plugin venue are one mechanism or two, now that there's a real external plugin to
  compare against.

At every phase, mail/calendar/todo/budget/records/ward/people stay native and unmodified, and
mise's delivery format remains compatible. Authenticated manifest refresh requires a coordinated
upgrade before automatic discovery; manual registration remains available during migration.

### 13. Test cases against real capability gaps

Jenner's call: test the design against five real gaps in what hob can do today rather than keep
refining it in the abstract. Some of the gaps are already named in the repo: `calendar_push.rb`
leaves availability queries for "a separate capability and a separate decision"
(`app/services/sentinel/native/calendar_push.rb:11-12`), and CLIMATE.md is a drafted, unbuilt
proposal with an interim workaround through `records.*`. Contacts and notes have no existing
proposal. One of the five (3, climate and host facts) turns out not to be a plugin at all, and
working out why is the most useful result of the exercise.

| # | app | capabilities | fits the plugin venue? |
|---|---|---|---|
| 1 | contacts (CardDAV) | `contacts.card.get/search`, `contacts.changes` | yes |
| 2 | family calendar + presence | `presence.current/history`, `familycal.events` | partly: presence yes, availability no |
| 3 | nursery climate, host facts | `climate.reading.report`, `hostfacts.report` + reads | no: native ingest, like `hob.calendar.push` |
| 4 | Miniflux | `miniflux.feeds/entries/counters` | yes; the planned first adopter |
| 5 | notes/docs | `notes.search/get/list` | yes, with a realm caveat |

The policy examples below are for agents (muse, skipsy, ward). Plugins never hold rules
(section 4). Every capability goes through acceptance (section 5) before any rule, wildcards
included, reaches it.

#### 1. People and contacts

hob's People module (PEOPLE.md) builds `Person` rows by deriving identity from message traffic;
there is no canonical card (address, company, notes). A CardDAV address book fills that gap.

- **Capabilities.** `contacts.card.get`, `contacts.card.search`, `contacts.changes` (a cursor,
  like `Records.changes`). All `read`; no write-back in v1.
- **Realm and policy.** A shared address book is `household`; one person's own iCloud contacts is
  a second, `personal` registration of the same plugin, the way `jenner-fastmail` and
  `house-fastmail` are two `calendar_backends` rows (CALENDARS.md). Agent rules are plain `allow`,
  with a `per_hour` limit on search.
- **Failure.** People is untouched: it never reads from this plugin. Card contents are data, not
  instructions, as PEOPLE.md already treats a sender's Contacts name.
- **What it exposes.** It's the one case with a native twin: a card and `people.get` can disagree
  about the same handle. PEOPLE.md's rule that identity is a person's call (merges are
  `requires_person`) means a card never auto-merges into a `Person`. **Open question:** should
  `contacts.*` ever *propose* a `people.merge`, or stay a separate namespace that's never
  reconciled?

#### 2. Family calendar and presence

There's no availability query across people (CALENDARS.md open question 4), and no notion of
presence at all.

- **Capabilities.** `presence.current` (coarse home/away per member), `presence.history`, and
  `familycal.events` if the household runs a family-organizer app outside `calendar_backends`.
- **Realm and policy.** `household`. Following CALENDARS.md's `free_busy` masking, the manifest
  exposes coarse state only, never a location trace; that's a choice in the manifest's design, not
  something policy enforces.
- **Failure.** Losing it loses presence, not the calendar, because it doesn't wrap
  `calendar_backends`. Presence can be wrong the way an invitation title can.
- **What it exposes.** "Unified" availability means merging presence with `calendar.events`, and
  a plugin can't call the sentinel (section 4). **Decision: availability is native work.** Build
  `calendar.free_busy` per CALENDARS.md's open question 4, with the presence plugin only supplying
  its half. The alternative is a plugin principal that can call the sentinel, a different trust
  posture this design doesn't take on.

#### 3. Climate readings and host facts: native ingest, not plugins

Both are host → hob pushes with no way to execute anything: a nursery climate bridge (CLIMATE.md)
and a per-host facts collector. Neither fits the plugin venue, and the earlier draft that said
this case "validates cleanly" was wrong:

- A push is a sentinel *call*. `climate.reading.report` is the bridge asking hob to store
  something, so the bridge is an agent with a policy rule, and section 4 rules out plugin keys
  reaching the sentinel. (`SentinelPolicy#principal_is_agent` refuses rules for anything else
  anyway.)
- If hob stores the readings, then `climate.current`/`history`/`summary` read hob's own table:
  they're native handlers, not deliveries to an app.

The pattern that fits already exists: **`hob.calendar.push`**, a native `act` capability that
takes batches from agents registered as `CalendarContributor`s for a named owner, refuses
anything else, and has no read path of its own. Climate and host facts are the same shape: a
native `*.report` capability accepting pushes only from an agent registered for those
sensors/that host, and native reads over the stored rows. CLIMATE.md already proposes this; it
needs a forge build or a hand-written handler, not the plugin platform.

The host-facts gap is also smaller than the earlier draft said. The kernel version isn't read from
Coolify: the ward worker probes it (`app/services/ward/inventory.rb:20-21`, `HOST_COMPONENTS`).
And `Ward::Patches` already reports each server's pending security updates and whether it needs
a reboot (via Coolify's patch check). What's missing is mostly distro name/release and uptime, a
couple of fields on the ward's existing host asset rather than a new integration.

**What it exposes**, which still matters for real plugins: `kind` is only `read`/`act`, so nothing
in the schema separates a passive push from something exec-shaped. With acceptance (section 5) a
person sees every new capability before any rule reaches it, which makes a schema marker less
necessary. **Open question:** should registration still refuse names like `*.exec`/`*.run`/
`*.shell` outright, given that "ward watches, it does not act" (WARD.md)?

#### 4. Miniflux feed reads

Section 10's first adopter.

- **Capabilities.** `miniflux.feeds`, `miniflux.entries` (by feed/status/date), `miniflux.counters`
  (unread counts without pulling bodies). All `read`.
- **Realm and policy.** `household` by default, `personal` per section 6 for one person's own
  instance. Agent rules are default `allow` with limits: low stakes if the reviewer is wrong.
- **Failure.** Reads fail `unavailable`; the breaker trips on repeated timeouts; nothing else
  depends on feed data. Entry content is data, never instructions.
- **What it exposes.** If a community Miniflux MCP server is used instead of a first-party
  bridge, sections 2 and 4 would have been tested against the wrong venue, so open question 5 (one
  mechanism or two with MCP) has to be settled *before* Phase 4, not later.

#### 5. Notes and docs reads

Nothing in hob reads a household's running notes (RECORDS.md says records aren't memory; PEOPLE.md
notes are relationship-scoped). A self-hosted wiki or notes app fills that gap.

- **Capabilities.** `notes.search`, `notes.get`, `notes.list`. All `read`; no editing in v1.
- **Realm and policy.** A shared wiki is `household`. A personal vault (a journal, therapy notes)
  is likely to hold `intimate` material, so the realm a person confirms at acceptance (section 6)
  matters most here: a vault whose manifest says `household`, by bug or because its template
  doesn't know hob's realms, gets caught at acceptance rather than going live. A household may
  reasonably choose `review` over `allow` for every read, since read-only isn't the same as
  low-stakes (WARD.md's `ward.status`). Note that a glob rule like `muse,notes.*,review` covers
  every *accepted* `notes.*` capability, including ones accepted later, so it's a standing grant,
  not a per-capability one.
- **Failure.** If the notes app's own per-person access control has a bug, hob can't detect it
  from its side; it trusts the plugin's backend the way it trusts mise's (section 4).
- **What it exposes.** Inside one `household` registration, the app may have finer per-person
  access control than hob's per-capability realm can express. Every delivery already carries the
  calling `agent` and `realm` in its signed body (section 4), so the plugin can already tell who is
  asking. **Open question:** may a plugin rely on that for its own per-person access control, which
  would make hob responsible for attesting a stable "on behalf of whom" beyond the agent's name? Or
  does anything with per-person access control register once per person, as CALENDARS.md does
  today?

### 14. Open questions for Jenner

1. **Scope of "apps."** Does "apps expose capabilities themselves" mean household-run apps only
   (mise-shaped: Jenner's own code, Coolify-hosted), or genuinely third-party software the
   household doesn't operate (a feed reader, a bank, a smart-lock vendor)? **Decision needed:** how
   strong the identity/trust model in section 4 has to be on day one — TOFU-over-HTTPS is fine for
   the former, not for the latter. This determines almost everything else in the trust section.
2. **~~Silent vs. loud new capabilities.~~ Settled by section 5.** The earlier draft offered
   "enabled with no rule, so denied" as a safe default. It isn't safe: wildcard rules (muse's `*`)
   and waiting petitions reach a new capability the moment it exists. New plugin capabilities land
   disabled and unaccepted, and the person is notified.
3. **Who may register and accept.** Only Jenner (today's model — registration needs someone
   running a rake task), or should Tessa be able to register her own personal plugin, and accept
   its new capabilities, without a terminal? Acceptance happens on every new capability, not once
   per plugin, so it needs a quick path (a notification that links to an admin page) sooner than
   registration does. **Decision needed:** whether an admin-UI accept flow is a v1 requirement, and
   whether "personal" realm-scoped plugins (section 6) matter before that UI exists.
4. **Manifest contract strictness.** Is the `output_schema`/error-taxonomy addition (section 2) a
   hard requirement from day one, or a soft migration with a grace period (as phased)?
   **Decision needed:** whether mise's own `docs/HOB.md` contract and code need to change before
   Phase 2 ships, since mise is the only existing consumer today.
7. **The smaller questions from section 13:** whether `contacts.*` may ever propose a
   `people.merge` (13.1); whether registration should refuse exec-shaped names outright (13.3);
   whether a plugin may rely on the delivered `agent` identity for its own per-person access
   control (13.5).
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
