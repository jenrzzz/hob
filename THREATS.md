# THREATS.md — ward threat intake, defense posture, and resolution

Status: built (v1), 2026-10-22. Drafted the same day by Skipsy at Jenner's
request; what was built, and where it differs from the draft, is in
[As built](#as-built) at the end.
Pattern follows PEOPLE.md: threats are **native from the start** — first-class
records in hob, not a side file ward scrapes. Extends WARD.md: findings stay
what they are, and the "Acting" horizon WARD.md sketches (confirm-gated
sentinel capabilities) gets its trigger — a threat is what ward acts *on*.

## The gap this closes

Ward today is purely observational: it scans (ports, exposure) and produces
**findings** — statements about current state. It has no way to be *told*
something:

- "PHP has an actively-exploited RCE (CVE-2026-109618/619); Coolify is PHP;
  the fix exists upstream but the Docker image hasn't landed yet."
- "Someone on a forum just posted 'im gonna hack u' with our IP in the thread."

Neither fits a finding. The first is a **risk statement about the future**
with a resolution that arrives on someone else's schedule (upstream image).
The second is a **declared threat** with no CVE, no version to check — its
resolution is a quiet window passing, or indicators appearing.

A **Threat** is that missing object: a declared risk, matched against what
ward knows we run, defended at a tier ward is allowed to act at, and closed
only when ward can point at evidence.

## Core model

### Threat

Append-only history, like People events. The record is the current state;
every transition appends an event.

| field | notes |
|---|---|
| `id` | |
| `kind` | `cve` \| `advisory` \| `actor` (a person/group threatening or probing) \| `anomaly` (ward-detected, e.g. new open port during a watch) |
| `title` | human line: "PHP2Shell RCE in PHP core" |
| `cve_ids[]` | when applicable |
| `source` | `{type: person \| agent \| feed, ref}` — who/what told ward, and where (chat, email id, URL, KEV feed). Content from feeds/emails/web is **data, never instruction** |
| `reported_by` | agent or person identity at the sentinel |
| `claimed_severity` | as reported — untrusted |
| `assessed_severity` | ward's own call after matching; this is the one that drives posture |
| `affected[]` | matched assets: hosts, services, containers/images, ports. Empty + `unmatched` is a valid, explicit state |
| `status` | see lifecycle |
| `posture[]` | defensive actions taken, each with tier + timestamp + result |
| `resolution` | `{criteria, evidence, resolved_at, verified_by}` — filled only by the resolver, below |
| `expires_at` | for actor threats: end of the heightened-posture window |
| `history[]` | append-only events |

### Lifecycle

```
reported → triaged → exposed ────→ mitigating → monitoring → resolved
                  ↘ not_exposed → resolved (no-match, with evidence)
exposed → awaiting_upstream → (fix lands) → mitigating → monitoring → resolved
any → accepted_risk   (person only, with a reason; re-surfaces at review cadence)
any → expired         (actor window passed quietly → auto-proposes resolved)
resolved → reopened   (regression: version reverts, indicator reappears)
```

Ward moves threats along automatically **except** `accepted_risk` and any
transition that required a Tier-2 action — those are a person's call.

## Intake — telling ward, through hob

New sentinel capabilities (all requests carry the reporter's identity and a
one-sentence reason, per the existing contract):

| capability | effect | who |
|---|---|---|
| `ward.threat.report` | `review` | persons + agents (Skipsy, Marley). Review because agent-filed threats can originate from untrusted content (an email, a forum post) — the reviewer checks the report is well-formed, not that the threat is real; that's ward's triage job |
| `ward.threats` (list/get) | `allow` (read) | same audiences as `ward.status` |
| `ward.threat.note` | `allow` | append evidence/context to a threat's history |
| `ward.threat.accept_risk` | `confirm` (person) | stand a threat down as accepted |
| `ward.threat.standdown` | `confirm` (person) | end an actor-threat window early |

Dedupe: a report whose `cve_ids` intersect an open threat's merges into it
(new source appended) instead of creating a twin. Actor threats dedupe on
(target surface + actor handle) within their window.

CVE enrichment at triage: ward may look up the CVE in KEV/NVD-style feeds to
fill fixed-version data — the lookup result is evidence, and the *feed's*
severity never overrides ward's assessed severity from our own inventory.

## Triage — matching a threat to what we actually run

Ward already has scan targets and finding history. Threats need one more
input: a lightweight **asset inventory** ward maintains:

- hosts (cadance, tabitha, agentbox), with roles
- services per host (from existing findings + scan targets)
- container images + tags/digests per service, and component versions where
  a cheap probe exists (HTTP banner, `--version` over existing channels,
  image label)

Inventory source (**decided 2026-10-22, Jenner**): ward gets a **read-only
Coolify API token** and pulls applications, services, image tags/digests,
and versions straight from the control plane — Coolify already knows what
it runs. Probes stay as the cross-check (what Coolify *says* runs vs. what
answers on the wire), and hosts/services outside Coolify's view still come
from scan targets + findings. The token is read-only, minted by Jenner,
held wherever ward keeps its other service credentials; it is the same
token shape as the one the sslip.io fallback-domain cleanup needs, but
that cleanup wants write — keep the two grants separate: ward's is
read-only, full stop.

Triage = join the threat's identifiers (CVE → component + fixed versions;
actor → named surface) against the inventory:

- Match with vulnerable version → `exposed`, assessed severity from
  exploitability × exposure (public > tailnet > localhost).
- Match with fixed version → `not_exposed`, attach the version evidence.
- No inventory match → `not_exposed (unmatched)`, stated as such — never
  silently dropped, because inventory is known-incomplete.
- Can't tell (no version probe) → `exposed (unverified)` at reduced
  confidence; ward's first posture action is to get the version.

## Defense posture — what ward may do on its own

Tiered, mirroring sentinel effects. Ward never holds standing authority
beyond Tier 1; anything disruptive goes through the sentinel per-call,
exactly like `ward.portcheck` stays at review.

**Tier 0 — automatic, read-only**
- Re-scan affected targets; raise their scan/portcheck cadence for the
  threat's duration.
- Version-probe affected components; correlate with open findings (a CVE
  on a service with an open exposure finding escalates both).
- Watch for the fix: poll the image registry / upstream release feed for
  the fixed tag or digest (this is the PHP case — see worked example).

**Tier 1 — automatic, reversible, household-visible**
- Open/track an OmniFocus task on the right list and keep it updated.
- Notify: mission or agent message to Skipsy/Marley (which surfaces to the
  household in chat), and a line in ward's triage output.
- Propose the remediation as a staged, ready-to-approve action ("image
  vX available; upgrade Coolify? [confirm]").

**Tier 2 — person confirms, every time (sentinel `confirm`/`review`)**
- Firewall/block a port or source, pause/stop a container, take a service
  offline, force an upgrade, rotate a credential.
- Ward prepares the exact action and its blast radius; a person taps go.

Actor threats cap at Tier 1 automatically regardless of claimed severity —
a stranger posting threats must not be able to make ward DoS the household.
Only observed indicators (auth failures, probes from the named source, new
exposure) let ward *propose* Tier 2.

## Resolution — ward decides, with evidence

A threat is `resolved` only when its kind-specific criteria hold, and the
resolution block names the evidence:

- **cve**: every matched asset probes at ≥ the fixed version (or runs an
  image digest containing the fix), verified by a fresh probe *after* the
  change — including component-specific gotchas recorded on the threat
  (e.g. PHP: FPM/workers restarted post-patch, because stale worker state
  carries one of the flaws). Sustained across 2 checks ≥1h apart.
- **awaiting_upstream → cve**: the upstream watch fires, the upgrade is
  confirmed and done, then the cve criteria above.
- **actor**: `expires_at` passes with zero indicators logged during the
  window → ward proposes `resolved (quiet window)`; a person can confirm
  or extend. Any indicator resets the clock and re-triages.
- **not_exposed**: resolution is the triage evidence itself (versions or
  absence), recorded at triage time.
- **accepted_risk**: never auto-resolves; re-surfaces in triage output at
  the household review cadence until patched or stood down.

Regression reopens: if a resolved CVE's asset later probes below the fixed
version (rollback, new unpatched container), the threat reopens at
`monitoring` with the regression in its history.

## Worked example 1 — PHP2Shell (today)

1. Skipsy files `ward.threat.report` {kind: cve, cve_ids:
   [CVE-2026-109618, CVE-2026-109619], source: Hetzner customer email +
   Rapid7/Bitsight reporting active exploitation, claimed: critical}.
2. Triage: inventory match — Coolify (cadance control plane; also manages
   tabitha + agentbox) is PHP/Laravel. Version unverified → posture Tier 0:
   probe Coolify's image/version first.
3. Jenner's call: wait for upstream Docker images → status
   `awaiting_upstream`, Tier 0 watch polls for the fixed image; Tier 1
   OmniFocus task opened; no repeated nagging — ward speaks again only
   when the image lands or exploitation indicators appear.
4. Image lands → Tier 1 staged proposal → Jenner confirms (Tier 2 upgrade)
   → ward verifies PHP ≥ 8.3.36/8.4.27 (per branch) in the running
   container, workers restarted, twice, ≥1h apart → `resolved`, task
   closed, one line to the household.

## Worked example 2 — "im gonna hack u"

1. Jenner (or Skipsy, from a screenshot/post Jenner hands over) files
   {kind: actor, source: forum URL, target surface: "the house / hob"}.
2. Triage: no CVE to match; ward assembles the current public surface from
   findings (the intentionally-public feed curators, cowyo, etc.).
3. Posture (Tier 0/1 only): portcheck cadence up on public targets, watch
   auth/failure indicators, household notified once. Window: 7 days
   default, Jenner can extend/stand down.
4. Quiet window → proposed resolved. Indicators → history entry, window
   resets, Tier 2 block proposed for Jenner's confirm.

## Open questions for Jenner

1. ~~Inventory source~~ — **decided 2026-10-22**: read-only Coolify API
   token (see Triage). Ward's grant stays read-only and separate from any
   write token minted for the sslip.io cleanup.
2. ~~Agent-filed threats at `review`~~ — **as built**: policy is the
   household's, as for every capability (no rule grants any of these by
   default). The recommended rule for every agent is `review` for
   `ward.threat.report`, CVEs included: the reviewer only checks the report
   is well formed, and ward's triage does the filtering either way. An
   agent's word never sets `exploited` (a person's or a feed's does), and a
   claimed severity is capped at `high`, so an `allow` rule cannot let a
   report push ward past Tier 1 on its own.
3. ~~Upstream watch~~ — **as built**: GitHub tags (Coolify's release feed,
   `coollabsio/coolify`) and Docker Hub tags, every 6 hours by default
   (`poll_hours` per threat). Polls are silent; ward speaks once, when the
   fix lands. GHCR is not polled: its tag list for Coolify is too long to
   read through `Web` whole.
4. ~~Actor-threat default window~~ — **as built**: 7 days
   (`HOB_WARD_ACTOR_WINDOW_DAYS`, or `window_days` per report). Indicators
   are what ward observes itself (a new or reopened finding during the
   watch, from its own runs) and what a person or agent notes with
   `indicator: true`. Auth logs are not shipped to hob; that is the next
   source when they are.

## As built

What is here, as of v1. The design above stands; this is the reference.

### Capabilities

All five at `personal`, granted only by a person's rule:

```sh
bin/rails "hob:sentinel:policy[skipsy,ward.threat.report,review]"
bin/rails "hob:sentinel:policy[skipsy,ward.threats,allow]"
bin/rails "hob:sentinel:policy[skipsy,ward.threat.note,allow]"
bin/rails "hob:sentinel:policy[skipsy,ward.threat.accept_risk,confirm]"   # requires_person: only confirm or deny
bin/rails "hob:sentinel:policy[skipsy,ward.threat.standdown,confirm]"     # requires_person
```

`ward.status` now carries the open threats too.

### Lifecycle, as the code holds it

`WardThreat::TRANSITIONS` is the table; a move it does not have raises.
Two places differ from the sketch above. `reopened` is an event, not a
status: a regression puts a resolved threat back at `monitoring`. And
`not_exposed → resolved` on the triage evidence happens only at intake;
a threat that was `exposed` resolves the resolver's way, never on one
re-triage.

CVE resolution, precisely: every matched asset at or past its branch's
fixed version, each asset's version **seen since the threat was reported**
for the first check and **seen again since the previous check** for each
one after, checks at least an hour apart, two of them, and every gotcha
checked off by a person with evidence. A floating tag (`php:8.3`), a
branch with no fix named, or a version that does not parse is `unknown`,
never `fixed`.

A distro's own numbering is a **scheme**. Ubuntu's kernel `6.8.0-139`
carries fixes backported from upstream releases it does not name, so an
observation in a scheme (`data.scheme`, e.g. `ubuntu`) is held only to
fixes named for it, `{ "ubuntu:6.8.0": "6.8.0-140" }` (the ABI, as
`uname -r` shows it), and never to upstream's `{ "6.8": "6.8.12" }`; with
none named it is `unknown`. Nor does a later line in a scheme count as
fixed: a distro names a fix per release it ships.

### Inventory and observations

`Ward::Inventory` reads Coolify's `/version`, `/servers`,
`/applications`, `/services`, and `/databases` with
`HOB_WARD_COOLIFY_TOKEN` (and `HOB_WARD_COOLIFY_URL`, else `COOLIFY_URL`);
its client has no method that writes. Images become components
(`php:8.3.30-fpm` → `php 8.3.30`), Coolify itself implies `php` and
`laravel`, and a person can add components or override exposure
(`hob:ward:inventory:declare`). Exposure: an FQDN is public, none is
tailnet, a database is localhost unless Coolify says it is public.
Without a token, the scan targets alone are the inventory.

Every Coolify server is a `host` asset that runs `linux_kernel` (all its
containers share that kernel) and Docker Engine as `docker` and `moby`
(NVD uses both names) at the `docker_version` Coolify read off it. So a
kernel CVE matches every host and is `exposed (unverified)` until the
worker has probed each one; it is never resolved unmatched for want of an
inventory. A host Coolify does not
manage (the Pis) is declared by a person:
`bin/rails "hob:ward:inventory:declare[tomcod]" KIND=host HOST=tomcod COMPONENTS=linux_kernel`.

Coolify's claims become observations on every sync. A **probe** (the ward
worker) or a **person** posts what answers on the wire to
`POST /v1/ward/observations`; a probe seen since Coolify's claim last
changed wins, and any disagreement is shown on the threat.

The worker (infra `security/ward.py`) runs the probes `security/probes.yaml`
names after every audit, so a threat's raised audit cadence keeps them
fresh, and on a `ward.probe` mission, which hob queues (one at a time) when
a match has no version. Today's probes are Coolify's version and the
`PHP_VERSION` of the image it runs: what the image was built with, not a
process asked on the wire, which is why "workers restarted" stays a
person's gotcha. Kernels are read from each host's node exporter over the
tailnet (`node_uname_info`), and agentbox's from the worker's own
`uname`, posted with the boot time as `started_at` (a reboot onto a new
kernel is a new row) and the full release, distro, and scheme in `data`.

### Posture, as built

- **Tier 0**: a `ward.audit` mission for the worker; a
  `ward-threat-<id>` schedule running the exposure audit every 6 hours
  (`HOB_WARD_WATCH_CRON`) until the threat resolves; an inventory refresh
  and a `ward.probe` mission when a match has no version; a note on
  any open finding about a matched asset, and a step up in severity.
- **Tier 1**: a task through Todos (`HOB_WARD_TODO_BACKEND`,
  `HOB_WARD_TODO_LIST`), kept updated, completed at resolution, reopened
  on regression; a ping (`Notify.person`); and, for each agent named in
  `HOB_WARD_TELL` (`skipsy,marley`), a `ward.threat.notice` mission to
  pass it on. Ward is a worker, not an agent, so it cannot send
  `hob.agent.message`; a mission is how it reaches them.
- **Tier 2**: proposals only (`upgrade` when an upstream fix lands,
  `block` on an observed indicator, `resolve` when an actor window passes).
  A person confirms or declines with `hob:ward:threat:decide` or
  `POST /v1/ward/threats/:id/proposals/:proposal/confirm`. **Ward holds no
  grant to carry a Tier 2 action out**: confirming records the decision,
  moves the threat (an upgrade puts it at `mitigating`), and notes the task;
  the doing is a person's, until a capability exists for it.

Every action, taken or skipped, is on the threat's posture list and in its
history with its result. A missing piece (no worker, no todo backend)
is recorded as skipped and never hides the threat.

### CVE lookup

Off unless `HOB_WARD_CVE_LOOKUP=nvd`. NVD's CVE API, through `Web`, fills
the component and per-branch fixed versions only where the report had
none, and sets `exploited` when NVD carries CISA's KEV date. NVD's
severity is kept on `enrichment` as evidence and never becomes ward's.

### API and tasks

```
GET  /v1/ward/threats?state=open|closed|all|<status>  ·  GET /v1/ward/threats/:id    (with history)
POST /v1/ward/threats                       { kind, title, cve_ids, component, fixed_versions, gotchas, source, claimed_severity, exploited, actor, target, window_days, upstream }
POST /v1/ward/threats/:id/notes             { body, evidence?, indicator?, satisfies? }
POST /v1/ward/threats/:id/retriage · /accept_risk { reason, review_days? } · /standdown { reason } · /extend { days? }
POST /v1/ward/threats/:id/await_upstream    { source: github|dockerhub, repository, current?, fixed?, poll_hours? }
POST /v1/ward/threats/:id/gotchas/:index    { evidence }
POST /v1/ward/threats/:id/proposals/:proposal/confirm|decline   { note? }
GET  /v1/ward/assets · POST /v1/ward/assets/sync · PATCH /v1/ward/assets/:id { components?, exposure? }
POST /v1/ward/observations                  { asset, component, version, digest?, started_at?, data? }    (the worker, or a person)
```

```sh
bin/rails hob:ward:inventory:sync · :assets · "observe[coolify,php,8.3.36]" · "declare[coolify]" COMPONENTS=php,laravel
bin/rails hob:ward:threat:report · :list · "show[<id>]" · "note[<id>]" · "retriage[<id>]"
bin/rails "hob:ward:threat:await[<id>]" · "accept[<id>]" · "standdown[<id>]" · "extend[<id>,7]" · "gotcha[<id>,0]" · "decide[<id>,<proposal>,confirm]"
bin/rails hob:ward:sweep                    # the sweep, then the threats' upkeep; WardSweepJob does both hourly
```

### Schema

```
ward_threats        ulid, kind, title, cve_ids[], component, fixed_versions, gotchas, sources, reported_by, claimed/assessed_severity,
                    confidence, exploited, actor, target, affected, status, posture, proposals, passes, resolution, upstream,
                    enrichment, expires_at, window_days, review_at, accepted_reason, accepted_by, todo_id, schedule_id, resolved_at
ward_threat_events  ulid, threat, kind, from/to_status, principal?, body, data           (append-only)
ward_assets         ulid, ref (unique), name, kind, host, role, source, exposure, image, tag, digest, components, declared, last_seen_at, gone_at
ward_observations   ulid, asset, component, version, digest, source (coolify|probe|person), principal?, started_at, first/last_seen_at
```

Not realm-scoped, like the rest of the ward.

### Not yet

- **Tier 2 execution.** Proposals are confirmed, not carried out.
- **A model in triage.** Threat pings are mechanical; `Ward::Triage`
  still reads findings only.
- **Auth-log indicators.** See open question 4.
- **Native threat sourcing.** See the sourcing section at the end.
  Interim: Skipsy bellwether (external, since 2026-10-25).

## Threat sourcing — proposed (decided 2026-10-25, not yet built)

How ward learns about new threats on its own, instead of waiting for a
person or an agent to read the news. Jenner's call, 2026-10-25: build this
into hob natively; until it lands, Skipsy bellwethers externally (below).

### Sources

- **CISA KEV — primary.** Actively exploited is the bar for a feed to open
  a threat unprompted, and KEV is the catalog of exactly that. Small
  (under two thousand entries), updated roughly daily, plain JSON.
- **NVD — secondary, watched components only.** A new CVE naming a
  component in ward's inventory but not (yet) in KEV opens as an
  `advisory`-grade candidate at low confidence, or enriches an existing
  threat — it never sets `exploited` on its own. This is the existing
  `HOB_WARD_CVE_LOOKUP` path widened from lookup-at-triage to a watch.
- **Vendor advisories** for inventoried components with no CVE yet
  (a Coolify security release, a Docker bulletin) — `kind: advisory`,
  same matching rules.

### Mechanics

- A sourcing poll rides the hourly sweep (`WardSweepJob`): fetch KEV,
  diff `cveID`s against every CVE ward has ever seen (open or resolved —
  the threats table is the watermark, no separate seen-list), and match
  survivors against `ward_assets.components`.
- **Match → threat.** `kind: cve`, `reported_by` = ward itself,
  `source` = the feed entry. A feed's word may set `exploited` (open
  question 2), and KEV listing is exactly that case. Claimed severity is
  the feed's, capped as usual; ward assesses its own from inventory.
  Dedupe is free: a CVE already on an open threat merges by `cve_ids`.
- **No match → dismissed, but on the record.** A candidate that matches
  no inventoried component is logged as a sourcing event (feed, CVE,
  date), never a threat. The "never silently dropped" rule binds
  *reports*; a feed of thousands cannot be allowed to become a threat
  queue of thousands. The dismissal log is what makes the filter
  auditable when a match is later declared (an asset gains a component →
  re-run the log against it).
- **Noise bound.** Sourcing opens threats silently into triage, like
  upstream-watch polls. The household hears about a sourced threat when
  triage finds an exposed asset, or in the next posture summary —
  never one message per CVE.
- **Cadence.** KEV every 6 hours (aligned with the upstream-watch
  default); NVD watch daily is plenty. A poll that errors is silent
  once and loud on the third consecutive failure.

### Interim: the bellwether (external, running since 2026-10-25)

Until this ships, Skipsy polls KEV every 12 hours, filters new entries
against a household-stack keyword list, and files matches through
`ward.threat.report` at `review` — the ordinary agent intake above.
Known limits, accepted for the interim: the keyword list is a blunt
stand-in for inventory matching (it over-reports; ward's triage is the
real filter), it depends on Skipsy's scheduler being up, and its
watermark is a local file, not the threats table. When native sourcing
lands, the bellwether stands down and this section's "proposed" comes
off.
