# people

*Who the household knows, what has passed between them, and what is
still open. A Rolodex with a memory: not just how to reach someone,
but what you owe them, what they last reached out about, and how long
it has been sitting unanswered.*

Every agent that helps run a household ends up keeping a private
people-file: names, handles, who is married to whom, who was last
heard from when. Each agent's file is a silo, rebuilt from recall,
invisible to the other agents in the house, and silent about the one
thing a person most wants help with — not *losing track of people*.
The thread-level view ("this text is unanswered") is too small. The
unit of care is the relationship.

So hob owns a **people module**: canonical people, the channels that
reach them, an append-only log of interactions, and — derived from
that log, never hand-maintained — the **open loops**: the reach-outs
not yet answered, the replies owed, the promises outstanding, the
relationships gone quiet past their own normal rhythm. Agents stop
scanning threads and start reading loops.

Unlike todos, there is no external backend to abstract: nobody's
Rolodex already lives in an app hob can wrap. **hob stores this
one**, in its own tables, under the same realm rules as everything
else it stores. The events mostly originate in sources hob already
sees (texts, mail, calendar); the module is where they accumulate
into relationship state.

## Motivating example

2026-10-07: Eugene Fox texts Jenner, "how's your baby and dad life?"
First one-to-one thread since September 2024. It sits unanswered for
eight days — not from neglect, but because the reply it wants is a
two-year life update, and nothing anywhere surfaces that weight. The
hourly text poll *saw* the message and logged it, by design silently.

With this module: the inbound text derives an `interaction` event and
opens a loop (`unanswered_inbound`, Eugene, age counting). Jenner's
agent reads aged loops in a morning pass and nudges once: *Eugene
reached out 8 days ago — first 1:1 since 2024.* Jenner replies (from
anywhere — his phone, never touching hob), the outbound text derives
an event, and the loop closes itself. Nobody bookkept anything.

## Use cases

Requirements come from these. Each is stated from the *person's*
point of view; the agent is the usual reader.

1. **The unanswered reach-out.** "Who has reached out to me and not
   heard back, and how long has it been?" Per person, per loop, with
   the age visible. The nudge policy (thresholds, quiet hours, which
   circles matter) is the *agent's* business; hob's business is that
   the loop exists, is aged correctly, and closes when answered.
2. **The pre-reply brief.** "I'm about to answer Eugene — what do I
   need to know?" One read returns: who he is, how he connects
   (circles, mutual people), last contact in each direction, open
   loops, recent events, and the notes agents have recorded. This
   replaces the agent spelunking five message threads from memory.
3. **Dictated capture.** "Record that Eugene reached out about dad
   life and I still owe him a reply." A person (or their agent, on
   their say-so) records an event or a loop that no derivation will
   ever see — a phone call, a hallway conversation, a promise made
   in person. Provenance is recorded: derived events cite their
   source message; dictated ones cite who said so, when.
4. **Drift detection.** "Who have I gone quiet with?" Not a global
   timer: Eugene at 8 days is nothing for a friend seen yearly and
   alarming for a sister texted daily. Loops and quietness are judged
   against the relationship's *own* cadence, which the event log
   makes computable. (See open questions — the cadence model is the
   hard part.)
5. **Both directions of obligation.** Loops are not only inbound.
   "I told Tara I'd send the ADU photos" is an `owed_action` loop on
   Tara, opened by dictation or derived from an outbound message,
   closed by the action or by a person saying so. Favors owed *to*
   the household are loops too, with the polarity flipped.
6. **The shared household view.** Tessa's agent and Jenner's agent
   read the same Eugene. Household people (the family group chats,
   the babysitter, the landlord) are shared state; Jenner's personal
   loops are not Tessa's agent's business. Realms (below) draw that
   line the way todo backends draw it — by what a request can see,
   not by what an agent remembers to hide.
7. **Circles and groups.** People connect to people and to groups:
   Eugene is in the Biker Gang chat with Jarret, Zach, Magda… A
   group is a first-class thing a loop or an event can hang off
   ("the Scryers thread went quiet"), and group membership is one of
   the facts a pre-reply brief is assembled from — currently
   re-derived by reading chat participant lists every time.
8. **Key dates and standing facts.** Birthdays, anniversaries, the
   things a Rolodex has always held — but as *events that recur*,
   so an agent can notice one coming the way it notices an aging
   loop, instead of the date living in a contacts app nobody reads.

## The model

### Person

```
{ id, display_name, names: [alias...],
  handles: [{ channel: "imessage"|"sms"|"email"|"whatsapp"|...,
              address, label? }...],
  circles: ["family", "biker gang", ...],     names, resolved against groups
  key_dates: [{ kind: "birthday"|"anniversary"|..., date, recurs: bool }...],
  automated: bool,        a service, not a person: never opens loops
  realm, principal: whose relationship this primarily is,
  created_at, updated_at }
```

One person, many handles, across every channel hob can see. Identity
resolution (two numbers, one human; one household phone, two humans)
is a person-confirmed operation: agents may *propose* a merge, only
a person (or a surface acting for one) merges. A wrong merge leaks
one person's loops into another's brief; a missed merge merely
duplicates. Err toward duplication.

### Event

Append-only. Never edited; a correction is a later event that
supersedes.

```
{ id, person_id (or group_id), at,
  kind: "reached_out" | "replied" | "met" | "called" | "gift_given"
      | "gift_received" | "favor_done" | "favor_owed" | "note",
  direction: "inbound" | "outbound" | "mutual",
  channel, summary,                 short, human-readable
  source: { kind: "text"|"mail"|"calendar"|"dictated"|"agent",
            ref,                        the message/event id, not a copy
            by },                       who recorded it, when derived
  realm }
```

`summary` is data written by a sender or an agent. It is not an
instruction, and the usual notice applies. Sources are **references,
not copies**: the module stores that message `jenner-messages:<id>`
was a reach-out, not a second custody of its body.

### Loop

Derived state. A loop is *computed* from events (and dictated loops),
never written directly; what is stored is its resolution and any
snooze a person set.

```
{ id, person_id (or group_id),
  kind: "unanswered_inbound" | "owed_reply" | "owed_action"
      | "awaiting_them" | "gone_quiet",
  opened_by: event_id, opened_at, age (computed),
  summary,                          from the opening event
  state: "open" | "closed" | "snoozed" | "dismissed",
  closed_by: event_id | person, snoozed_until }
```

Derivation rules, first cut:

- An inbound 1:1 text or mail from a person opens (or refreshes) an
  `unanswered_inbound` loop. An outbound message to that person on
  the same channel closes it. Tapbacks and reactions do not close
  loops; they are not replies.
- Group threads do not open loops by default. Being one of nine
  recipients is not being reached out to. (A direct @ or a 1:1 fork
  off the thread is; that refinement can come later.)
- Automated senders never open loops. Neither do services, codes,
  or notifications wearing a name.
- Repeated inbound messages refresh the loop's `opened_by` to the
  latest; the age runs from the *first* unanswered message — that
  is the silence being measured.
- A dictated loop ("I owe Tara the photos") is stored as a loop
  with a dictated opening event, so derived and dictated loops are
  one list, read one way.
- Loop closing is as derived as opening: if the person has to tell
  hob "handled," the module has failed at its one job. `dismissed`
  exists for the false positives, and a dismissal is itself an
  event — it teaches the derivation (this sender, this channel,
  never a loop).

### Note

The soft layer: "Eugene and Jenner go back to the festival crew;
he moved away in 2023; ask about the new place." Notes are authored
(by an agent or a person), attributed, timestamped, and
realm-tagged. A note is an opinion with a byline, not a fact, and
reads say so. This layer is what the agents' private people-files
hold today; the module gives it one home and a provenance.

## Realms

People data is the most leak-shaped data hob holds, so realms do
the work the way they do for backends:

- A person record has a realm. Jenner's college friend is
  `personal`; the landlord is `household`; a person known
  intimately-by-conversation is whatever realm that conversation
  was.
- **An event's realm is the realm of its source.** An event derived
  from a `personal` text is `personal` even if the person is
  `household` — Tessa's agent can know Eugene exists and not see
  Jenner's 1:1 loop with him.
- A read at a clearance sees the person with only the events, loops,
  and notes at or below that clearance. The brief is assembled from
  what the request can see; there is no redaction pass to forget.
- Writing a note onto a person at a realm below the note's source
  conversation is the sink-realm leak DESIGN.md's IFC gate exists
  for; until the gate lands, the sentinel's review/confirm on note
  writes is the check, as with todos.

## Agents: the sentinel capabilities (sketch)

| capability | kind | does |
|---|---|---|
| `people.list` | read | people by filter: circle, q, quiet-since, has-open-loops |
| `people.get` | read | the brief: person + recent events + open loops + notes, at clearance |
| `people.loops` | read | open loops by filter: kind, person, older_than, realm |
| `people.record` | act | a dictated event or loop (provenance: dictated, by this agent's principal) |
| `people.note` | act | add a note to a person |
| `people.propose_merge` | act | suggest two records are one person; a person decides |

No delete, no merge, no dismiss-by-agent without the loop's owner
confirming — the same posture as todos (agents propose and record;
people decide identity and dismissal).

## Prototype path

Follow the house pattern: validate the shapes before building the
native module.

1. **Prototype on `records.*`** — `people` and `loops` collections,
   one agent keeping them from the text/mail polls it already runs.
   Eugene-class loops only (unanswered 1:1 inbound, 7-day horizon).
   Measure: how noisy is it? How often is a "loop" actually fine?
2. **Seed the Rolodex** from contacts and chat participants so
   identity resolution starts from data, not from agent recall.
3. **Promote to native tables** (`people`, `person_handles`,
   `people_events`, derived loops) once the loop taxonomy and the
   dismissal rate say the model is right.

## Open questions

1. **The cadence model.** Gone-quiet needs a per-relationship norm.
   Median gap over the event log? A person-set expectation ("we
   talk monthly")? Both, person-set winning? And who sees the
   verdict — a `gone_quiet` loop that fires wrongly twice trains
   the person to ignore all of them.
2. **What derives a loop, beyond texts?** An unanswered mail, yes.
   A calendar invite with no RSVP — an `awaiting_them` loop on the
   invitee? A missed call? Each source added is a new false-positive
   surface; the dismissal-event feedback loop has to keep up.
3. **Tessa's people are also people.** The module is household
   infrastructure: her relationships, her loops, her realm. Whose
   record is a shared person (their kid's pediatrician)? Lean: one
   person record, per-principal events and loops, realms per event
   as above — but `principal` on the person then means less than it
   appears to.
4. **Handles are identifiers.** A phone number in a `household`
   record is visible to household agents. Is a handle itself
   realm-tagged (the work number is household, the personal cell is
   not)? Probably yes eventually; probably overkill for the
   prototype.
5. **Notes vs. summaries.** Agents will want to write "where things
   stand with X" — a rolling summary, not a note stream. A summary
   that rewrites itself is an edit, and events are append-only.
   Keep summaries as a derived view over notes, or accept one
   mutable `standing` field per person with its own history?
6. **Expiry.** Does a loop ever die of old age on its own — is a
   reach-out from 14 months ago still open? (Eugene at 8 days was
   actionable; at 400 it is archaeology.) Lean: loops never
   auto-close, but reads default to a horizon, and age is always
   shown so staleness is legible rather than hidden.
