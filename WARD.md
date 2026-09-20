# ward

*The charm on the lintel. It does not stop the wind; it notices when a
window has been left open, and says so before the rain does.*

hob knows what the household's AI life costs, who asked for what, and what
every agent was allowed. The **ward** is where hob starts to know whether
the house is *safe*: what is exposed to the internet, whether the
scanners that check are still running, what a person has looked at and
decided to live with, and what has changed since they last looked. It is
the seed of a household protector: a thing that keeps watch across many
kinds of risk, tells a person only when telling is worth it, and, one day,
acts.

This document is the v1 design: a **findings ledger** fed by the existing
infrastructure audit, a **triage** that turns a diff into a phone
notification, and two **capabilities** so an agent can ask how the house
stands. The inventory and policy the audit checks against stay where they
are, in git; hob holds what changes over time.

## What it grows into

The horizon, so v1's shapes are chosen with it in mind:

- **More checks.** Log review (Traefik access logs, Authelia auth failures,
  `journald` on the hosts, Vaultwarden's admin log), certificate expiry,
  backup-restore verification, image CVE scanning, DNS drift against the
  Pulumi zones, new devices on the home LAN, credential-rotation
  reminders, breach notifications for the household's addresses. Each is a
  check with its own cadence; each posts runs in the same shape.
- **Knowledge.** When the memory plane (DESIGN.md Plane 3) lands, findings,
  acknowledgements, and notes become observations about host and resource
  entities, with provenance; the ward's notes are the first reviewed
  decisions the household writes down anywhere.
- **Acting.** Today the ward tells. Later, with a confirm in the loop, it
  could revoke a key, cancel a mission, quarantine a container, or queue a
  forge build for a fix. Every one of those is a sentinel capability with a
  `confirm` rule, so nothing new is needed to gate them.
- **A screen.** The companion app (clients/ios) shows petitions and
  requests; a ward screen with acknowledge-from-the-phone is the obvious
  next surface.

## Threat model

The ward watches for *exposure and drift*, not for an attacker already
inside. It trusts the scanner it runs (infra's `security/audit.py`, which
reads the Coolify API, DNS, and open ports and prints findings), and it
trusts hob. What it does not trust is the text: finding messages are built
from resource names, hostnames, and status strings that come from the
infrastructure, and one day from logs. The triage model is told they are
data and never instructions, and `ward.status` labels them the same way for
whichever agent reads them.

An agent that can ask `ward.status` learns the household's exposure. That
is sensitive, so both ward capabilities sit at `personal`, and no policy
grants them by default: a person writes the rule, per agent.

The ward does not scan from where hob runs. hob lives on cadance; a port
scan of cadance from cadance proves nothing. The worker runs on agentbox, a
different host, so scans of cadance and tabitha are from outside.

## Concepts

### Checks

A **check** is a feed the ward expects to hear from on a cadence: a slug
(`exposure`), a description, an `interval` and a `grace`. The first check
is infra's security audit, weekly, with a day of grace. A check that has
not had a *complete* run within interval + grace is **stale**, and
staleness is a finding like any other (level `error`, fingerprint
`stale`), because a scanner that stopped must not look like a clean house.

```sh
bin/rails "hob:ward:check[exposure,7,1]" DESCRIPTION="..."    # slug, interval days, grace days
```

### Runs

A **run** is one posted report: the check, when it started and finished,
the exit code, the parsed lines, the counts, and the **diff** against the
findings on file (`new`, `reopened`, `resolved`, `expired_acks`). The
worker posts what `audit.py` printed, `LEVEL message` per line, and the
exit code. hob parses; OK lines are context and never findings.

**Exit 2 resolves nothing.** `audit.py` exits 2 when it could not finish:
a scanner outage, a missing dependency, a deliberately partial `--checks`
run. Its findings are recorded, but nothing absent from it is resolved,
since a scan that did not cover port 8888 cannot show that 8888 closed.
Only a complete run (exit 0 or 1) resolves, and only a complete run counts
toward the check's cadence.

### Findings

A **finding** is a WARN, FAIL, or ERROR line that persists across runs,
keyed by a fingerprint of (check, level, message). The same drift reported
week after week is one finding with a growing `occurrences`, not a new
alarm each time. A finding a complete run no longer reports is
**resolved**; if a later run reports it again it **reopens**, and that is
a change worth telling someone about.

A finding is in one of three states:

| state | meaning |
|---|---|
| `open` | reported, not resolved, and nobody has said "I know" (or their acknowledgement lapsed) |
| `acknowledged` | a person has looked, with a note and optionally an expiry |
| `resolved` | a complete run stopped reporting it |

**Acknowledging** is the reviewed-decision line of infra's `SECURITY.md`
("step-ca TCP 9000 is intentionally public, reviewed 2026-06-12"), with a
clock: `bin/rails "hob:ward:ack[<id>]" NOTE='nordlynx proxy; auth required'
UNTIL=2026-12-01`. An acknowledged finding stays out of the open list and
out of the triage's attention until it expires, at which point it is open
again and the ward says so. No expiry means until it resolves.

### Notes

A **note** is free text a person attaches to a subject: a host, a Coolify
resource, a check. `bin/rails "hob:ward:note[vaultwarden]" BODY='2FA
enforced 2026-08; direct port reviewed.'` The triage reads the notes for
every subject in the run it is looking at, so what the household has
already decided shapes what it is told. Notes are the knowledge that
`exposure.yaml`'s `note:` fields and `SECURITY.md` hold today, in a place
that grows without a commit.

### The sweep

hob has no scheduler yet (Solid Queue is in the Gemfile and not wired).
The ward keeps time three ways instead: every ingest sweeps, every status
read sweeps, and `bin/rails hob:ward:sweep` runs hourly as a scheduled
task on the hob container in Coolify. A sweep raises stale findings and
expires acknowledgements; when it changes something outside an ingest it
writes a **sweep run** (no exit code, no lines) so the change is on the
record and triaged like any other. Idempotent, cheap, quiet when nothing
moved.

### Triage

When a run's diff is not empty, `Ward::Triage` asks a model (role
`ward-triage`, Sonnet with a Haiku fallback) what to tell a person. It
sees the check and the run's outcome; the new, reopened, resolved, and
un-acknowledged findings; what is still open; what is acknowledged and
with what note; the notes on every subject involved; and the previous
triage's headline. It answers with a schema: `severity` (`quiet` | `info`
| `attention` | `urgent`), an 80-character `headline`, a `summary`, and
up to five `next_steps`. The verdict lands on the run with the
completion's conversation id, so "what exactly did the triage see" has the
same answer as any other hob call: the snapshot. Cost is a ledger row with
`ref: ward/<run id>`.

Then `Notify.person`: the household's ntfy topic and every phone running
the companion app, titled `ward: <headline>`, the summary and numbered
steps as the body, tagged by severity. **If the model cannot be reached
or declines, the ping still goes out** with a mechanical summary
("exposure: 2 new (1 FAIL), 1 resolved; triage unavailable"). A change in
the house's exposure is never swallowed. A run with an empty diff is
quiet: no model call, no ping.

## Capabilities

Two native capabilities (SENTINEL.md), both at `personal`, granted to an
agent only by a person's rule:

| capability | kind | does |
|---|---|---|
| `ward.status` | read | the checks with their last run and staleness, the open and acknowledged findings with notes, the latest triage |
| `ward.audit.run` | act | queue a `ward.audit` mission for the ward worker to run a check now; one at a time per check |

```sh
bin/rails "hob:sentinel:policy[butler,ward.status,allow]"
bin/rails "hob:sentinel:policy[butler,ward.audit.run,confirm]"
```

## The worker

`security/ward.py` in the infra repo, next to the audit it runs. Python,
standard library only, no Ruby on the runner. Two modes:

```
python3 security/ward.py run [--check exposure] [--from-file report.txt] [-- audit args]
python3 security/ward.py work [--wait 25] [--every 604800]
```

`run` executes `audit.py`, captures its lines and exit code with
timestamps, and `POST`s them to `/v1/ward/runs` with the worker's key,
retrying and spooling the report to `WARD_SPOOL` if hob cannot be reached
(a lost report becomes a stale check, which is noticed). `work` is the
forge's loop in Python: lease `ward.audit` missions, heartbeat while the
scan runs, post the run with the mission id, complete the mission; and
with `--every`, run the scheduled check whenever the last successful post
is older than the interval. One process is both the clock and the
on-demand worker.

It runs as a Coolify app on **agentbox** from `infra/coolify/ward`, with
`HOB_URL`, `HOB_KEY`, `COOLIFY_BASE_URL`, and a **read-only**
`COOLIFY_API_TOKEN` (never the write token hob's provisioning holds).
`exposure.yaml` carries its row, `tier: private`, no routes, no ports.

## API

Agents get 403 everywhere here; they ask the sentinel.

```
POST /v1/ward/runs                  { check, exit_code, lines | output, started_at?, finished_at?, mission? }   worker or person
                                    → 201 { id, check, complete, counts, changes: { new: [finding…], reopened, resolved, expired_acks }, summary, triage }
GET  /v1/ward/runs?check=&limit=    person
GET  /v1/ward/status                person   checks, staleness, open and acknowledged findings, latest triage (sweeps first)
GET  /v1/ward/findings?state=open|acknowledged|resolved|all&check=
POST /v1/ward/findings/:id/ack      { note?, until? }  ·  POST /v1/ward/findings/:id/unack
GET  /v1/ward/notes?subject=  ·  POST /v1/ward/notes { subject, body }
```

A finding: `{ id, check, level, subject, message, state, occurrences,
first_seen_at, last_seen_at, resolved_at, acknowledged_by, ack_note,
ack_until }`.

## Setting one up

```sh
bin/rails "hob:ward:setup[ward]"                   # the worker principal and its key, shown once; registers the exposure check
bin/rails hob:ward:status                          # checks, open and acknowledged findings, the latest triage
bin/rails "hob:ward:findings[open]" CHECK=exposure
bin/rails "hob:ward:ack[<id>,jenner]" NOTE='reviewed: intentional' UNTIL=2026-12-01
bin/rails "hob:ward:note[cadance,jenner]" BODY='8888 is nordlynx; auth required on it'
bin/rails "hob:ward:runs[exposure]"
bin/rails hob:ward:sweep                           # hourly, as a Coolify scheduled task on the hob app
```

On agentbox, the ward app from `infra/coolify/ward` with the key from
`setup`. The first run lands within the hour; the triage ping follows.

## Schema

```
ward_checks     slug PK, description, interval_seconds, grace_seconds, enabled, last_completed_at, last_run_id
ward_runs       ulid, check_slug, principal?, started_at, finished_at, exit_code?, complete, counts, lines,
                diff { new, reopened, resolved, expired_acks }, triage?, mission_id?
ward_findings   ulid, check_slug, fingerprint (unique per check), level, subject, message, occurrences,
                first/last_seen_at, first/last_run_id, resolved_at?, resolved_run_id?,
                acknowledged_at?, acknowledged_by?, ack_note?, ack_until?
ward_notes      ulid, subject, body, author?
```

Not realm-scoped: one class of data, read by people and by a
`personal`-tier capability, like `agent_messages`.

## Open questions

1. **The clock.** A Coolify scheduled task is a fine hourly sweep until
   Solid Queue is wired (infra `TODO.md` wants the queue schema and a
   separate job process first). When it is, the sweep becomes a recurring
   job and the scheduled task goes.
2. **Structured audit output.** The worker posts text lines and hob
   fingerprints them; that is enough because `audit.py`'s WARN/FAIL/ERROR
   messages are stable per subject. A `--json` mode in `audit.py` with an
   explicit subject and code would make fingerprints immune to wording
   changes. Not needed yet.
3. **Acknowledging from the phone.** The companion app has no ward screen;
   `Push.link_for` knows petitions and requests. A `hob://ward/finding/<id>`
   link and a screen with ack-with-note is the next surface.
4. **A digest.** The ward is quiet when nothing changes, which is right for
   pings and wrong for a monthly "here is where the house stands". A
   scheduled digest through the same triage role, once there is a clock.
5. **Findings as memory.** When Plane 3 exists, a finding's subject is an
   entity and an acknowledgement is an observation with provenance.
   Nothing in v1's shape prevents that migration.
