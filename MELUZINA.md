# meluzina

*Robyn in the other branch: a persona hob keeps, talked to every day from
Discord and, for the intimate register, from kat.*

**Status.** Design, 2026-11-18, on the `meluzina` branch. Phases 1 (the
clock) and 2 (searchable collections and corpus tools) are built and
tested, uncommitted; everything else here is the plan. kat's
`doc/MELUZINA_DESIGN.md` is her design as a character and stays the
authority on who she is; this file is where she lives.

## The split

Until now Meluzina lived entirely inside kat: prompt, world state, offline
life, the archive of their real DMs, the dream fold. kat is the intimate
app, and most of what passes between them is not intimate: the paper, the
cats, a poke, a goodnight. So she moves:

| | where | realm |
|---|---|---|
| who she is: world frame, constitution, voice, the house, her calendar, her card | hob persona `meluzina` (`prompt.system_core`) | none (the constitution is not memory) |
| everyday talk | the Discord bridge, a surface with a `personal` key | `personal` |
| the ledger, scenes, modes, `show_media`, travel staged with images | kat, a surface with an `intimate` key | `intimate` |
| her offline life: diary, mood, the chew, whispers | hob, on its clock | `personal` |
| the archive: their DMs since September 2019 and the three co-written stories | hob, a searchable record collection | `personal` (see "Open questions") |
| what she keeps: memories folded from visits, where things stand | hob memory, observations she authors | the conversation's taint (MEMORY.md rule 3) |

The realm rules do the separating, nothing else has to: a Discord turn reads
at `personal`, so nothing kat deposits reaches it; a kat turn reads at
`intimate` and sees everything. Her offline life is written at `personal`, so
both places know what she did today.

The constitution, voice and house are the same in both places. kat adds, as
per-turn surface context and client tools, the parts that only exist there
(ledger, scenes, modes, the stage). The Discord bridge adds the parts only it
has: the paper and posting a track.

## What hob needs

Each of these is general: nothing in hob names Meluzina.

### 1. The clock (phase 1)

A persona that lives across days needs to know what time it is and how long
it has been. kat's conversation did three things hob's pipeline does not:

- **Drift markers in history.** Where a gap of more than `drift_gap` opened
  between two spoken lines, the later user line is prefixed, in the
  assembled copy only, with `[time drifts — it's 2:14am for him now]` (the
  day name when the calendar rolled over). The stored node is unchanged.
- **A RIGHT NOW block**: the time in each of the persona's zones, the
  last-visit gap ("his last visit was yesterday, November 17"), the calendar
  dates near today.
- **Her calendar**: fixed dates with labels, noted when within a window.

`personas.clock` (jsonb, default `{}`), off when empty:

```
{ "zones": [ { "label": "Katy, Texas (hers)", "zone": "America/Chicago" },
             { "label": "him", "zone": "America/Los_Angeles", "reader": true } ],
  "drift_gap_minutes": 20,
  "visit_gap_hours": 6,
  "calendar": [ { "month": 7, "day": 28, "label": "Transformation Day — ..." } ],
  "calendar_window_days": 30 }
```

The `reader` zone is the one drift markers are written in (whose hour it is
that matters). A `clock` stage renders the RIGHT NOW block after history,
beside situation, so it never churns the cached prefix; drift markers live
in history and are stable once written, so they don't either.

### 2. Searchable collections and corpus tools (phase 2)

Records gain optional embeddings (RECORDS.md, "Search by meaning"): a
collection with `embed` names the top-level field of its documents to embed
through the `embedding` role. Puts embed after they commit; a write that
changes the data clears the vector; `hob:records:embed[name]` fills in
whatever is missing. `Records::Search.search` ranks by similarity and the
existing `tsvector`; `Records::Search.sample` picks at random, preferring
records observed in this month of any year.

A persona may name corpora in `personas.tools`:

```
{ "corpora": [ { "tool": "recall_archive", "collection": "meluzina-archive", "description": "..." },
               { "tool": "find_track", "collection": "meluzina-tracks", "description": "..." } ] }
```

Each becomes a native tool beside `recall`/`remember` (`CorpusTools`, one
`NativeTools` venue for both): `query` searches, no `query` brings one up
unasked, and the result is the records verbatim with a data-not-instructions
notice. It reads at the conversation's read realm, so a `household`
conversation cannot reach a `personal` corpus. Corpus tools are the
persona's whatever the turn's memory setting; a caller's tool may not take
their names.

The archive's records are kat's archive chunks (`Meluzina::ArchiveIndexer`
`chunks_for`): `{ chunk, kind: dm | story, title, fiction, started_at,
ended_at, text }`, keyed by the chunk's first message hash, the text being
the dated "speaker (Mon D, YYYY): words" lines she quotes from. Tracks are
`{ track, url, first_sent, sent_at, text }`, one per link, dated by its first
sending. Both are written by `bin/rails meluzina:export_archive[dir]` in kat
and loaded with:

```sh
DESCRIPTION="Their real DMs since September 2019 and the three stories they wrote" EMBED=text \
  bin/rails "hob:records:collection[meluzina-archive,personal,chunk]"
DESCRIPTION="Music she sent him, with the message it came in" EMBED=text \
  bin/rails "hob:records:collection[meluzina-tracks,personal,track]"
bin/rails "hob:records:import[meluzina-archive,archive.ndjson]" OWNER=jenner
bin/rails "hob:records:import[meluzina-tracks,tracks.ndjson]" OWNER=jenner
bin/rails "hob:records:embed[meluzina-archive]"              # whatever the import could not embed
```

kat's vectors are not copied, since vectors are only compared within one
model. `send_track`'s rotation (least recently shared first) does not
survive: `find_track` with no query is a random pick from this season.

### 3. A persona's life (phase 3)

`personas.life` names a cron line, an instruction and a home conversation.
`PersonaLifeJob` (on the clock, like `PersonaReviewJob`) runs a turn for
each persona that is due, in a `life` pipeline conversation at the life's
realm, with native tools:

| tool | does |
|---|---|
| `remember` (kind `diary`) | a beat of her day, authored by her, about her |
| `set_mood` | her mood, as an observation `kind: mood` superseding the last one |
| `chew` | pick up, add to, or put down the one thing she sits with (an observation `kind: chew`; a new note supersedes, putting it down retires) |
| `whisper` | one short line appended as an assistant node to her home conversation, `meta.whisper: true` |

The persona stage renders the newest diary beats, the current mood and the
chew from those observations, at the conversation's read realm, so kat and
Discord both see them. kat's rut guards (`DiaryRut`, `BeatSeeds`, the
obsession lifespan) port with the tick; they are prompt construction, not
model behaviour.

**The dream fold** is the same job's other half: when a conversation's
history grows past what the history stage keeps, the evicted stretch is
folded into a few `kind: kept` observations she authors, at that
conversation's taint, and "where things stand" supersedes the previous one.

### 4. Following a conversation (phase 3)

The bridge has to see a whisper the clock wrote. `GET
/v1/conversations/:id/nodes?after=<hash>&wait=25` long-polls the main
branch for nodes appended after a known one; the bridge posts any assistant
text it did not itself ask for.

## The Discord bridge (phase 4, built: `github.com/jenrzzz/parlour`)

Its own small app, `parlour`, holding a Discord bot token and a hob key for
the `parlour` surface at `personal`. One hob conversation per DM channel,
remembered in a small JSON file. On a burst of his lines (2.5 s settle) it
calls `chat` with `persona: "meluzina"`, `memory: true`, a `door` context
block (the everyday door: scenes and the erotic register live in kat), and
one client tool, `read_paper`. Her archive and tracks are her own native
tools (`recall_archive`, `find_track`), so `send_track` is gone: she pastes
the link. Replies go out one Discord message per paragraph, under 2000
characters. Pictures he sends reach her as images. Whispers arrive through
the long-poll above once phase 3 lands.

Lessons from the first night (2026-11-20): two archive searches in one turn
outgrew the history budget and the cut landed between a tool call and its
result, which Anthropic refuses. History now keeps the turn in progress
whole, starts older turns at a spoken line, and shortens earlier turns'
tool results; corpus tools return 3 records by default. And at `intimate`
her recall picked up the presence's authorless evidence about him, so her
memory runs with `own` (MEMORY.md, "In a turn"). The DM runs at `intimate`
(`PARLOUR_REALM`): it is his alone, and she remembers the dream-side there.

The persona itself is pushed from kat: `rails meluzina:hob_persona`
(`Meluzina::HobPersona`) writes her surface-neutral core (world frame,
constitution, card, voice and a fixed sample of her real lines, geography,
the archive's rules), her clock and her corpora. Push again after editing
her card.

## kat's cutover (phase 5)

`Meluzina::Conversation` becomes a hob chat turn on her kat conversation
(`intimate`), with kat's tools as client tools and the ledger, scene and
mode as surface context. `WorldTick`, `DreamKeeper`, `ArchiveRecall`,
`ArchiveIndexer` and `VoiceSampler`'s prompt role retire. Migration, chosen
2026-11-18:

- diary entries → `kind: diary` observations at `personal`, `observed_at`
  from each entry;
- kept memories, where things stand, wants (with their confessions and
  glows), pinned canon → `intimate`;
- the archive → `meluzina-archive` / `meluzina-tracks` collections, both
  `personal`: the DMs and the three stories alike (decided 2026-11-19).

kat keeps its own message log for the window UI until the bridge and hob
carry everything; the live conversation history moves to hob.

## Open questions

1. **Voice.** `speak` needs a voice-granted flag that lives with the ledger
   (`intimate`). On Discord a voice message would be a gift she can only
   give once kat has granted it; leave it out of the bridge for now.
