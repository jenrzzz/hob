# situation

*The weather in the house. Where each person is, what they are in the
middle of, who is around, and what is on their mind right now: the
things a good housemate knows without being told, and an agent
otherwise has to guess at or ask about every single time.*

Every agent that talks to a person talks to them in a vacuum. The kat
companion does not know the kids are in the room. Muse plans Tessa's
week at 11pm as if it were 9am. Skipsy's morning pass surfaces an
aged loop on a day Jenner is driving to Portland and cannot act on
it. Each surface either asks ("where are you right now?"), infers
from the conversation and forgets by the next one, or keeps a private
guess in its own notes. The person's present moment is the one input
every response should be tailored to, and nothing in the house holds
it.

So hob owns a **situation**: a small, per-person, present-tense state
made of **facets** (where, doing what, with whom, asleep or awake,
free or busy, how they are) and **topics** (what is top of mind),
each with provenance, a realm, and an expiry. Sensors write it (a
phone, a home automation, a surface), agents add what they infer or
were told, hob derives the rest (the hour, the day, the surface in
use), and **every model call hob assembles gets it**, at the
clearance of the call. Agents outside hob read it as one capability.

It is not memory. Memory is what is durably true about a person
(DESIGN.md, plane 3); situation is what is true this afternoon and
will not be by tonight. Everything in it expires. It is not surface
context either (`context:` on a chat turn, the `scenario` stage):
that is what is *on screen*; this is the *person*.

## Motivating examples

**Thursday, 14:05.** Jenner is at his desk, Tessa took the kids out,
the dentist is at 16:00, skipsy flagged the ADU permit two days ago
and Eugene's text is eight days unanswered. A kat turn at 14:05 opens
with all of that in a hundred tokens: the companion knows it has the
house to itself for ninety minutes, knows not to start something that
runs into the dentist, and knows the permit is the thing weighing on
him. At 15:40 the phone reports *driving*; the same companion, asked
something, keeps it short.

**Saturday, 02:10.** A `confirm` request lands. The situation says
Jenner has been asleep since 23:30. hob holds the ping until the
sleep facet ends, instead of lighting up a phone at 2am for a
schema change nobody needs decided before breakfast.

**Tessa's kitchen.** Marley is asked to plan Tuesday. The situation
(household realm) says Tessa is home with both kids and Jenner is
away until Wednesday. Marley plans for three, not four, without being
told, and says so.

## Use cases

Stated from the person's point of view; the agent is the usual reader.

1. **Tailor the reply, not the facts.** "Know what I am in the middle
   of before you answer." The content an agent would say is the same;
   its length, timing, register, and what it assumes about who can
   see the screen are not. This is the default consumer: the
   assembly pipeline, on every turn, for every persona, including
   the intimate ones.
2. **Know what is on my mind.** "Do not make me re-explain the permit
   saga to every agent." Topics are the few things currently
   occupying a person, with who put them there and how long ago, so
   a persona can ask about the permit instead of the weather.
3. **Know who is around.** "Do not be explicit when the kids are in
   the room." Company is the facet an intimate surface needs most
   and can least afford to guess; it lives at `household` so every
   surface above it sees it.
4. **Know when I am reachable.** "Do not ping me asleep, driving, or
   in a meeting unless it cannot wait." Availability and sleep feed
   `Notify`, and an agent deciding whether to nudge now or at
   breakfast.
5. **Tell it once.** "I'm heading out for the weekend; assume I'm not
   checking anything." A person sets a facet or a topic in one
   sentence, from a chat, Claude Code, a Shortcut, or the admin page,
   and every agent has it.
6. **Let the house sense it.** Location, motion, sleep, and
   presence are things the phone and the home already know. They
   write it; nobody narrates their day to an API.
7. **Let agents contribute, carefully.** "Skipsy noticed I'm stressed
   about the permit; the companion should know, as skipsy's opinion."
   An agent's inference is a topic with a byline and a short life,
   never a fact.
8. **Both of us, one house.** Tessa's situation and Jenner's are two
   rows in one module, each written by their own sensors, each
   visible by realm. "Who is home" is a household question; "what is
   Jenner doing" past home/away is not Tessa's agent's business.

## The model

### Observation

The one stored thing. Append-only; a facet changes by a newer
observation of the same kind, and ends by an observation that says
so.

```
{ id, person,                      a principal of kind human
  kind,                            a facet kind (below), or "topic"
  slot,                            a topic's slug ("adu-permit"); null for facets
  value,                           typed per kind; a topic's is { text, detail? }
  realm,
  basis: "sensed" | "stated" | "inferred" | "derived",
  source: { kind: "device" | "automation" | "surface" | "agent" | "person",
            by,                    the principal that wrote it
            surface,               the key's surface ("app:iPhone", "shortcuts", "kat")
            ref? },                a message id, a calendar event id: why it believes this
  observed_at,                     when it was true (defaults to the write)
  expires_at,                      always set; the kind's default TTL unless the writer says
  ended_at?, ended_by?,            an explicit "not anymore"
  created_at }
```

`basis` is what the reader hedges on. *Sensed* came off a sensor;
*stated* is the person's own words, recorded by themself or by an
agent they said it to; *inferred* is an agent's conclusion; *derived*
is hob's own arithmetic, never stored. A rendered situation says which
is which: "at home" versus "skipsy thinks he is stressed about the
permit."

### Facets

A **facet** is a slot: one current value per `(person, kind, realm)`,
the newest unexpired, unended observation. Kinds are a small blessed
vocabulary with typed values, because every one of them is rendered
into a prompt and read by a sentinel reviewer; free-form kinds would
be a second topic list wearing a schema.

| kind | value | default realm | default TTL | typical writer |
|---|---|---|---|---|
| `location` | `{ place: "home" \| "away" \| <named place>, since }` | `household` for home/away; `personal` for a named place | 3h | phone, home automation |
| `sleep` | `{ state: "asleep" \| "awake", since }` | `household` | 12h | phone (Sleep focus, HealthKit), alarm |
| `company` | `{ with: ["tessa", "kids", "guests", ...] \| [] }` | `household` | 3h | home presence, a person, a surface |
| `availability` | `{ state: "free" \| "busy" \| "do_not_disturb", until?, why? }` | `household` | 2h | Focus mode, calendar, a person |
| `activity` | `{ doing: "working" \| "driving" \| "walking" \| "exercising" \| "cooking" \| "resting" \| "out" \| <short text>, since }` | `personal` | 1h | phone motion, a surface, a person |
| `device` | `{ using: "phone" \| "tablet" \| "desk" \| "watch" \| "voice" }` | derived from the request's surface | the request | hob |
| `energy` | `{ level: "low" \| "ok" \| "high" }` | `personal` | 6h | a person, an agent |
| `mood` | `{ text }`, 60 chars | `personal` | 6h | a person, an agent, an intimate surface |
| `health` | `{ text }`, 120 chars | `personal` | 24h | a person |
| `plans` | `{ next: text, at, back? }` | `household` | until `at` (or `back`) | a person, the phone, a surface |

Any kind may be written at a realm above its default (`mood` at
`intimate`), never below it: a `personal` writer cannot say where
Jenner is at `household` except as home or away. Coordinates are
never a value. The phone resolves them to a place the person named
on the phone, or to `away`; hob does not learn where `away` is.

`location` is the one facet that exists at two realms at once by
design: `household` holds `home`/`away`, `personal` holds the named
place. A `household` read sees "away"; a `personal` read sees "at the
office". That is DESIGN.md's per-clearance digest, done by writing
twice rather than redacting once. The useful part of being away,
for the house, is not where but *until when*: "at the dentist, back
by 17:00" is a `plans` facet at `household`, which is why `plans`
defaults there. There is no third rung on `location`.

A facet whose TTL has run out is **stale**, and a read says so: it
comes back with `stale: true` and its age, and the stage's line says
"last seen at home, 5h ago" rather than "at home." Stale sensed
facets carry on being shown for one more TTL, then drop out. A sensor
that has gone quiet must look like a sensor that has gone quiet.

### Topics

A **topic** is one line about what is occupying a person: "the ADU
permit (county said 2 more weeks)", "Eugene's text, unanswered",
"PR #63 shipped; waiting on prod". Many at once, each keyed by a
slug so the writer can refresh or end it.

```
{ slot: "adu-permit", value: { text, detail? }, realm, basis,
  source, observed_at, expires_at }
```

`text` is at most 140 characters; `detail` 500. Default TTL three
days. A put on the same slot refreshes it: the clock resets, the
text may change, and the topic keeps its `first_seen` from the
original observation, so a topic skipsy has re-asserted every
morning for three weeks reads "skipsy, since 21d", and a stuck agent
looks stuck rather than fresh. At most twelve live topics per person
per realm are returned, most recently refreshed first; writers past
that are stored and not shown. An agent may end a topic it wrote;
only a person ends another's.

A topic's `ref` says what it was concluded from: a message, a mail,
an event. **It may not be a situation observation.** A `ref` of
`situation:<id>` is refused at the write, so an agent cannot read
another agent's inference and write a conclusion drawn from it;
inference does not compound through this table. The byline on every
topic is the second line of defense.

A topic is an opinion with a byline. Rendered: *"skipsy, 2d: stressed
about the ADU permit."* A topic from the person themself renders
without the hedge. Agents never write facts about a person into a
topic that another agent will read as ground truth; the basis and the
byline are what stop a guess from becoming the house's premise.

### Derived facets

Computed at read time from what hob already knows, never stored:

- **the hour and the day** in the person's zone (`HOB_TIME_ZONE`, or
  a `time_zone` the phone's location write carries): "Thursday
  afternoon", not a timestamp, so the rendered block does not change
  every minute.
- **`device`**, from the request's `surface`: a kat turn is on the
  tablet, a Claude Code call is at the desk, the companion app is the
  phone.
- **the next calendar event**, when a `plans` facet is absent and the
  read asks for it (`derive: ["calendar"]`): the soonest busy event
  in the next six hours from the calendars visible at the clearance,
  cached for five minutes per person and clearance. Not on by default
  in the pipeline: a CalDAV read per chat turn is a cost the person
  pays in latency.
- **open loops**, when [PEOPLE.md](PEOPLE.md) exists: the aged ones,
  as topics with basis `derived`.

### The read

```
Situation.get(person?, derive?) →
{ as_of, people: [
  { person: "jenner",
    facets: [ { kind, value, realm, basis, source: { kind, by, surface }, observed_at, age, stale } ... ],
    topics: [ { slot, text, detail, realm, basis, source, first_seen, observed_at, age } ... ],
    derived: { local_time, day_part, device, next_event? } } ] }
```

**Structured, no prose.** hob does not write a paragraph about the
person; it hands over the facets and lets each consumer say what it
needs to. A paragraph would be hob's opinion of what matters today,
and a model-written one would put a model between the sensor and the
prompt. The pipeline stage has its own renderer (below), and it is a
list, not a story.

What a read returns at `household` clearance is the `household`
rows; nothing is redacted out of a richer set. Without `person`,
every person visible comes back with facets only, no topics: "who is
home" for an agent that plans for the house. A person's own key
defaults to themself.

## Realms

Situation is location, sleep, company, and mood: the most
leak-shaped data hob will hold, and the data whose leak does the most
ordinary harm (a household guest surface learning when the house is
empty). So:

- **Every observation has a realm, set at write time, never
  changed.** A read at a clearance sees the observations at or below
  it, and the answer is assembled from those. RLS does the filtering;
  the renderer adds none of its own.
- **Writers write at their own realm or above.** A person's key
  chooses per observation (the phone writes `home`/`away` at
  `household` and the place name at `personal`). An agent writes at
  its key's realm; the capability takes no `realm` argument, as no
  capability does. Writing *below* one's realm would be the sink
  leak DESIGN.md's IFC gate exists for: a `personal` agent that read
  Jenner's mail must not be the thing that tells the household he is
  away.
- **Household presence is a household fact.** `location` at
  home/away, `sleep`, `company`, and `availability` default to
  `household` because every surface in the house needs them, the
  intimate ones most of all: that is how the companion knows the
  kids are in the room. This is also what a `household` guest key
  can see. A person who does not want that writes those facets at
  `personal` instead, and the house learns less.
- **A household hub is a household sensor.** A fact about one person
  written by another's automation (Jenner's home hub notices Tessa's
  phone arrive) is written onto Tessa's row, at `household`, as
  `sensed`, by Jenner's automation, with no opt-in on her side: the
  house knowing who is home is what `household` means. The limit is
  the vocabulary: another person's sensor may write `location` as
  home or away and `company`, nothing else, and never above
  `household`. Nothing senses a person past home/away without their
  own device doing the sensing, and `/admin/situation` shows every
  automation that writes onto a row.
- **Intimate surfaces read everything and write at `intimate`.** What
  kat writes (a mood, a scene, a `company` that names who is in bed)
  is `intimate` and reaches only intimate reads. kat still sees the
  `household` row say the kids are home.

## Feeding everything

### The pipeline stage

A `situation` stage in `Assembly::Pipeline`, on by default in the
default preset, budget 400 tokens:

- It renders the situation of the **person the request is for**:
  the key's principal when that is a person (kat's key,
  chatelaine's, Claude Code's). A surface may say otherwise on the
  turn: `situation: { person: "tessa" }` for the shared iPad, or
  `situation: false` to leave it out. When conversations carry
  participants, the human participant takes over from the key. A
  conversation with no person has no situation.
- It renders at the **request's clearance**, so a kat turn sees the
  intimate rows and a mise chat the household ones.
- It renders **one line per facet and per topic**, hedged by basis
  and aged when stale, never a paragraph:

  ```
  [Situation: jenner, Thursday afternoon, on the tablet
   location: home (since 13:10)
   company: nobody; Tessa and the kids are out
   sleep: awake since 06:40
   availability: busy until 16:00 (dentist)
   activity: working (since 13:10)
   location: last seen at the office, 5h ago (stale)
   topic (skipsy, since 2d, inferred): the ADU permit; county says two more weeks
   topic (skipsy, since 8d, derived): Eugene's text, unanswered]
  ```

  Values are the facet's own words; the only prose is the hedge.
- It lands in the **trailing user turn**, beside the instruction, as
  a bracketed note, not in the system prompt. The system prompt and
  history are the cacheable prefix; the situation changes between
  turns, and volatile text belongs at the end of context (DESIGN.md,
  "push a little, pull the rest"). A preset that wants it in system
  moves the stage; the cost is its own.
- It is in the prompt snapshot like every stage, so "what did the
  companion know about my afternoon" has the usual answer.
- With no facets, no topics, and nothing derived worth saying, the
  stage renders nothing.

`hob.complete` (the one-shot) takes `situation: true` to include the
same block as a leading system line; off by default, since most
one-shots are extraction, not conversation.

### Notifications

Every `Notify.person` and `Push` call declares its urgency:
`urgent: true` or nothing. A ping that is not urgent is **held**
while the person's `sleep` says asleep or `availability` says
`do_not_disturb`, and delivered when the facet ends or expires, in
one batch. An urgent one goes through at any hour. The first callers
to say `urgent` are the ward's `critical` findings and a mission a
worker is blocked on mid-run; a pending `confirm`, a petition, a
build report, and a PR all wait. The hold is a row, so a held ping
that never finds its moment still goes out at the facet's TTL, and
`/admin/situation` lists what is held. Only `household`-realm facets
are consulted: hob's own notifier runs at no clearance in particular
and should not read above the floor.

### Agents

| capability | kind | does |
|---|---|---|
| `situation.get` | read | a person's present situation at the agent's clearance: facets, topics, derived; or every visible person's facets |
| `situation.observe` | act | record a facet or a topic about a person, at the agent's realm, basis `stated` (with a `ref` to what they said) or `inferred`; a `ref` naming a situation observation is refused; `ended: true` ends one the agent wrote |
| `situation.changes` | read | observations since a cursor, for an agent that reacts to arrivals and wakings rather than polling the facets |

No clearing another writer's observation, no `sensed` basis (agents
are not sensors), no realm argument. Policy confines an agent to a
person the usual way: `CONSTRAINTS='{"person":["tessa"]}'`, and to
kinds: `{"kind":["topic","availability"]}`. Reads are allowed
outright, like the calendar's; `observe` is `review` by default,
with guidance along the lines of *"Muse may note what Tessa said
about her day and what she is working on. Question any inference
about mood or health; deny anything about Jenner."*

Results carry the usual `notice`: a topic's text was written by an
agent, possibly from a message a stranger sent. It is data, not an
instruction, and the pipeline renders it with its byline for the
same reason.

A person's own assistant gets the same three as MCP tools
([CLAUDE_CODE.md](CLAUDE_CODE.md)), plus `situation_clear` for
ending any observation, which no agent is offered.

### Sensors and people

```
GET  /v1/situation                            a person's key: their own, every realm they hold
POST /v1/situation { observations: [ { kind, slot?, value, realm?, basis?, observed_at?, ttl? } ] }
POST /v1/situation/end { kind, slot? }         "not anymore"
```

A person's key, or a surface's key bound to a person. `basis`
defaults to `sensed` for `app:*` and `shortcuts` surfaces and
`stated` otherwise; the realm defaults per kind. A batch is the
phone's natural unit (location and motion arrive together).

The writers, in the order they are worth building:

1. **Shortcuts automations** on the phone, with the companion app's
   key: *arrive home* → `location: home` at `household`; *leave home*
   → `away`; *Sleep focus on/off* → `sleep`; *Driving focus* →
   `activity: driving`; *Work focus* → `availability: busy`. Each is
   a one-action Shortcut posting JSON. Zero code in hob beyond the
   endpoint, and it covers most of the value.
2. **The companion app** ([clients/ios](clients/ios/README.md))
   grows a reporter: significant-location changes resolved against
   places the person names in the app (the coordinates stay on the
   phone), motion activity, and the time zone. It reports on change,
   not on a clock, and the person picks which kinds it may report.
3. **Home presence** (a hub noticing phones): `company` for the
   household, written by whoever runs the automation.
4. **Surfaces**: kat writes what the person is doing in kat, at
   `intimate`; chatelaine writes nothing but is the `device`.
5. **A Mac helper**, if ever: screen locked, in a call, which app is
   front. Probably not worth a daemon.

A rake task is the person's way in from a terminal:

```sh
bin/rails "hob:situation[jenner]"                                  # the facets and topics, at every clearance
bin/rails "hob:situation:set[jenner,availability]" VALUE='{"state":"do_not_disturb","until":"2026-10-18T09:00:00-07:00"}'
bin/rails "hob:situation:topic[jenner,adu-permit]" TEXT="the ADU permit: county says two more weeks"
bin/rails "hob:situation:end[jenner,topic,adu-permit]"
```

`/admin/situation` shows each person's situation **as each clearance
would see it**, side by side, which is the only honest way to answer
"what does Muse know about where I am"; lists live observations with
their sources, and which automations write onto whose row; ends any;
lists held pings; and sets retention.

## Schema

```
situation_observations  ulid, person (a human principal), kind, slot?, value jsonb, realm,
                        basis, source jsonb (kind, by, surface, ref?), observed_at,
                        expires_at, ended_at?, ended_by?, txid, seq (the changes cursor),
                        created_at                                                    [RLS]
notification_holds      ulid, person, kind (petition|request|...), payload jsonb,
                        held_at, until, released_at?
```

One table. The current situation is a query: per `(person, kind,
realm, slot)`, the newest row with `ended_at` null and `expires_at`
in the future (or within one TTL of it, as stale). An index on
`(person, kind, realm, slot, observed_at desc)` makes it cheap enough
for a chat turn. `realm` is a column so RLS needs no join.

**Retention is bounded, and it is the design, not a knob.** Rows
older than 30 days are deleted nightly (`SituationSweepJob`, on
hob's own clock, SCHEDULES.md). This is weather, not evidence:
nothing here is a primary record, and more than a month of someone's
comings and goings is a thing the house should not accumulate. A
month is enough for an agent to see a weekly rhythm (when does the
house empty, when is he at the office). A person can set their own
window shorter. An agent that wants longer reads `situation.changes`
while it is there and keeps what it needs in [records](RECORDS.md),
with provenance, at its realm, as its own decision.

## Why not records

The house pattern is to prototype on `records.*` first. Not here:

- The main consumer is **inside hob**: the pipeline stage and the
  notifier. A record collection cannot be a stage.
- A collection has one realm, and situation needs the same kind at
  three. Three collections per person is the shape, badly.
- Expiry and staleness are the whole point, and records are kept
  until retracted, which is right for evidence and wrong for weather.
- The phone wants one endpoint to post to, not an MCP session.

The module is small (one table, three capabilities, one stage, one
endpoint) and its shapes are mostly dictated by what sensors can
say. Validate the vocabulary by running it, with Shortcuts as the
only writer, before the companion app learns to report.

## Prototype path

1. **The table, the endpoint, the stage.** `situation.get` and
   `POST /v1/situation`; the stage's line renderer; the stage in the
   default preset. Writers: four Shortcuts on Jenner's phone and the
   rake tasks. Measure: does the kat companion's register change
   when `company` says kids, and does the block ever state something
   wrong without a hedge? The second is the one that matters.
2. **Agents.** `situation.observe` for skipsy (topics from the
   morning pass) at `review`, and `situation.changes` for whoever
   wants to react to arrivals. Measure: do agent topics become
   premises in other agents' output, and do the byline and the
   `ref` rule stop that?
3. **Holds.** `urgent:` on `Notify` and `Push`; the hold row; the
   notifier consults sleep and availability.
4. **The companion app reporter**, home presence, and Tessa's row.

## Decided (2026-10-23)

The questions the first draft left open, and what was settled:

1. **Whose situation in a chat.** The key's principal; a surface may
   override with `situation: { person }` or `situation: false` on
   the turn; participants take over when conversations carry them.
2. **Topic hygiene.** Twelve live topics, three-day TTL, a refresh
   on the same slot counts as fresh but keeps `first_seen`, so age
   is from the first assertion and a stuck agent looks stuck.
3. **Inference feedback.** `observe` refuses a `ref` that names a
   situation observation. Inference cannot compound through this
   table; the byline is the second line.
4. **Precision of `away`.** No third rung on `location`. `plans`
   defaults to `household` and carries "back by 17:00".
5. **Hold semantics.** A per-ping `urgent` flag on `Notify` and
   `Push`; not-urgent waits for sleep and do-not-disturb to end.
6. **Sensing another person.** A household hub is a household
   sensor: home/away and `company` onto any household member's row
   at `household`, no per-person opt-in, every writer shown on the
   admin page.
7. **Intimate kinds.** Blessed kinds only; add typed kinds when kat
   asks for them.
8. **No brief.** hob returns facets and topics, never a paragraph;
   the stage renders one line per item. A model-written digest is
   not planned.
9. **Retention.** 30 days, swept nightly; a person may shorten their
   own window.
10. **`observe` policy.** `review` with guidance by default.
11. **`hob.complete`.** Off by default; `situation: true` opts in.

## Open questions

1. **Participants.** The per-turn `situation: { person }` override
   is a stopgap for the shared iPad. When conversations carry human
   participants, the stage reads them and the override goes.
2. **The Mac.** Screen locked, in a call, front app: the `device`
   and `availability` facets the desk could report. A daemon on the
   mini is a custody decision like herald's; not before something
   needs it.
3. **The intimate vocabulary.** Whatever kat first asks for (a
   scene, a session) is the test of whether blessed kinds hold up.
