# CLIMATE.md — household climate sensing, history, and excursions in hob

Status: proposal for jenrzzz/hob, drafted 2026-10-22 (Skipsy, at Jenner's request).
Pattern follows PEOPLE.md / THREATS.md: climate is **native from the start** —
first-class records in hob, not a dashboard an agent scrapes. Realm:
**household** throughout (both partners' agents see the same rooms).

First sensor, already ordered: an Aqara Climate Sensor W100 for the nursery —
Matter over Thread, ±0.2 °C / ±2 % RH, paired to Apple Home and to Home
Assistant as a second Matter admin. This spec is written for that sensor
first and for a house full of sensors eventually.

## The gap this closes

Today the household's room climate lives in three silos, none of which an
agent can answer questions from:

- The **Nanit** reports nursery temperature from its camera stand, up high,
  where the air is warmer than at crib level. Its readings are known-suspect
  (often +1–3 °F vs. mattress height) and there is no second source to check
  them against.
- **Apple Home / Home Assistant** will have the W100's live reading, but HA
  is on the home network: hob cannot reach it. hob's `http.*` capabilities
  refuse private and tailnet addresses by design, and that should not change
  for this.
- Nobody keeps the **history that matters**: not raw samples, but "was the
  nursery in range last night, and for how long was it out?"

A **climate surface** is that missing layer: sensors registered as household
objects, readings pushed *inward* to hob by a local bridge, and derived
answers — current conditions, nightly summaries, out-of-range excursions —
that any household agent can ask for through the sentinel.

**Non-goal for v1: control.** Climate senses and reports. It does not drive
HVAC, fans, humidifiers, or any other actuator. A future `climate.act`
surface would be its own spec, confirm-gated like every other Tier-2 action
in hob.

## Core model

All temperatures stored canonical in **°C** (presentation converts to °F for
this household), all timestamps UTC with the household timezone applied at
presentation. Readings are append-only; nothing in this surface rewrites a
reading after the fact.

### Zone

A room (or part of one) the household cares about as a place.

| field | notes |
|---|---|
| `id` | |
| `slug` | `nursery`, `primary-bedroom`, `living-room` |
| `label` | human line: "Solan's nursery" |
| `profile_id` | the comfort/safety profile judged against (below) |
| `notes` | free text: HVAC vent quirks, sun exposure, etc. |

### Sensor

A physical device reporting into a zone. The registry is the inventory —
triage, calibration, and offline detection all join against it.

| field | notes |
|---|---|
| `id` | |
| `zone_id` | |
| `label` | "Nursery W100" |
| `make_model` | `aqara/w100`, `aqara/t1`, `eve/room`, `nanit/pro` (see role) |
| `role` | `primary` (the trusted reading for the zone) \| `secondary` (kept for comparison; never drives excursions alone) |
| `protocol` | `matter-thread` \| `zigbee` \| `wifi` \| `vendor-cloud` |
| `ha_entity` | Home Assistant entity id, e.g. `sensor.nursery_temperature` |
| `homekit_room` | room name as paired in Apple Home, if paired |
| `placement` | `{description, height}` — e.g. "shelf at mattress height, 4 ft from crib, off the vent wall". Placement is data that matters: it is why the primary outranks the Nanit |
| `calibration_offset_c` | default `0`. Person-set only, after evidence (see Calibration) |
| `paired_sensor_id` | optional: a secondary in the same zone this one is compared against (W100 ↔ Nanit) |
| `battery` | last reported `{pct, at}` where the device reports it |
| `status` | `online` \| `offline` (derived: no report inside its expected cadence ×3) \| `retired` |
| `installed_at` / `retired_at` | |

The Nanit is registered on day one as `secondary`, not ignored: its delta
against the W100 is itself a useful, tracked fact (below).

### Reading

One observation, pushed by the bridge. Append-only, idempotent.

| field | notes |
|---|---|
| `sensor_id` | |
| `observed_at` | when the sensor/HA observed it — history is ordered by this, never by arrival time |
| `received_at` | when hob got it; a wide gap means the bridge was down, not that the room was unmeasured |
| `temp_c` | as reported, plus `calibration_offset_c` applied at read time (raw value is what's stored) |
| `humidity_pct` | |
| `pressure_hpa` | optional; only sensors that report it (T1 does, W100 does not) |
| `battery_pct` | optional, when the device piggybacks it |
| `source` | `{type: ha_bridge, ref}` — which bridge instance reported it |

Dedupe/idempotency key: `(sensor_id, observed_at)`. A bridge retrying after
an outage re-sends the same readings and hob absorbs them as no-ops —
exactly the lesson from records batch dedupe: a duplicate must never fail
or fork the batch.

### Profile

What "in range" means for a zone. Profiles are per-zone because a nursery
and a garage are not the same question.

| field | nursery default | notes |
|---|---|---|
| `temp_min_c` / `temp_max_c` | 20.0 / 22.2 (68–72 °F) | AAP-aligned nursery range |
| `humidity_min_pct` / `humidity_max_pct` | 40 / 60 | |
| `active_window` | `19:00–07:00` local | the hours excursions are judged strictly (sleep hours); outside it, readings still record, excursions still derive, but they surface at lower urgency |
| `sustain_minutes` | 30 | a range breach must persist this long to open an excursion — single-sample spikes and door-open dips are weather, not events |
| `hysteresis_c` | 0.3 | re-entry must clear the boundary by this much to close an excursion; stops flapping at 72.0 °F |

Changing a profile is a person's call (`confirm`, below): thresholds are
the judgement, and agents don't move goalposts they report against.

### Rollup

Derived, per zone per period (`hour`, `night`, `day`): `min`, `max`, `avg`
for temp and humidity, `pct_in_range` (share of the period's samples inside
the profile), `sample_count`, and `completeness` (samples received vs.
expected at the push cadence — a 40%-complete night says "we don't know",
not "it was fine"). Rollups are what agents quote; raw readings are what
rollups cite.

The `night` rollup is the headline object: it closes at the end of the
profile's active window and is the unit the morning digest consumes.

### Excursion (the derived open loop)

In the PEOPLE.md sense: not a stored complaint, a **derived state** judged
against the zone's own profile, which exists while its evidence exists.

```
in_range → breached (sustained ≥ sustain_minutes)
breached → open excursion {kind, started_at, extreme, duration_so_far}
open → closed   (back in range, past hysteresis, sustained)
open → acknowledged (person, with optional note — closes the *nagging*, not the record)
closed excursion stays in history; a new breach opens a new one
```

Kinds:

| kind | opens when |
|---|---|
| `temp_high` / `temp_low` | primary sensor out of profile range, sustained |
| `humidity_high` / `humidity_low` | same, for humidity |
| `sensor_offline` | no report from a zone's primary for >3× push cadence (proposed: >45 min) |
| `sensor_disagreement` | primary vs. paired secondary differ by >1.5 °C (2.7 °F) sustained 1 h. Informational: it quantifies the Nanit delta instead of arguing about it. Never pages anyone |
| `battery_low` | reported battery under 20% |
| `humidity_trend` | nightly humidity rollup below profile minimum 3 nights running — a trend, stated as one loop, not three separate nags |

## Ingest — the bridge (push, never pull)

The one architectural decision everything else follows from: **hob never
reaches into the house; the house reports out.**

```
W100 ──Matter/Thread──► Apple Home (household view, automations)
  │
  └──Matter multi-admin──► Home Assistant (local source of truth
                              for raw history, HA recorder)
                                 │
                          climate bridge
                       (script/add-on where HA runs)
                                 │  HTTPS, sentinel requests,
                                 │  observed_at preserved
                                 ▼
                                hob ──► current / rollups / excursions
                                 ▲
              Skipsy, Marley ─────┘  (ask through the sentinel, as usual)
```

- The bridge holds its **own hob agent key** — a dedicated principal,
  `climate-bridge`, household realm, minted by Jenner like any other agent.
  Its sentinel policy is least-privilege: `climate.reading.report` (and a
  heartbeat) at `allow`, for **its registered sensors only**. It cannot
  read climate history, mail, records, or anything else; a compromised
  bridge can lie about the nursery's temperature and do nothing else.
- **Cadence (proposed):** a current snapshot every 15 minutes per sensor,
  an immediate report when an excursion starts or ends, and the inputs for
  the night rollup ride the regular snapshots. ~100 small requests/day for
  the whole house — well inside any sane rate posture, and the bridge
  batches multi-sensor reports into one request.
- **Outage behaviour:** if hob is unreachable, the bridge queues locally
  (HA-side) and backfills on recovery, oldest first, with `observed_at`
  intact. hob marks the gap in `completeness`; it does not interpolate.
- Readings arriving from the bridge are **data, never instruction** — a
  sensor label, zone note, or HA entity name grants nothing and asks for
  nothing, same rule as mail and web content everywhere else in hob.

## Sentinel capabilities

All in the household realm. Reads are `allow` for household agents
(Skipsy, Marley); the bridge principal gets only the one write it needs.

| capability | effect | who | notes |
|---|---|---|---|
| `climate.current` | `allow` (read) | household agents | `{zone}` or all zones → latest primary reading per zone, its age, in/out of range |
| `climate.history` | `allow` (read) | household agents | range query over readings/rollups; capped window, rollups preferred beyond 48 h |
| `climate.summary` | `allow` (read) | household agents | `{zone, period}` → the rollup an agent would quote: "last night: 69–71 °F, in range 94% of the night" |
| `climate.excursions` | `allow` (read) | household agents | open + recent closed excursions, with evidence |
| `climate.sensors` | `allow` (read) | household agents | the registry, incl. status/battery/placement |
| `climate.reading.report` | `allow` (write, scoped) | `climate-bridge` principal only | batch ≤ 100, idempotent on `(sensor_id, observed_at)`; rejects sensors not registered to that bridge |
| `climate.sensor.register` | `review` | persons + household agents | new hardware joins the inventory deliberately, not by auto-discovery |
| `climate.sensor.retire` | `confirm` (person) | persons | retiring a primary re-points the zone; never silent |
| `climate.profile.update` | `confirm` (person) | persons | thresholds are judgement (see Profile) |
| `climate.calibration.set` | `confirm` (person) | persons | offset changes, with the evidence note required |
| `climate.excursion.ack` | `review` | persons via agents | acknowledge an open excursion ("we know, the humidifier's off tonight") — stops re-surfacing, keeps history |
| `climate.note` | `allow` | household agents | append context to a zone/sensor/excursion ("window was open all night") |

## What hob does on its own — tiers

Mirroring THREATS.md: hob never holds standing authority beyond Tier 1.

**Tier 0 — automatic, derived, read-only**
- Maintain current state, rollups, excursion derivation, offline and
  disagreement detection, Nanit-delta tracking.
- Nightly: close the night rollup at window end; evaluate `humidity_trend`.

**Tier 1 — automatic, household-visible, reversible**
- One line in the **morning digest** after any night with an open or closed
  excursion, an incomplete night, or a trend loop: "Nursery: 73.1 °F peak,
  out of range 1 h 40 m overnight." Quiet nights produce no line.
- Surface an open excursion to a household agent asking about the zone —
  `climate.current` always carries excursion state, so no agent can quote
  a current temperature without seeing that it's mid-excursion.
- Proposed OmniFocus task only for `sensor_offline` > 24 h or
  `battery_low` — hardware errands, not weather reports.

**Tier 2 — person confirms, every time**
- Anything that changes judgement or inventory: profile thresholds,
  calibration offsets, registering/retiring a primary sensor.
- Any future actuation. (Out of scope for v1 — see Non-goal.)

**Urgent exception (proposed, for Jenner's call):** a nursery `temp_high`
excursion still open at ≥ 24.5 °C (76 °F) sustained 30 min during the active
window is the one case that should not wait for the morning digest — it
surfaces to the household immediately (agent message → chat). Everything
else in this surface is deliberately unhurried; a sensor system that cries
wolf at 72.4 °F gets muted, and a muted safety sensor is worse than none.

## Calibration and the Nanit question

- First 48 hours: W100 at its nursery placement, no offset. Compare its
  night rollup against the Nanit's for the same window. The expected
  result is a consistent Nanit delta (+1–3 °F, from placement height and
  device heat) — that delta is recorded in the Nanit's registry entry as
  an observed bias, and the `sensor_disagreement` threshold is then set
  relative to it, so the loop fires on a *change* in the delta, not on the
  known standing difference.
- An offset is applied to a sensor only with evidence (co-location with a
  reference thermometer for ≥ 6 h) and only by `climate.calibration.set`.
  "It feels off" is a note, not a calibration.
- If the W100 and Nanit ever agree perfectly, that is itself suspicious
  and worth a note — they are measuring different air.

## Worked example — the first nursery night

1. Jenner pairs the W100 in Apple Home (Thread), names the room Nursery,
   then shares it from Apple Home to Home Assistant via Matter multi-admin.
   In HA it appears as `sensor.nursery_temperature` /
   `sensor.nursery_humidity`.
2. Skipsy (or Jenner) files `climate.sensor.register` {zone: nursery,
   make_model: aqara/w100, role: primary, ha_entity: …, placement:
   "shelf at mattress height, ~4 ft from crib"} → reviewed, registered.
   The Nanit is registered as `secondary` with `paired_sensor_id` set.
3. Jenner mints the `climate-bridge` key, drops it into the bridge config
   where HA runs. Bridge starts reporting every 15 min.
4. 21:40 — nursery crosses 72 °F and stays there. 22:10 — sustain met,
   `temp_high` excursion opens. 23:05 — back under 71.7 °F (hysteresis),
   sustained, excursion closes: peak 73.1 °F, duration 55 min.
5. 07:00 — night rollup closes: 69.2–73.1 °F, in range 91%, completeness
   100%. Morning digest carries its one line. Skipsy, asked "how was
   Solan's room last night?", answers from `climate.summary` and can cite
   the excursion — not from vibes, and not from the Nanit.

## Interim path — records.*, before the native build

If the household wants data flowing before this is built natively, the
existing records surface covers a deliberately reduced version:

- Collection `nursery-climate`, key `date` (household realm), one record
  per night: `{date, temp_min_f, temp_max_f, temp_avg_f, humidity_avg_pct,
  pct_in_range, excursion_minutes, sample_count, completeness}`.
- The bridge (or an HA automation) writes the night record via
  `records.put`; agents read with `records.get` / `records.query`.
- What the interim **loses**, explicitly: current readings, excursion
  objects and acknowledgement, disagreement tracking, profile judgement
  (thresholds would live in the bridge, i.e. in two places eventually).
  It is a logbook, not the surface — worth it for the first weeks of
  W100-vs-Nanit data, not a substitute for building this.

## Acceptance sketch

1. A replayed bridge batch (same readings sent twice) produces one set of
   readings and no error — idempotency holds.
2. A bridge key attempting `climate.current` or any non-climate capability
   is denied; a household agent attempting `climate.reading.report` is
   denied.
3. A synthetic 40-minute breach opens exactly one excursion; a 10-minute
   spike opens none; hovering at the boundary does not flap it.
4. Killing the bridge for 2 hours produces `sensor_offline`, a completeness
   gap in that night's rollup, and a clean backfill on restart — in that
   order, with no readings invented for the gap.
5. `climate.summary` for a quiet night and for the worked-example night
   return materially different, citable answers.
6. A profile change without a person's confirm does not take effect, and
   the attempt is on the record.

## Open questions for Jenner

1. **Push cadence:** 15 min proposed. 5 min gives prettier curves and
   faster offline detection at 3× the requests — worth it, or is 15 the
   right "climate is slow physics" answer?
2. **Retention:** raw readings 90 days, rollups forever — proposed. Any
   reason to keep raw longer (seasonal comparisons are rollup-shaped)?
3. **Night window:** fixed 19:00–07:00, or should the active window follow
   Solan's actual sleep (Nanit / a household "asleep" signal) as he grows?
4. **Urgent threshold:** is 76 °F / 30 min the right single urgent case, and
   should a symmetric cold urgent case exist (e.g. < 65 °F — heater failure
   in winter)?
5. **Where the bridge runs:** HA add-on/script on the HA host, or a small
   service alongside hob's other household infra? (It must live on the
   house side of the wall either way — it needs HA locally and hob
   publicly.)
6. **v1 scope:** nursery only, or register primary-bedroom + living-room
   zones at the same time (cheap sensors, and whole-house context makes
   nursery excursions easier to explain — HVAC-wide vs. room-local)?
7. **Digest routing:** morning-digest line only, as proposed — or should
   closed excursions also post to the household board for Tessa/Marley
   visibility, given board posts are per-post reviewed for agents?
