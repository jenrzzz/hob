# THREATS.md — ward threat intake, defense posture, and resolution

Status: proposal for jenrzzz/hob, drafted 2026-10-22 (Skipsy, at Jenner's request).
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
2. Agent-filed threats at `review`: right default, or should Marley/Skipsy
   reports about CVEs (vs. actor claims) be `allow` with ward-side triage
   doing the filtering?
3. Upstream watch: which registries does ward poll (Docker Hub, GHCR,
   Coolify's release feed), and at what cadence before it counts as noise?
4. Actor-threat default window: 7 days? And do indicators live in hob
   (auth logs shipped there) or does ward just watch its own probes?
