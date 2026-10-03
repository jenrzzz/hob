# records

*What the household's agents found out and want to keep. hob does keep
these: they have no other home.*

[Budgets](BUDGET.md) and [todos](TODOS.md) store nothing in hob, because
somewhere else already keeps them and a second copy only drifts. Some
things an agent learns have no such somewhere. Muse reads Amazon's order
history through gofer to match orders against the Prime Visa in YNAB; the
match lands in YNAB as a memo and a category, and the order itself (the
items, the shipments, what was returned) is thrown away. Amazon is not the
household's record of it: pages change, history gets trimmed, access goes.
What an agent scraped is **evidence**, and evidence wants keeping.

So hob owns a **record store**: named collections of structured documents,
each with a key, a realm, and the provenance of every version.

- **A collection is a row**: a name, an owner, a realm, where its
  documents' keys are, and optionally a JSON Schema they must meet. An
  agent can ask for one, and ask for one gone, but a person says yes
  every time.
- **A record is a JSON document** in one collection, found by its key
  (`order_id`), never rewritten in place. Every change is a new version
  saying who wrote it, through what, from where, and when.
- **Agents get it as sentinel capabilities**; a person's own assistant
  gets the same ones as MCP tools ([CLAUDE_CODE.md](CLAUDE_CODE.md)).

**What does not go here.** Records are primary records, not mirrors. A
collection of YNAB transactions or OmniFocus todos would be the copy
BUDGET.md refuses to keep, by another door; refer to them instead (below).
Records are not memory either: an observation is a fact about an entity,
written for recall ([DESIGN.md](DESIGN.md), plane 3), and a record is a
document written for lookup. Extraction may one day read records and
distill observations from them ("bought a car seat, August 2026, 289.00"),
the way it reads conversations.

## The contract

### Record

```
{ id: "rec:amazon-orders:113-4567890-1234567",
  collection: "amazon-orders",
  key: "113-4567890-1234567",
  data: { order_id: "113-...", placed_on: "2026-09-14", total: 64.18,
          items: [{ title, asin, quantity, price }], shipments: [...] },
  links: ["budget:house-ynab:7f3c...", "todo:omnifocus:hM2x..."],
  version: 3,
  schema_version: 2,                       the collection's schema it was written under
  observed_at: "2026-09-20T17:04:00Z",     when the writer saw it this way
  source: "https://www.amazon.com/gp/your-account/order-details?orderID=113-...",
  written_by: { agent: "muse", surface: "gofer" },
  created_at, updated_at }
```

`data` is whatever the collection's schema says, at most 64 KB. `links`
are refs (below) to the things this record is about. `source` is where
the writer read it, if anywhere; `observed_at` defaults to the write's
time and is the writer's to set when it is reporting something older.

### Collection

```
{ name: "amazon-orders", realm: "household", owner: "jenner",
  key: "order_id",                         a top-level field of data
  schema: { ...JSON Schema... } | null,
  schema_version: 2,                       up by one with every schema change
  description: "Amazon orders as Muse read them, for matching the Prime Visa",
  count, updated_at }
```

The key is a field of the document, not an argument beside it, so the
same order written twice is the same record. It is a string or an
integer, and once a collection holds records its key does not change.

### Refs

A ref names one thing anywhere in the household, as a string: what kind
of thing, then the id it already has.

| ref | names |
|---|---|
| `rec:<collection>:<key>` | a record |
| `budget:<backend>:<id>` | a budget transaction, account, or category (BUDGET.md's id, prefixed) |
| `todo:<backend>:<id>` | a todo or list |
| `mise:recipe:<id>`, `mise:meal:<id>` | mise's things |
| `board:<thread id>` | a board thread |
| `mission:<ulid>` | a mission |

That is the whole of hob's "global id": a convention for writing down
what an id already is, so a record can point at a YNAB transaction
without a table that knows every id in the household. hob checks a ref's
shape (a known prefix, then something) and nothing more; it does not
check that the thing exists, which would cost a YNAB request per link.
Resolving refs in general (`hob.resolve`) is an open question.

### Operations

| operation | takes | gives |
|---|---|---|
| `Records.collections` | | the collections visible at this clearance |
| `Records.put` | `collection`, `data`; optional `links`, `source`, `observed_at`, `if_version` | `{ record, changed }` |
| `Records.put_many` | `collection`, `records: [{ data, links?, source?, observed_at? }]` (100 at most) | `{ records, changed, unchanged }` |
| `Records.get` | `collection`, `key`; optional `version` | a record |
| `Records.query` | `collection`, and the filters below | `{ records, matched, truncated }` |
| `Records.history` | `collection`, `key` | every version, newest first |
| `Records.changes` | `collection`; optional `since` (a cursor), `limit` | `{ changes: [{ key, version, at }], next_since }` |

**A put is an upsert by key, and a put that changes nothing is nothing.**
If `data` and `links` equal the current version's, no version is written
and `changed` is false; only `observed_at` on the current version moves,
so "Muse saw this order unchanged on the 20th" is still known. An agent
can re-read the whole order history every week without filling the
history with copies, and a retried put is safe: there is no idempotency
key to forget, because the key is the document's own.

`put_many` is all or nothing: one invalid document refuses the batch,
naming it. `links` given on a put replace the set; to keep them, send
them again (the agent has just read the record to know they exist).

| query filter | means |
|---|---|
| `match` | an object the document must contain: `{ "items": [{ "asin": "B0..." }] }` (Postgres `@>`) |
| `linked` | a ref the record must link to: which order is this YNAB transaction? |
| `q` | words that must all appear in the document's text |
| `observed_after`, `observed_before`, `updated_after` | times |
| `sort` | `updated` (the default, newest first), `observed`, `key`, or a top-level field of `data`; `-` reverses |
| `limit` | default 50, at most 500 |

An unknown filter is refused, never ignored, as everywhere else.

### Making and removing

| operation | takes | gives |
|---|---|---|
| `Records.create_collection` | `name`, `key`, `description`; optional `schema`, `realm` (the agent's own by default) | a collection |
| `Records.update_collection` | `collection`, `reason`, and any of `schema` (null drops it), `description` | a collection, with its new `schema_version` |
| `Records.delete` | `collection`, `key`, `reason` | `{ record }`, retracted |
| `Records.delete_collection` | `collection`, `reason` | `{ collection, records }`, retracted, with how many records went with it |

These are the four operations that decide what the household keeps, and
**a person confirms every one** (below). An agent proposes a collection
with the schema it means to write; the person deciding sees the name, the
realm, the key, the schema, and the agent's reason, and the collection's
owner is that person, not the agent.

**A schema change is a new schema version.** A collection's
`schema_version` starts at 1 and goes up with every change to its schema,
and every record version carries the `schema_version` it was written
under, so a reader can tell an order written before `shipments` existed
from one written after. The new schema applies to writes from then on;
records already there are not rewritten or re-checked. The person
deciding sees the old and new schemas side by side, and how many current
records the new one would refuse (what `hob:records:check` reports). An
agent that wants old records in the new shape re-reads and puts them
again once the change is confirmed: they are its writes to make, with
provenance, not hob's to transform.

`name`, `key`, and `realm` do not change. A name is in every ref to the
collection's records, and the key is what makes them the same records.
A realm is who may see everything in the collection; moving it down is
declassification, which DESIGN.md keeps a human act start to finish, and
moving it up hides records from readers who already hold copies. A
collection in the wrong realm is a new collection and a delete of the old
one, both confirmed.

**Delete is retraction.** A deleted record gets a tombstone version and
stops answering `get`, `query`, and `changes` (where it appears once, as
`retracted: true`, so a reader's copy can drop it). A deleted collection
takes all its records with it the same way, and its name is not free
again until it is purged. Nothing is gone: the versions and their
provenance stay, and `/admin/records` restores a record or a collection
with one click. Only a person, in `/admin/records`, **purges**, which
removes the rows for good; an agent cannot ask for that at all. A
mistaken confirmation costs a click, not the evidence.

A record that is merely wrong is not deleted: it is put again, corrected,
and its history keeps what it was.

### Concurrency: versions, not locks

Two runs of an agent, or two agents, may write the same record. The
default is last write wins, which for evidence is usually right: both
saw the order, the later look is the better one. When a writer read a
record, changed it, and needs nothing to have changed in between, it puts
with `if_version`, and a put against a newer version is refused with the
current record (`Records::Conflict`). It reads again and decides.

hob does not hand out locks. Postgres advisory locks live as long as a
database session, and an agent's session with hob is an HTTP request: a
lock would end with the request that took it, or be held by a request
that never came back. Work that must happen once at a time is a
[mission](MUSE.md), whose lease already expires when its worker
disappears. A general named lease (`hob.lease`) is an open question.

### Changes: a cursor, not a subscription

Agents cannot be pushed to (MUSE.md, "Listening for missions"), so a
subscription is a poll that is cheap to repeat. `Records.changes` answers
with every key changed since a cursor and a `next_since` to ask with next
time, oldest first, the way `hob.board.read` does. The cursor is opaque
and stays good for 30 days. fineass, a digest job, or an extraction run
keeps its cursor and reads only what moved.

A collection may name an ntfy channel to post on when it changes, as a
wake-up and never as the feed itself; not before something needs it.

## Collections are rows

```
record_collections  ulid, name (unique slug), principal (the owner: a person), realm,
                    key_path, schema jsonb, schema_version, description, notify jsonb,
                    proposed_by (an agent, or null), sentinel_request_id,
                    retracted_at, retracted_by, timestamps                         [RLS]
records             ulid, collection_id, key, version, data jsonb, links text[],
                    observed_at, source, retracted, timestamps                     [RLS]
record_versions     ulid, record_id, version, schema_version, data jsonb, links text[],
                    observed_at, source, principal (the writer), surface, sentinel_request_id,
                    mission_id, retracted, created_at                              [RLS]
```

`records` holds the current version, unique on `(collection_id, key)`;
`record_versions` holds all of them, the current one included. Both carry
the collection's realm as a column, so RLS filters them without a join.
`data` gets a GIN index for `match`, `links` one for `linked`, and a
generated `tsvector` for `q`. Every version's provenance comes from the
request, never from the arguments: an agent cannot say someone else wrote
it.

```sh
bin/rails "hob:records:collection[amazon-orders,household,order_id]" \
  OWNER=jenner SCHEMA=config/records/amazon-orders.json \
  DESCRIPTION="Amazon orders as Muse read them, for matching the Prime Visa"
bin/rails hob:records:collections                        # what exists, how many records, last write
```

The rake task is the person's way in; `records.collection.create` and
`records.collection.update` are the agent's, and both make the same rows.
Running it again updates the description or the schema, with the same new
`schema_version` an agent's update gets. `hob:records:check[amazon-orders]`
lists the current records the schema would now refuse.

## Realms

A collection has one realm, and it is the realm of every record in it,
exactly as a budget backend's is. A `household` request cannot see a
`personal` collection's row, so it cannot name it, so it cannot read or
write a record in it. The choice is made at setup: the household's Amazon
account is `household`, and a gift someone ordered for someone else in the
same household is a reason for a second, `personal` collection, not a
reason to hide records one at a time.

The realm is also the sink realm of a put. Muse reading a `personal`
budget and writing what she found into a `household` collection is the
leak the IFC gate exists to stop (DESIGN.md, "tool sinks"); as with todos
and budgets, nothing checks it yet.

## Agents: the sentinel capabilities

| capability | kind | does |
|---|---|---|
| `records.collections` | read | the collections the agent can see, with their schemas |
| `records.get` | read | one record, or one version of it |
| `records.query` | read | records in a collection, filtered |
| `records.history` | read | every version of one record and who wrote it |
| `records.changes` | read | what changed since a cursor |
| `records.put` | act | write one record |
| `records.put_many` | act | write up to 100, all or nothing |
| `records.collection.create` | act | propose a new collection; a person confirms |
| `records.collection.update` | act | change a collection's schema or description; a person confirms |
| `records.delete` | act | retract one record; a person confirms |
| `records.collection.delete` | act | retract a collection and everything in it; a person confirms |

**The last four are `confirm` or nothing.** They ship marked
`requires_person`, and `hob:sentinel:policy` and `/admin/grants` refuse
`allow` or `review` for them, for any agent and under any glob: a `*`
rule that allows everything leaves them at `confirm`. A pending request
pings the household's ntfy topic and the companion app (SENTINEL.md, open
question 1) and is decided in `/admin/sentinel`, where a collection
proposal shows its schema, a schema change shows the old one beside the
new and the records it would refuse, and a delete shows the record, or the
collection's record count and newest write. An agent waits on it like any
`pending` request (MUSE.md, "Waiting"); a collection it needs mid-mission
is worth asking for first, before the scraping starts.

Policy can confine an agent to some collections with a constraint on
`collection`, as with any argument:

```sh
for cap in collections get query history changes; do
  bin/rails "hob:sentinel:policy[muse,records.$cap,allow]" LIMITS='{"per_hour":120}'
done
bin/rails "hob:sentinel:policy[muse,records.put_many,allow]" LIMITS='{"per_hour":30}' \
  CONSTRAINTS='{"collection":{"pattern":"^amazon-orders$"}}'
for cap in collection.create collection.update delete collection.delete; do
  bin/rails "hob:sentinel:policy[muse,records.$cap,confirm]" LIMITS='{"per_day":10}'
done
```

Writes are allowed outright here, not reviewed: a record harms nothing
until someone acts on it, its history keeps every version, and a reviewer
reading a hundred order documents is cost without judgment.

Results carry a `notice`: a record's data is what a page said and an
agent copied down. Item titles and seller names are written by strangers.
They are data, not instructions.

## Muse and the Prime Visa

1. Muse reads the order history through gofer, a page at a time.
2. For each order, `records.put_many` into `amazon-orders`: the order as
   read, `source` its order-details URL. Unchanged orders cost nothing.
3. For each Prime Visa transaction in YNAB without a match, a query on
   `amazon-orders` by date and total finds the order (or the shipment: Amazon
   charges per shipment, so a schema with `shipments: [{ charged_on,
   amount }]` makes that the thing to match).
4. `budget.transaction.update` writes the memo and category, and
   `records.put` adds `budget:house-ynab:<id>` to the order's `links`.
5. Next month, `records.query { linked: "budget:house-ynab:<id>" }`
   answers "what was this charge?" without opening Amazon.

## Open questions

1. **Attachments.** An invoice PDF or a receipt photo is evidence too.
   hob stores no blobs; an attachment is probably a ref to wherever files
   live (`file:<...>`), once the household has one such place.
2. **`hob.resolve`.** Turning any ref into the thing it names is one call
   per prefix to services hob already speaks to. Useful for showing a
   record's links to a person; not needed to store them.
3. **Named leases.** If two agents ever share work that is not a mission
   (two reconcilers on one card), a `hob.lease { name, ttl }` built from
   missions' lease columns. Not before that happens.
4. **Retention.** Records are kept until retracted, and versions forever.
   A collection-level `keep_versions` is the knob if history grows.
5. **Surfaces.** A `/v1/records` for surfaces' keys, when fineass or a
   dashboard wants to read a collection directly instead of through an
   agent.
