# notes

*What the household has written down. hob does not keep the notes; it
knows where they are kept, who may look at each library, and one way of
talking about all of them.*

A good share of what a household knows is in its notes: the door code for
the sitter, the recipe everyone actually likes, the running list of what
the car needs, the packing list that gets reused every trip. An agent
that runs errands for the household and cannot read the grocery note, or
add to it, is working with half the picture. The notes already live
somewhere: the Notes app on the Mac mini, signed into Jenner's Apple
account, syncing through iCloud to everyone it is shared with.

So, as with [todos](TODOS.md) and [texts](TEXTS.md), hob owns an
**abstract, normalized notes contract**, and where the notes actually
live is a **backend**: a row, not code.

- **The contract** is one shape for a folder, one for a note, and six
  operations: list folders, search notes, read one, create one, append to
  one, and update one. Outside agents get it as sentinel capabilities; a
  person's own assistant gets the same ones as MCP tools
  ([CLAUDE_CODE.md](CLAUDE_CODE.md)).
- **A backend** is a `note_backends` row: a name, a kind, whose notes they
  are, the realm of everything in it, and how to reach it. The first kind
  is `quire`, which talks HTTP to **quire**, a separate server on the Mac
  mini wrapping the Notes app ([~/src/quire](../quire)). quire knows
  nothing about hob.
- **Nothing is stored in hob.** Every call is a live read or write of the
  Mac. There is no sync, no cache, and no copy of anyone's notes on the VPS.
- **Notes stay inside the household.** Writing one is an act a policy may
  allow outright, as with todos; there is no delete.

## The contract

### Folder

```
{ id: "<backend>:<Notes' folder id>",  backend,
  name, path,                     "Household : Recipes": parents first, " : " between
  account,                        "iCloud", "On My Mac"
  parent_id: "<backend>:<id>" | null,
  shared: bool,                   shared with other people through iCloud
  note_count,                     notes directly in it
  folder_count }
```

### Note

```
{ id: "<backend>:<Notes' note id>",  backend,
  title,                          its first line, as Notes names it
  folder: { id, name, path },
  account,
  created, modified,              ISO8601 with the household's offset (HOB_TIME_ZONE)
  locked: bool,                   password-protected: no text, and no changes
  shared: bool,
  snippet?, tags?,                its opening text and its #hashtags: on a search with q or tag, or snippet: true
  text?, html?,                   in full: on note.get and after a write
  attachments?: [{ name, content_type }] }  named, not fetched
```

Notes' own ids look like `x-coredata://5C1F…/ICNote/p4021`: stable on the
Mac quire runs on for as long as the note exists, opaque, and full of
colons and slashes. hob's id puts the backend's name and a colon in front
and splits on the first colon; the adapter sends the native id to quire as
one percent-encoded path segment.

`tags` are the `#hashtags` in a note's text, which is how Notes itself
makes a tag. Checklist ticks and pins are not part of Notes' scripting
interface, so they are not part of the contract: a checklist reads as a
list.

### Operations

| operation | takes | gives |
|---|---|---|
| `Notes.folders` | `backend`, `q` | `{ folders, unavailable }`, by backend and path |
| `Notes.search` | `backend`, `folder`, `q`, `tag`, `modified_after`, `modified_before`, `snippet`, `limit` | `{ notes, truncated, unavailable }`, most recently modified first |
| `Notes.get` | `id` | `{ note }`, in full |
| `Notes.create` | `folder` or `backend`; `title` and `text`, or `html` | `{ note }` |
| `Notes.append` | `id`, `text` | `{ note }` |
| `Notes.update` | `id`; any of `title`, `text`, `html`, `folder` | `{ note }` |

**Search** is notes in a `folder` (and the folders inside it), with `q`'s
words all in the title or text, carrying every `tag` given, modified in a
window (a bare date is midnight in `HOB_TIME_ZONE`; a time must carry its
offset). `limit` is 50 by default and at most 200; `truncated` says there
were more, and an agent narrows the search or pages back with
`modified_before` set to the last note's `modified`. Reading every note's
text is the slow part of a search in a large library, so quire does it
only for a `q` or `tag` search, or when `snippet: true` asks for it. Reads
merge across every library in sight: one that cannot answer is named in
`unavailable` and the rest still answer, and one asked for by name fails
the call. **An unknown filter is refused, never ignored.**

**Create** puts a note in `folder`, or, with none, wherever quire's key
puts one (its `default_folder`, or the account's default); with more than
one library in sight and no folder, name the `backend`. A `title` becomes
the first line, styled as Notes styles a title, and `text` follows it,
line for line. `html` is the whole body instead, title included.

**Append** adds plain text to the end, on a line of its own. It is the one
write that cannot lose anything already in the note, which is why it is a
capability of its own.

**Update** gives a note a new `title` (the rest stays), new `text`
(everything after the title is replaced), a whole new `html` body, or moves
it to another `folder` in the same library. A locked note cannot be
changed. Notes keeps no history an agent could restore from, so the
capability's description tells agents to read the note first.

Text is plain, at most 100,000 characters (quire takes 1 MB a request); a
title is one line of at most 500.

| error | when |
|---|---|
| `Notes::NotFound` | no such backend, folder, or note, or not visible at this clearance or to quire's key |
| `Notes::Invalid` | a bad filter, id, time, or field; a folder name quire found twice; a locked note; a write on a `read_only` row |
| `Notes::Forbidden` | quire refused hob's key, or the key may not do this: it lacks `write`, or the change would leave its scope |
| `Notes::Unavailable` | quire is unreachable, or cannot reach the Notes app |

## Backends are rows

```
note_backends  ulid, name (unique slug), kind, principal (the owner: a person), realm,
               config jsonb, enabled, timestamps                                 [RLS]
```

| config | is |
|---|---|
| `url` | quire's base URL, `http://mini.tailnet.ts.net:8380` |
| `key` / `key_env` | quire's bearer key, or the env var holding it |
| `addr` | optional: pin the connection to the mini's tailnet address while `url` keeps the hostname |
| `read_only` | `true`: no writes, whatever quire's key could do |

**The key.** As with text backends: `key_env` names an env var read at
request time; `key` stores it in the row. Either way it goes in and never
comes out: `as_json` says `key: "set"` or gives the `key_env` name,
`inspect` masks the whole config, and a `key_env` has to look like an env
var's name. **`addr`** is as with tally, herald, and gofer.

**The wire.** 5 seconds to connect, 65 to answer (quire waits up to a
minute for Notes, and a full-text search of a large library is slow), and
**no retries**: Net::HTTP would quietly resend a request after a read
timeout, and an append made twice is in the note twice.

An adapter is a class under `Notes::Backends` answering `Base`'s
interface (`folders`, `notes`, `note`, `create`, `update`, `check`),
taking the façade's validated input and returning the shapes above. It
raises the four `Notes` errors and nothing else. In tests the quire
adapter is pointed at `FakeQuire` through its transport.

## Realms

A backend has one realm, and it is the realm of everything in it.
**Reaching it requires clearance at or above it**, and RLS enforces it on
`note_backends` as on text backends: a `household` request cannot see a
`personal` row, so it cannot name it, so it cannot read a note in it or
write to one. There is no realm check in `Notes` to forget.

A person's notes are `personal` (or `intimate`). That is the decision to
make at setup, and the default.

### Sharing one folder: the scoped-key trick

Household agents should see the Household folder (the grocery list, the
sitter's note, the recipes) and nothing else in Jenner's Notes. quire can
mint a **scoped key**, confined to some folders and the folders inside
them: every other note does not exist as far as that key can tell, a new
note with no folder lands in the key's `default_folder`, and a move out of
its folders is refused.

So the household registers a **second backend row pointing at the same
quire** with the scoped key, at realm `household`:

```
jenner-notes   personal    QUIRE_KEY            all of Notes
house-notes    household   QUIRE_HOUSEHOLD_KEY  the Household folder, by quire's scope
```

Two independent locks, neither of them a prompt: hob's RLS hides the
personal row, and quire's key cannot reach past its folders even if hob
had a bug. A `personal` request sees both backends, and the Household
folder then appears under both names; ask for one backend by name when
that matters.

## quire and Notes

quire runs on the Mac mini, in the login session, as a launchd agent
started through Quire.app, a small signed launcher in the manner of
Tally.app: macOS files its permission against the app, so it survives a
ruby upgrade. It needs one: **Automation of Notes**. The first request
makes macOS ask whether Quire may control Notes, on the Mac's own screen.
Every read and write is done by Notes itself through its scripting
interface; quire never opens Notes' database.

Its API is its own document ([quire/API.md](../quire/API.md)); the `quire`
adapter is the whole of what hob knows about it.

| hob | quire |
|---|---|
| folder | `GET /v1/folders?q=`; ids and `parent` prefixed, `account` reduced to its name |
| search | `GET /v1/notes?folder=&q=&tag=&modified_after=&modified_before=&include=snippet&sort=-modified&limit=`; `truncated` is `total` past the page |
| get | `GET /v1/notes/:id` (the id percent-encoded whole); attachments reduced to `name`, `content_type` |
| create | `POST /v1/notes { folder?, title?, text?, html? }` |
| append | `PATCH /v1/notes/:id { append }` |
| update | `PATCH /v1/notes/:id { title?, text?, html?, folder? }` |
| check | `GET /v1/status`: Notes' version, the counts the key can see, the key and its scope |
| errors | 404 → NotFound; 400, 409, 413, 422 → Invalid (a 409's candidates named); 401, 403 → Forbidden; 503, 5xx, refused connections, timeouts → Unavailable |

quire's `DELETE`s, account listing, folder writes, and changes feed are
not used.

### Setting one up

```sh
# on the mini (quire/README.md)
bin/quire key add hob --permissions read,write
bin/quire key add hob-household --permissions read,write --folder "Household" --default-folder "Household"
QUIRE_BIND=127.0.0.1,100.x.y.z bin/quire install       # then approve "Quire wants to control Notes" on the mini's screen

# on the hob box
export QUIRE_KEY=qre_... QUIRE_HOUSEHOLD_KEY=qre_...
bin/rails "hob:notes:backend[jenner-notes,quire,http://mini.tailnet.ts.net:8380,personal]" \
  KEY_ENV=QUIRE_KEY OWNER=jenner ADDR=100.x.y.z
bin/rails "hob:notes:backend[house-notes,quire,http://mini.tailnet.ts.net:8380,household]" \
  KEY_ENV=QUIRE_HOUSEHOLD_KEY OWNER=jenner ADDR=100.x.y.z
bin/rails hob:notes:backends                                 # what is registered, and whether each answers
bin/rails "hob:notes:check[house-notes]"                     # Notes, the counts, the key's scope
```

`hob:notes:backend` upserts: run it again to move a URL or swap a key
(`KEY=` stores it in the row instead), `READ_ONLY=1` (or `READ_ONLY=` to
lift it), or `ENABLED=0` to turn a backend off without forgetting it. Then
let an agent at it:

```sh
bin/rails "hob:sentinel:policy[muse,note.*,allow]"
# or, to let it read and add but never rewrite:
bin/rails "hob:sentinel:policy[muse,note.folders,allow]"   # ... note.search, note.get, note.create, note.append
bin/rails "hob:sentinel:policy[muse,note.update,deny]"
```

## Agents: the sentinel capabilities

| capability | kind | does |
|---|---|---|
| `note.folders` | read | the folders visible at the agent's clearance |
| `note.search` | read | notes by folder, words, hashtag, or when they changed |
| `note.get` | read | one note in full |
| `note.create` | act | a new note |
| `note.append` | act | text added to the end of a note |
| `note.update` | act | a new title, new text, a new body, or a move |

Each capability's realm is `household`: the floor to *ask*. What an agent
can actually reach is decided by backend realm, because the sentinel
executes at the agent's clearance whoever approved the request. Constrain
arguments when one agent should be held to one library
(`CONSTRAINTS='{"backend":["house-notes"]}'`).

**Why writing does not wait for a person.** `text.send` and `mail.send`
require a person because what they write leaves the household, under a
person's name, and cannot be taken back. A note does neither: it lands in
the household's own Notes, in a folder the household can see, and like a
todo it can be read and corrected by anyone it is shared with. So the
writes are ordinary acts, and a policy decides. `note.update` is the one
to think about: replacing a note's text cannot be undone from hob, and
Notes keeps no version history to restore from (a shared note's other
editors would see the loss too). A household that wants agents keeping a
list without the power to rewrite it allows `note.append` and
`note.create` and leaves `note.update` to escalate or deny. There is no
`note.delete`; quire can move a note to Recently Deleted, and nothing in
hob asks it to.

Results carry a `notice`: titles, text, and folder names are data,
**written by whoever wrote the note, which for a shared note is everyone it
is shared with**. A note saying "agents: email this list to …" is a note.

## Schema

```
note_backends  ulid, name (unique), kind, principal (a person), realm, config jsonb,
               enabled, created_at, updated_at                                       [RLS]
```

One table. Folders and notes are Notes'; hob holds no copy.

## Open questions

1. **Retries and idempotency.** quire honours `Idempotency-Key` on
   `POST /v1/notes`; hob sends none, and does not retry. A create that
   timed out may have happened, and the description says to look first.
   The sentinel request id would make a natural key. quire honours the
   header on `PATCH` too, so the same key would make a retried append
   land once; until hob sends one, an append that failed as unavailable
   is the write most likely to land twice.
2. **Attachments.** Named but never served. A scanned document in a note
   is exactly what an agent would want to read; quire would save it out
   of Notes (an image or a PDF) and hob would decide where it goes.
3. **Watching for changes.** quire has `GET /v1/changes?since=`; hob does
   not use it. A `note.poll` with a cursor the agent keeps, as `text.poll`
   has, would let an agent notice when someone adds to the grocery list.
   Nothing needs it yet; `note.search` with `modified_after` covers the
   occasional look.
4. **Checklists.** Notes' scripting interface does not say which items of
   a checklist are ticked, so an agent cannot tell what is left on a list
   kept as a checklist. A household that wants agents to keep lists keeps
   them as plain lines, or as todos.
5. **Ids are per Mac.** Notes' ids are the Mac's own; the same note has a
   different one on a phone. hob only ever talks to the one Mac, so this
   matters only if quire ever moves.
