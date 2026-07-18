# hob

*The household spirit that does the chores overnight, keeps the pots warm beside the fire, and knows everything about the house — provided you leave the milk out.*

hob is a personal LLM substrate: one backing service through which **every** LLM interaction in the household flows. Surfaces (kat, mise, feedcurator, and whatever comes next) talk to hob through thin client libraries; hob owns providers, conversations, personas, memory, tools, compute, and voice.

hob is the plumbing. The fancy embeddable chat porcelain, when it comes, is **chatelaine** — the keeper of the keys, wearing the `chat` on her belt.

---

## Design goals

1. **One door.** Every completion, chat turn, embedding, transcription, and TTS call in the household goes through hob. One usage ledger, one memory, one place to swap models.
2. **SillyTavern-class roleplay without the cruft.** Branched conversations, character cards, lorebook-style knowledge activation, group chats — as clean primitives, not accreted settings.
3. **Memory and knowledge are first-class.** A single entity graph + embedding index that every surface deposits into and withdraws from. The personal-superintelligence flywheel.
4. **Realms: agents must not tell people things they shouldn't.** Threat model is *disclosure by agents*, not box compromise. Enforcement is structural (Postgres RLS + information-flow control on tools), never "the prompt says don't mention it."
5. **Tools are the fourth pillar, not an afterthought.** Registry, venues (app webhooks, native, sandbox, GPU queues), async results, realm-annotated sinks.
6. **Compute is elastic and owned-first.** The gaming rig drains queues when it's on; RunPod bursts when queues back up; intimate work can be pinned to owned hardware.

### Non-goals

- Multi-tenant SaaS. hob serves one household. Actors exist (Jenner, Tessa, guests, personas), tenants don't.
- Cryptographic isolation between realms. Single Postgres, trusted service. If the box falls, everything falls; that risk is accepted.
- A frontend. hob is headless. chatelaine is a separate project (see [CHATELAINE.md](CHATELAINE.md)) coupled to hob only through the documented API contract.

---

## Architecture

```
                    ┌──────────────────────────────────────────────┐
                    │                    hob                       │
  kat ──ruby──▶     │  ┌─────────┐ ┌─────────────┐ ┌────────────┐  │
  mise ──ruby──▶    │  │ Gateway │ │ Conversation│ │   Memory   │  │
  feedcurator ─py─▶ │  └────┬────┘ └──────┬──────┘ └─────┬──────┘  │
  chatelaine ─sse─▶ │       └────────┬────┴──────────────┘         │
                    │         ┌──────┴─────────┐                   │
                    │         │ Execution fabric│                  │
                    │         └──────┬─────────┘                   │
                    └────────────────┼────────────────────────────-┘
                          ┌──────────┼──────────────┬───────────┐
                     app webhooks  agentbox      GPU queues   ElevenLabs
                     (mise, kat)   (coder)      (rig, RunPod)
```

- **Service:** Rails 8 API-only. Same conventions as kat/mise so code extracts cleanly. Solid Queue for internal jobs; ActionCable/SSE for streaming.
- **Store:** one Postgres with pgvector. Realm partitioning via row-level security (below).
- **Clients:** `hob` gem (rubygems name is free), `hob-client` on PyPI (pypi `hob` is squatted), `@jenner/hob` scoped on npm. Same conceptual API in each.
- **Identity:** API keys per surface, each bound to a principal + default clearance. Principals: humans (Jenner, Tessa, guests) and personas. Auth stays boring (bearer tokens) until it can't.

### The four planes

| Plane | Owns |
|---|---|
| **Gateway** | Providers, model roles, routing, streaming, retries, usage ledger |
| **Conversation** | Message DAG, branches, personas, assembly pipeline, ST import |
| **Memory** | Entity graph, observations, embeddings, extraction, recall, promotion queue |
| **Execution fabric** | Tool registry + IFC gate, venues, job queues, workers, voice |

---

## Plane 1 — Gateway

Provider abstraction over Anthropic / OpenAI-compatible / local endpoints.

**Model roles, not model IDs.** Surfaces request a role (`companion-voice`, `cheap-classifier`, `vision-tagger`, `narrator`, `tts-default`); hob maps roles to concrete provider+model with fallback chains. Swapping Haiku for a local Qwen is a config change in hob, invisible to every surface.

**Ephemeral providers.** A provider can be marked `transient` — present only while a live worker session holds it open (see GPU fabric). Role resolution prefers transient providers when online: `cheap-classifier → rig-qwen if present, else claude-haiku`.

**Usage ledger.** Every gateway call writes a `usage_event` (surface, principal, role, provider, tokens/characters/seconds, cost, conversation ref). kat's `llm_usage` is the seed. ElevenLabs characters and RunPod minutes land in the same ledger — one place to see what the household's AI life costs.

**Streaming** is SSE end-to-end; the gateway normalizes provider stream formats into one event shape (`delta`, `tool_call`, `usage`, `done`).

---

## Plane 2 — Conversation engine

### The DAG (lifted from kat's `MessageNode`)

Messages are **immutable, content-addressed nodes**: `content_hash = H(role, speaker, content, parent_hash)`, parent-hash chained. This is git for chat, and everything ST bolts on falls out naturally:

- **Swipes** = sibling nodes under the same parent.
- **Branches** = named refs pointing at leaf hashes (`branches` table: conversation, name, head_hash). Regenerate/edit = new node + ref move; nothing is ever destroyed.
- **Dedup** = content addressing. Importing the same ST chat twice is a no-op.
- **Late tool results and async events** append as nodes; a conversation is just a readable log of everything that happened, forkable at any point.

Multi-participant conversations are native (kat's `conversation_participants`): N personas + N humans, speaker order decided by a turn policy stage in the pipeline, not ST's group-chat hacks.

### Personas

A persona = prompt material (system core, example dialogue, greeting variants) + voice binding + default model role + memory scope (which entity it *is*, so it accumulates its own observations). ST character card v2/v3 import via kat's existing parsers; cards are converted to native form, originals archived.

### The assembly pipeline (the heart)

Every request's context is composed by an ordered pipeline of **stages**, each with a token budget, priority, and declared inputs:

```
persona → world/lore → memory recall → surface context → history → tool schemas
```

- Stages are pluggable units registered in hob; surfaces and personas can override the stage list or budgets, but the *defaults are opinionated* — this is where ST's prompt-manager spaghetti goes to die.
- **History** is budget-aware: newest-first fill, with rolling summarization of the evicted middle (summaries are themselves realm-tainted derived artifacts).
- **Surface context** is the host app's injection point: mise passes the recipe on screen, kat passes the media item. Arbitrary structured blob, rendered by a template the surface registers.
- **Lorebook entries** are not a separate system: they're entity observations with activation rules (keyword and/or embedding proximity), pulled in by the recall stage. ST lorebook import maps onto this.

Every assembled prompt is snapshotted (hash-referenced) so any reply can answer "what exactly did the model see?"

---

## Plane 3 — Memory & ontology

### Shape

- **Entities** are global and realm-less: people, personas, media items, recipes, articles, topics, projects, places. Typed, but types are free-form strings with a small blessed core (`person`, `work`, `event`, `place`, `preference`); rigid ontologies die on contact with real life. Stable ULIDs.
- **Observations** — timestamped facts about entities — carry a **realm** and **provenance** (source surface, conversation ref, extraction job, author principal). "Jenner is allergic to shellfish" (`household`, from mise chat 2026-07-01). Provenance is non-negotiable: the graph must know *why* it believes things.
- **Relations** (typed edges) also carry realms — edges are exactly where the sensitive stuff lives.
- **Embeddings** on everything (messages, observations, documents, entity digests), rows carry the realm of their source. Recall is hybrid: graph traversal from entities present in context + pgvector similarity, both realm-filtered *inside the query*.

### Extraction & the promotion queue

Background jobs distill conversations into observations. Extracted observations inherit the **realm of the conversation's clearance** (taint), even when the content looks mundane — a shellfish allergy mentioned to the kat companion lands in `intimate`.

The corrective is the **promotion queue**: the extractor flags observations that look mundane ("this appears to be a dietary fact — promote to `household`?") and a human approves with one tap. Declassification is always a human act; nothing auto-promotes, nothing auto-demotes. A weekly "here's what I learned, where should it live?" review doubles as memory-quality curation.

### Derived artifacts

Summaries, entity digests, "what I know about X" — anything computed from multi-realm inputs inherits the **union** of input realms, which usually renders it useless downstream. So hob computes digests **per clearance level**: a `household`-scoped digest of Jenner and an `intimate`-scoped one. More compute, categorically safer.

*(Metaphor for the memory plane, courtesy of mise: the master stock — the pot that never empties, every conversation enriches it, every surface draws from it.)*

---

## Realms

### Model

Realms form a hierarchy (lattice-ready if ever needed):

```
intimate  ⊇  personal  ⊇  household
  (kat)      (feedcurator,      (mise, family
              work, private)     surfaces)
```

**Asymmetric visibility:** clearance reads downward-inclusive. A kat request (`intimate` clearance) sees everything — the companion charmingly knows what's for dinner. A mise request (`household`) structurally cannot see up — Saffron never learns about the ERP scenarios. One comparison in the recall query buys the whole feature.

### Clearance resolution

`request clearance = min(api_key default, actor grant, explicit request cap)`. Tessa's principal grants `household`; kat's API key defaults to `intimate`; a surface can voluntarily cap down (e.g. kat's guest mode requesting `household`).

### Enforcement: Postgres RLS

Per-request: `SET LOCAL app.clearance = '<realm>'` inside the transaction. RLS policies on `observations`, `relations`, `embeddings`, `message_nodes`, `conversations` filter by realm-rank ≤ clearance-rank. A hob code bug that forgets a WHERE clause **cannot** leak — the database refuses. pgvector similarity queries pass through the same policies.

### The other leak channel: tool sinks (IFC)

Recall filtering stops an agent from *knowing*; the IFC gate stops an agent that legitimately knows from *telling*:

- Every tool declares a **sink realm**: where its effects become visible. `add_to_shopping_list → household` (Tessa reads the list), `save_memory → context realm`, `code_execution → none` (sandbox, no audience).
- Every conversation carries a **taint**: the max realm of anything assembled into its context. Retrieval tools make taint **dynamic**: every tool *result* carries the tool's source realm and can raise the taint mid-conversation, so the gate re-evaluates after every tool result, not once per turn.
- **The gate:** a tool call whose sink realm < conversation taint is blocked or routed to a human confirmation, per tool policy. The kat companion can *read* the meal plan; its attempt to *write* a note onto it trips the gate.

An audit log records every cross-realm read and every gate decision.

---

## Plane 4 — Execution fabric

### Tool registry

A tool registration = JSON schema + **source/sink realm annotations** + cost class + execution **venue** + auth. hob owns the tool loop (venues make client-side loops untenable); surfaces receive a normalized event stream.

**Tools as context: push a little, pull the rest.** Tools are read paths, not just action paths — mise's `search_recipes` proved this before hob existed. The surface-context stage pushes only *what the user is looking at* (small, stable, one round trip); everything else — the other 400 recipes, the pantry, past plans — is exposed as retrieval tools the model pulls on demand. This beats serializing the surface's world into the prompt every turn, and it's the cache-friendly shape: tool schemas are stable prefix material, while volatile data arrives as tool results at the *end* of context instead of churning the system prompt. Big up-front context blobs are the cache-killer.

**Async tools are first-class.** A call may return a job handle immediately; the conversation continues; the result lands later as a new DAG node and an SSE event. "Transcribe this and tell me when it's done" works in chat. ST structurally cannot do this.

### Venues

1. **App-hosted** — surfaces register tools with a webhook endpoint (`mise: add_to_meal_plan`). hob calls back with a signed request. Apps own their domain actions. The native venue for household surfaces, and the primary one, *because* registration carries the realm annotations the IFC gate needs.
2. **Native** — `recall`, `remember`, `speak`, `search`. Available to every persona everywhere.
3. **MCP bridge** — hob acts as MCP *client* to consumer-provided MCP servers; an MCP server is just a tool provider whose schemas are discovered (`list_tools`) instead of declared. This is the "home AI substrate" play: existing MCP servers plug in without hob-specific code. MCP has no realm concept, so a server registers with **per-server default source/sink realms and per-tool overrides**, annotated in hob at registration time.
4. **Client-session** — browser surfaces (chatelaine) can't host webhooks; their tools round-trip over the live connection instead: hob emits the `tool_call` SSE event, the client executes locally and POSTs the result back, the loop resumes. Also the path for client-side capabilities (clipboard, local files) hob should never see.
5. **Sandboxed compute (agentbox)** — a first-class `code_execution` tool driving Coder's REST/CLI, exactly the headless path in `infra/agentbox/coder`: provision from template → execute → return output → teardown. gVisor + fail-closed egress allowlist means personas get real compute with no path to the fleet or secrets — the precondition for letting a roleplay character run code. Two flavors:
   - **Warm pool** (1–2 live workspaces): sub-second "run this Python" for the calculator/scraper/chart case.
   - **Ephemeral task → PR**: the existing long-job flow, surfaced as an async tool.
6. **GPU queue** — enqueue a typed job, async result. Below.

### GPU fabric

kat-whisper-worker and kat-tagging-worker already froze the right protocol twice: **passive queue, active worker**; lease / submit / release; rig-comes-and-goes; `status:"empty"` is terminal success. hob generalizes it:

- **Typed queues:** `transcribe`, `vision-tag`, `embed`, `image-gen`, `tts-local`, … New modality = new queue type, not a new repo.
- **Workers** authenticate, declare capabilities (`{queues: [...], models: [...], vram}`), lease accordingly, heartbeat, release on signal. The two kat workers become thin ports over a shared lease-client library.
- **Priority classes:** interactive (a chat is waiting) > standard > backfill.
- **Live-provider mode:** a worker can additionally register as a **transient gateway provider** for latency-sensitive local inference (rig-hosted LLM). Batch and live are two modes of one worker daemon.
- **Burst (post-v1):** an autoscaler watches queue depth/age, spins a RunPod pod running the same worker image, which drains and self-terminates on idle. **Per-queue policy: `burst: allowed | owned_hardware_only`** — realm-annotated jobs from `intimate` queues never land on rented GPUs; feedcurator embedding backfills burst freely.

### Voice

- **Voices belong to personas.** Saffron has a voice; kat companions have voices; `speak` is a native tool.
- **Cache by content hash:** messages are already content-addressed, so TTS audio caches at `H(message_hash, voice_id, settings)` — never pay ElevenLabs twice for the same line. (kat's `eleven_labs` + `generated_audio` services extract nearly whole.)
- **Provider-abstracted like everything else:** `tts-default` is a model role — ElevenLabs today, an XTTS queue on the rig tomorrow. Metered in the usage ledger.
- Free killer app: feedcurator's morning briefing → persona voice → private podcast feed.

---

## Schema sketch

```
realms            slug PK, rank int                     -- household=0, personal=1, intimate=2
principals        id, kind(human|persona|worker|surface), name, max_clearance
api_keys          token_digest, principal_id, surface, default_clearance

entities          ulid PK, type, name, aliases[], created_by
observations      ulid, entity_id, body, realm, provenance jsonb,
                  observed_at, embedding vector, promoted_from ulid?     [RLS]
relations         ulid, from_id, to_id, kind, realm, provenance jsonb    [RLS]
entity_digests    entity_id, clearance, body, refreshed_at               [RLS]
promotions        observation_id, suggested_realm, status(pending|approved|rejected)

conversations     ulid, surface, realm, taint_realm, participants[]      [RLS]
message_nodes     content_hash PK, conversation_id, parent_hash, role,
                  speaker, content, kind(text|tool_call|tool_result|event),
                  prompt_snapshot_hash?                                  [RLS]
branches          conversation_id, name, head_hash
personas          ulid, entity_id, prompt jsonb, voice_id, default_role,
                  card_import jsonb?
prompt_snapshots  hash PK, assembled jsonb                               [RLS]

providers         id, kind(anthropic|openai_compat|elevenlabs|transient), config
model_roles       role PK, chain jsonb                  -- ordered provider/model fallbacks
usage_events      id, principal, surface, role, provider, units jsonb, cost, ref

tools             id, name, schema jsonb, venue(webhook|native|mcp|client|sandbox|queue),
                  source_realm, sink_realm, cost_class, config jsonb
mcp_servers       id, url, auth jsonb, default_source_realm, default_sink_realm
                  -- discovered tools land in `tools` with venue=mcp, per-tool overrides
tool_invocations  ulid, tool_id, conversation_id, status, args, result,
                  gate_decision(allowed|blocked|confirmed)?, job_id?

queues            slug PK, kind, burst_policy(allowed|owned_only), realm
jobs              ulid, queue, payload jsonb, priority, status,
                  leased_by?, lease_expires_at, result jsonb             [RLS]
workers           id, principal_id, capabilities jsonb, last_seen, live_provider bool

audio_cache       key PK (msg_hash+voice+settings), url, bytes, cost
audit_log         id, principal, action, realm_context, detail jsonb, at
```

RLS: policies on `[RLS]` tables comparing `realms.rank` against `current_setting('app.clearance')`; hob sets `SET LOCAL app.clearance` per request transaction. Cross-realm FKs avoided on realm-scoped rows (ULIDs everywhere) — keeps the per-realm-database escape hatch open, even though we're not taking it.

---

## Client library shape

```ruby
hob = Hob::Client.new(key: ENV["HOB_KEY"])          # clearance rides on the key

# pipeline-style completion (feedcurator-style work)
hob.complete(role: "cheap-classifier", schema: CLUSTER_SCHEMA, messages: [...])

# chat turn on a branch, with surface context
hob.chat(conversation:, branch: "main", persona: "saffron",
         context: { recipe_id: 42 }) { |event| ... }   # SSE: delta/tool/audio/done

# branching
hob.fork(conversation:, at: node_hash, branch: "what-if")

# memory
hob.remember(entity: "jenner", body: "...", realm: :household)
hob.recall(query: "dinner preferences", entities: ["jenner"])

# jobs & voice
hob.enqueue(queue: "transcribe", payload: {url: ...})   # → job handle
hob.speak(text: "...", persona: "saffron")               # → cached audio URL
```

Python mirrors it (`hob-client`). The clients are where "abstract over all the bullshit" lives: no provider APIs, no token budgets, no prompt assembly visible to surfaces.

---

## Sequencing

**v1 — the door and the DAG.** Rails app + Postgres with realms/RLS *from day one* (cheap now, wrenching later). Gateway with Anthropic + one OpenAI-compat provider, model roles, usage ledger. Conversation DAG + branches + personas + ST card import (kat code extraction). Assembly pipeline in its default configuration. Ruby client. **Generic job queue + lease protocol, porting both kat workers** (low-risk: the contract already runs in production). First consumer: kat's companion chat.

**v1.5 — voice.** ElevenLabs wrap, persona voices, hash-keyed audio cache (kat extraction). Cheap and immediately fun.

> **Resequencing (2026-07-18):** chatelaine has been pulled forward from v2 — it's being built now against a v1 vertical slice (gateway + DAG + assembly pipeline, no workers). The kat worker port moves out of v1 in exchange. See [CHATELAINE.md](CHATELAINE.md).

**v2 — the fabric.** Tool registry + hob-owned loop + the IFC sink gate. Venue order: app-hosted webhooks first (mise is the proving consumer — its four companion tools port directly), MCP bridge second, client-session tools when chatelaine needs them. Async tool results into the DAG. agentbox `code_execution` (warm pool + ephemeral). Python client; feedcurator's pipeline moves to `hob.complete`. mise moves over — its contextual chat is the assembly pipeline's proving ground. chatelaine v0 (the web component) starts here, with the clearance badge (kat-purple for `intimate`, something warm for `household`).

**v3 — the graph and the burst.** Memory extraction pipelines, hybrid recall stage, promotion queue, per-clearance digests. feedcurator's interest profile becomes graph-resident. Rig live-provider mode. RunPod burst with `owned_hardware_only` pinning.

The discipline: **don't build the ontology first.** Memory with no conversations flowing through it has nothing to learn from. Plumb the boring layers; the graph fills itself.

---

## Open questions

1. **Embedding model & dimensions** — one household-wide model (swap = full re-embed) vs per-collection. Lean: one model, versioned column, re-embed via the GPU queue (that's what backfill queues are for).
2. **Assembly pipeline extensibility surface** — config-declared stages only, or arbitrary code (gem-loaded stages)? Lean: config + a small stage SDK; no remote code.
3. **Prompt snapshot retention** — every turn forever is a lot of jsonb. Lean: keep hashes forever, GC bodies after N days except pinned.
4. **ST import fidelity** — cards yes, full chat JSONL history yes (kat parser exists); lorebooks → observation+activation-rule mapping needs a spike.
5. **chatelaine transport** — SSE vs WebSocket for the component; SSE is simpler and sufficient until multi-user presence matters.
6. **Where hob runs** — ~~tabitha next to kat, or its own box?~~ **Decided (2026-07-18): cadance.jfave.com (VPS)**, so hob survives home-internet outages. This accepts VPS custody of realm-tagged data; trade-off and mitigations recorded in [CHATELAINE.md](CHATELAINE.md#deployment-cadancejfavecom). The per-realm-database escape hatch stays open for pinning `intimate` to owned hardware if the placement ever feels wrong.

## Name registry status (checked 2026-07-04)

| | rubygems | pypi | npm |
|---|---|---|---|
| `hob` | **free** | taken → use `hob-client` | taken → use `@jenner/hob` |
| `chatelaine` | **free** | **free** | **free** |

Grab `hob` on rubygems and `chatelaine` everywhere before building in the open.
