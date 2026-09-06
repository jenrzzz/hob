# hob extraction refactor

*Surveyed 2026-09-06 against every checkout in `~/src`: airing, chatelaine,
feedcurator, hob, lumen, mise, parboil.* This document says what the sibling
apps taught, what changes in hob as a result, and in what order each app
moves over. It sequences **ahead of** DESIGN.md's v2 (tools fabric) and
replaces the "mise moves over in v2" line with something more granular.

**Status.** A and B are implemented in hob as of 2026-09-06, together with
the Phase 0 foundations (test suite, `Gateway::Fake`) and the Phase 1
`POST /v1/completions`, `GET /v1/completions/:id`, and `GET /v1/usage`
endpoints. One naming change from the text below: the ruby_llm wrapper is
`Gateway::Transport`, not `Gateway::Provider`, because `Provider` is already
the config model. Cache token counts live in `usage_events.units` alongside
the other token counts rather than as a column.

C and D followed the same day. Tools: a reply that stops at tool calls is
`status: tool_calls` (a third outcome next to success and refused, since
"success with a tool_calls key" hid the branch every caller has to take);
`POST /v1/completions` resumes with `{ id, tool_results }`; `tool_choice`
and `max_iterations` ride on the request, and past the cap the tools stay
declared with `tool_choice: none` (Anthropic rejects a transcript holding
`tool_use` blocks when no tools are declared). ruby_llm's `Chat#complete`
executes tools in-process, so `Gateway::Transport` calls the provider
directly and hands the calls back unexecuted. The gem is `hob` 0.1.0 in
`clients/ruby` (the 0.0.1 name reservation), with `Hob::Fake` and no runtime
dependencies. Open question 4 (an interview conductor helper) is still open.

---

## 1. What exists today

| App | Stack | LLM path today | Built hob-shaped? | Ledger | Realm |
|---|---|---|---|---|---|
| **hob** | Rails API | `Gateway.chat(role:)` over ruby_llm; SSE chat only | is hob | `usage_events` (tokens, no cost, no failures) | all |
| **parboil** | Rails | `LLM::Gateway.complete/chat` → `LLM::Client` (kat port) → ruby_llm | yes, explicitly mirrors the DESIGN.md client sketch | `llm_usages` — the richest: operation, status, duration, cost, prompt/response | personal |
| **airing** | Rails + sqlite | `Llm.complete(role:, system:, messages:, schema:)` on the raw `anthropic` gem | yes, copied from parboil | none | personal |
| **mise** | Rails | `AIGateway.chat(role:)` → ruby_llm; tools via `RubyLLM::Tool` | yes, `docs/HOB.md` already maps every piece | `ai_usage_events` | household |
| **feedcurator** | Python/FastAPI | raw `anthropic` SDK, forced tool-use for structure, hand-rolled agentic loop | no | log lines only | personal |
| **lumen** | Node, one file | raw SDK, native `json_schema` output, streamed 64k-token generations | no | none | household |
| **chatelaine** | Svelte SPA | hob `/v1` — the only real hob client | is the client | — | via key |

Every Rails app independently rebuilt a "gateway" module whose comment says
some version of *"when hob exists this becomes a thin wrapper over the hob
client."* The hob client is a name-reservation stub. **That is the refactor:
make the stub real, and make hob able to do what the four gateways do.**

---

## 2. What the apps taught

### 2.1 `complete` is the missing primitive

hob has one model-facing operation: a chat turn on a DAG branch. Of the six
consumers, only chatelaine wants that. Everything else is a one-shot,
structured completion: *role + system + messages + schema → parsed object*.

| Consumer | Call | Structure mechanism |
|---|---|---|
| parboil extractor, interviewer | `complete(role:, messages:, schema:, operation:, metadata:)` | ruby_llm `with_schema`; refusal heuristic = "no `{` in the reply" |
| airing extractor, interviewer | `complete(role:, system:, messages:, schema:, max_tokens:)` | Anthropic native `output_config.json_schema`; `stop_reason == refusal`; adaptive thinking |
| mise extract, refine | `chat.with_schema` + regex to dig JSON out of prose | ruby_llm; comment notes Anthropic path didn't enforce schemas |
| feedcurator ×4 | forced `tool_choice` with a strict submit tool | re-parses stringified JSON in array fields; retries once |
| lumen | native `json_schema` output, streamed | refusal detection; provider-side fallback beta |

Five implementations, five different refusal and repair strategies. The
DESIGN.md client sketch already promises `hob.complete(role:, schema:,
messages:)`. parboil and airing built their call sites to exactly that
signature on purpose. It must exist before anything can move.

Lessons that the consolidated version has to carry, each learned the hard
way in at least one app:

- **Refusal is a distinct outcome**, not a parse error and not a 500. parboil
  counts it in the ledger as `refused`; airing and lumen read `stop_reason`.
- **Stringified JSON inside structured output happens.** feedcurator's
  `_extract_tool_input` re-parses top-level string fields that look like
  arrays or objects. Cheap to do everywhere.
- **Retry exactly once** on an unparseable structured reply (feedcurator,
  three separate call sites).
- **Long outputs must stream from the provider even when the caller
  doesn't want a stream.** lumen streams 64k-token generations only to avoid
  the HTTP timeout; mise moved capture into a job for the same reason.
- **Native provider features matter.** airing and lumen bypassed ruby_llm to
  get native structured outputs, adaptive thinking, and refusal stop
  reasons. hob's provider layer must not lose those.

### 2.2 The ledger: parboil's is the reference, hob's is the thinnest

hob's `usage_events` records tokens after a successful call. Cost is a column
that nothing writes. Failures are never recorded. parboil's `llm_usages`
(ported from kat) records `operation`, `status` (success / refused /
rate_limited / error), `duration_ms`, `error_message`, `metadata`, computed
`cost` from a per-model price table, and the prompt and response bodies.
airing records nothing at all, so its interview costs are invisible.

The whole point of "one door" is one ledger. hob's must be at least as good
as the best surface ledger, or surfaces will keep their own.

### 2.3 The interview loop was copied twice

parboil's `Interview::{Conductor, Extractor, Persona}` was lifted nearly
verbatim into airing's `MemoryInterview::*` ("parboil's Conductor with the
DAG taken out"). The pattern:

1. Persist the human's answer **before** any model call.
2. Run a schema-constrained **extraction** as a side effect; extraction
   failure never blocks the next question.
3. Ask the next question with a prompt assembled from *persona + domain
   digest + what's already captured + transcript + a trailing instruction*.
4. `ask_next!` is idempotent; a turn that dies between answer and question
   resumes from the answer.
5. **Stuck → step down, never skip:** a smaller question appended as a child
   of the stuck question, with depth-based escalation.

Two things here are conversation-engine features hob doesn't have:

- **Assistant-initiated turns.** `start!`, `ask_next!`, and `step_down!` all
  produce an assistant node with no new user node. `ChatTurn` requires
  `content`.
- **Assistant→assistant chaining.** Stepping stones are children of the
  assistant's own question. The DAG allows it; `ChatTurn` doesn't.

And one thing that is an assembly-pipeline feature: the **trailing
instruction** ("Ask the single most useful next question", "The writer is
STUCK…"). Both interviewers render the whole prompt as one user message
because the current stage list has nowhere to put post-history text.
CHATELAINE.md's default stage list ends in `style` for the same reason.

The Conductor itself (session contract, ripeness steering, stuck depth)
stays surface-side. It's product, not plumbing.

### 2.4 Surface context is several named blocks, each with a budget

Every app injects "what the surface knows" as prompt text:

- mise `ContextBuilder`: the recipe on screen, or the meal plan, or (freeform)
  the last 12 recipes plus this week's plan, every turn.
- parboil `Persona`: material scraps (per-scrap and total char budgets),
  graph digest, ripeness gaps.
- airing `LibraryDigest`: library-by-year, top artists, scrobbles-by-year,
  the record on the table, nearby additions, memories already captured.
- lumen: the previous story (for sequels) and the last 25 topics.
- feedcurator: ongoing-story memory and the previous briefing's coverage.

hob's `scenario` stage takes one string or hash. What the apps actually
need is an ordered list of named blocks, each with its own budget, with
stable blocks first so prompt caching hits. parboil already does the
budgeting by hand; mise's freeform context is exactly the cache-killer
DESIGN.md warns about.

### 2.5 Tools: one real loop, one hand-rolled loop

mise runs the only production tool loop (four `RubyLLM::Tool`s, in-process,
side effects broadcast as `event` rows in the chat). feedcurator hand-rolls
an agentic loop where `fetch_articles` is a real tool and `submit_summaries`
is the terminator, capped at ten iterations. Both are the **client-session
venue** from DESIGN.md Plane 4: the caller executes, hob orchestrates. The
webhook venue is heavier and no current surface needs it.

`message_nodes.kind` already reserves `tool_call` and `tool_result`; `role`
already includes `event`. The schema is ready; the loop isn't written.

### 2.6 Ensemble speakers

mise's companions answer in one model call with `[saffron]` / `[maggie]`
segments, split into separate messages per speaker. hob's history stage
already tags speakers when more than one is present, and `ChatTurn` strips
a self-tag for a single persona. The other half, splitting a reply into a
chain of speaker-attributed assistant nodes, is missing.

### 2.7 Model role configuration sprawl

| App | Roles | Where the model ID lives |
|---|---|---|
| hob | `chat-default`, `cheap-classifier` | `model_roles` rows with fallback chains |
| parboil | `interviewer`, `extractor` | initializer constant, plus a price table |
| airing | `interviewer`, `extractor` | module constant, opus with adaptive thinking |
| mise | `extractor`, `companion` | env vars with a global fallback |
| feedcurator | one setting | `claude_model` env |
| lumen | none | hardcoded, plus the server-side fallback beta |

Per-role params seen in the wild: `max_tokens` (8k / 16k / 64k), `thinking:
adaptive`, `temperature`. hob's chain links already carry `params`. One
thing missing: airing deliberately chose opus for the interviewer because
"the question is the product". A fallback chain that silently drops to a
cheaper model changes the product. Roles need a `strict` option.

### 2.8 Memory-shaped data in three places (not this refactor)

airing `Memory` (body, year/era, artist/title, provenance turn), parboil
`IdeaNode` (typed, provenance node hash, thesis flag), feedcurator
`StoryMemory` (LLM-maintained state per story, id-stable, ages out, "a model
omission never drops a story"). All three are *observations with provenance
extracted from conversation*, which is DESIGN.md Plane 3 in miniature.

DESIGN.md's discipline stands: don't build the ontology first. This refactor
only makes sure extraction results carry a hob node hash as provenance, so
these three datasets can seed the memory plane later without re-extraction.

---

## 3. The refactor

### A. Gateway plane

**A1. `Gateway.complete`.** One-shot request: `role`, `system`, `messages`,
`schema`, `tools`, `params`. Returns a normalized response: `content`,
`parsed` (when a schema was given), `stop_reason`, `refused?`, token counts
including cache reads, `model`, `provider`, `duration_ms`.

**A2. Keep ruby_llm as transport; wrap it, don't replace it.** *(Verified
2026-09-06 against ruby_llm 1.16.0, the installed and latest release, by
rendering payloads offline.)* Three apps bypassed ruby_llm for native
features, but the current release has most of them:

| Feature | ruby_llm 1.16.0 | Caveat hob's wrapper must handle |
|---|---|---|
| Native structured output | yes: `with_schema` → `output_config.format.json_schema`; reply is JSON-parsed | a parse failure is **swallowed silently** (content stays a string); hob does the retry |
| Adaptive thinking | yes: `with_thinking(effort:)` → `thinking: {type: adaptive}` + `output_config.effort` | **raises under `assume_model_exists: true`** (placeholder model has no reasoning options), and the registry stops at opus-4-8, so sonnet-5 / opus-5 are always assumed. Pass `thinking:` and `output_config: {effort:}` through `with_params` instead; deep-merge is correct and coexists with the schema's `output_config` |
| `max_tokens` | from the registry | assumed models get 4096; hob sets it per chain link via params |
| Refusal | **no**: `stop_reason` is never read; a refusal comes back as empty content | read `message.raw.body["stop_reason"]` on sync calls; streaming does not surface `message_delta`, so streamed refusals need the raw chunk hook or a post-hoc check on empty content |
| Cache usage | yes: `cached_tokens`, `cache_creation_tokens` | — |
| Beta headers, fallbacks | mechanism exists: `with_headers`, `with_params` | untested |

So the provider interface hob defines is a thin `Gateway::Provider` over
ruby_llm: it translates chain-link params into `with_params`, reads
`stop_reason` from the raw response, and owns retry. The `anthropic` gem
is not needed. If ruby_llm later reads `stop_reason` and drops the
registry gate on thinking, the wrapper shrinks further.

**A3. Always stream from the provider.** Buffer when the caller wants a
blocking response. Removes the timeout class of bug from lumen and mise
without every surface needing a job.

**A4. Structured-output hygiene, once.** Re-parse stringified JSON fields;
retry once on a parse failure; surface refusal as its own outcome.

**A5. Ledger v2.** `usage_events` gains `operation`, `status`,
`duration_ms`, `error`, `metadata`, `snapshot_digest`, `cache_read_tokens`.
Every call writes a row, including failures. `cost` is computed from a
`model_prices` table (model, USD per million input / output / cache read),
seeded from parboil's table. Config rows, not code.

**A6. Error hierarchy** shared by API and client: `Refused`, `RateLimited`,
`Unavailable` (no provider, upstream 5xx), `Unauthorized`, `Invalid`.

**A7. `strict` model roles.** A chain link marked `strict` fails the request
instead of falling through when its provider is unavailable.

### B. Conversation engine

**B1. Completions are conversations.** A completion persists as a
single-branch conversation flagged `kind: pipeline` (hidden from listings by
default). That gives every pipeline call a prompt snapshot, a ledger `ref`,
a place for tool-call nodes to land, and provenance hashes for extraction.

**Retention: keep everything.** *(Decided 2026-09-06.)* No GC on pipeline
conversations or snapshots. The DAG's rule is that nothing is destroyed,
parboil has kept prompt and response bodies per call since July, and the
v3 memory plane wants to re-extract from history: retention is the
reversible choice. The volume doesn't justify a policy anyway. From the
apps' actual settings, feedcurator dominates at roughly 400 MB a year
uncompressed (eight calls a day, 60 to 150 KB each); every other surface is
single-digit megabytes. TOAST compresses prompt text three to four times,
so the realistic total is 100 to 200 MB a year on the VPS disk. This closes
DESIGN.md open question 3 the other way from its lean.

Optional later trim, no loss: the snapshot repeats message bodies that
already live in nodes. The history stage already records a content hash
per message, so the snapshot can store hashes for messages and inline text
only for the system prompt. Revisit retention only if the tables pass a
few gigabytes, which at current rates is a decade away; feedcurator going
hourly or the memory plane embedding every node would bring that forward
to years.

**B2. Assistant-initiated turns.** `content` becomes optional on chat. With
no content, the assistant speaks at the branch head. If the head is already
an assistant node, the new node chains under it. This is `start!`,
`ask_next!`, and `step_down!` in one rule.

**B3. `instruction` stage.** Post-history text from the request
(`instruction:`) or the persona (`prompt.instruction`), rendered after
history. Default stage list becomes
`persona → scenario → history → instruction`.

**B4. Context blocks.** `context` accepts an array of
`{ name, body, budget, volatile }`. Non-volatile blocks render first in the
given order; volatile ones last. A bare string or hash still works.

**B5. Ensembles.** `personas: [...]` on chat. The reply is split on speaker
tags into a chain of assistant nodes, each with `speaker`. Single-persona
behaviour is unchanged.

**B6. Event nodes.** `POST /v1/conversations/:id/events { content }`
appends a `role: event` node. mise's `emit_event` becomes this.

### C. Client-session tools

`tools: [{ name, description, input_schema }]` on chat and complete. When the
model calls a tool, hob appends a `tool_call` node, emits a `tool_call` SSE
event (or returns it in the JSON body), and **ends the request**. The caller
executes and continues with `tool_results: [{ id, content }]` on the same
endpoint; hob appends `tool_result` nodes and calls the model again. The loop
is stateless on hob's side, resumable, and every step is in the DAG.
An `iteration` cap (feedcurator's ten) lives on the request.

### D. Ruby client gem 0.1

The API is parboil's `LLM::Gateway` signature, which airing copied, because
both were written to be the hob client:

```ruby
hob = Hob::Client.new(base: ENV["HOB_URL"], key: ENV["HOB_KEY"])

hob.complete(role:, messages:, system: nil, schema: nil, tools: nil,
             operation: nil, metadata: {}, params: {}) # => Hob::Completion

hob.chat(conversation:, branch: "main", content: nil, persona: nil,
         personas: nil, context: nil, instruction: nil, preset: nil,
         tools: nil, tool_results: nil) { |event| }  # => Hob::Turn

hob.conversations.create / show / fork / set_head / siblings / event
hob.usage(ref:, since:)
Hob::Fake                       # airing's Llm.client= injection, as a gem feature
Hob::Error, Hob::Refused, Hob::RateLimited, Hob::Unavailable
```

Node and Python surfaces call `/v1/completions` over plain HTTP for now.
lumen's whole LLM surface is one call; feedcurator's is four. Packages come
when a third consumer per language appears.

### E. Not in this refactor

Async turns (mise's job-wraps-a-sync-call is the right shape for every
current surface; hob-side async lands with the job queue). Memory plane.
Webhook and MCP venues. GPU queues, voice. Realm enforcement is already in
place and unchanged; each surface just gets a key with the right default
clearance.

---

## 4. API additions

```
POST /v1/completions
  { role, operation, system | persona, messages, schema?, tools?, tool_results?,
    params?, metadata?, ref?, realm? }
  → 200 { id, status: success|refused, content, parsed?, tool_calls?,
          usage: { input_tokens, output_tokens, cache_read_tokens, cost },
          model, provider, snapshot }
  Accept: text/event-stream → delta… tool_call? usage done

POST /v1/conversations/:id/chat            (existing, extended)
  + content optional · personas[] · context[] · instruction · tools · tool_results

POST /v1/conversations/:id/events          { content }
GET  /v1/usage?ref=&role=&since=           ledger summary for surfaces that drop their own
GET  /v1/completions/:id                   a pipeline conversation's single turn
```

Refusal is HTTP 200 with `status: refused` (the call happened and was
metered); the client raises `Hob::Refused`. Upstream rate limits return 503
with `Retry-After`.

## 5. Schema changes

```
usage_events      + operation, status, duration_ms, error, metadata jsonb,
                    snapshot_digest, cache_read_tokens
model_prices      model PK, input, output, cache_read   (USD per 1M)
model_roles.chain links gain  strict: bool
conversations     + kind (chat | pipeline)
prompt_snapshots  conversation_id already present; nothing new
personas.prompt   + "instruction" key
presets           default stages gain "instruction"
```

Seeded roles: keep `chat-default`, `cheap-classifier`; add `interviewer`,
`extractor`, `companion`, `narrator`. Per-role params go on the chain link.

---

## 6. Migration plan

| App | Phase 1 (complete + gem) | Phase 2 (conversation upgrades) | Phase 3 (tools) |
|---|---|---|---|
| **airing** | `Llm` → `Hob::Client#complete`; gains a ledger for the first time. `personal` key. Triage stays LLM-free. | `InterviewTurn` → hob conversation, one per album plus one library-wide; `Memory.interview_turn` → node hash. Step-down = assistant→assistant. | — |
| **parboil** | `LLM::Gateway`, `LLM::Client`, `LLMUsage`, initializer → gem. `personal` key. | Own `MessageNode` table → hob conversation. `IdeaNode.source_message_hash` is already a content hash. `Interview::Persona` → hob persona `interviewer` with an `instruction`. Ripeness and Linearizer untouched. | — |
| **mise** | `AIGateway` → gem; `RecipeAI` extract/refine → `complete(schema:)`; `AIUsageEvent` retired for `GET /v1/usage`. `household` key. | `ChatSession` → conversation keyed by context; `ContextBuilder` → context blocks (recipe/plan stable, "recent recipes" volatile, and shrinking); Saffron + Maggie → personas with `personas: [...]`. | Four companion tools → client-session tools from `CompanionReplyJob`; `emit_event` → event nodes. |
| **feedcurator** | cluster, briefing, story-memory steps → `POST /v1/completions` with `schema` over httpx. `personal` key. | — | summarize step: `fetch_articles` as a client-session tool, `submit_summaries` becomes the schema. |
| **lumen** | one `fetch` to `/v1/completions` with `schema`, SSE for progress; Fable and Lumen → personas; the fallback beta → a chain. `household` key. | — | — |
| **chatelaine** | nothing required | ensemble and instruction in the preset editor | tool-call rendering |

### Sequencing

**Phase 0 — foundations (hob only).** A test suite and `Gateway` fake (hob
has neither; airing and parboil both do). Provider adapters (A2, A3). Ledger
v2 and prices (A5). Error hierarchy (A6). Nothing user-visible changes.

**Phase 1 — the door.** `POST /v1/completions` (A1, A4, B1), `strict` roles
(A7), `GET /v1/usage`, gem 0.1 (D). Migrate airing first: one module, one
feature, and it currently has no ledger, so the win is immediate and the
blast radius is tiny. Then parboil's gateway, mise's `RecipeAI`, lumen,
and three of feedcurator's four steps. After this phase every app's model
ID lives in hob.

**Phase 2 — the engine.** B2 through B6. Migrate the two interviews and
mise chat onto hob conversations. parboil's private `MessageNode` table and
airing's `InterviewTurn` table retire.

**Phase 3 — tools.** C. mise's companions and feedcurator's summarizer. This
is the first slice of DESIGN.md v2's fabric, and it deliberately picks the
venue that needs no registry and no webhooks.

---

## 7. Open questions

1. ~~**Adapters vs ruby_llm.**~~ Resolved 2026-09-06: ruby_llm 1.16.0 has
   native structured output and adaptive thinking; it lacks refusal
   detection and gates thinking on its model registry. See A2 for the
   wrapper contract. Remaining sub-question: refusal detection on the
   **streaming** path, which needs a raw-chunk hook or a post-hoc check.
2. ~~**Pipeline conversation retention.**~~ Resolved 2026-09-06: keep
   everything. See B1 for the numbers and the optional snapshot dedupe.
3. **Usage endpoint shape.** Neither parboil nor mise has a usage UI today,
   so `GET /v1/usage` can start as a per-`ref` and per-role sum. Confirm
   nothing reads `llm_usages.prompt` / `response` before dropping them; the
   snapshot replaces them.
4. **Interview conductor as a gem helper.** It has been copied twice. A
   `Hob::Interview` helper in the gem (conversation + digest proc + extractor
   schema + apply proc) is tempting. Lean: not yet; wait for a third copy.
5. **Realm for airing.** Music memories are autobiographical; `personal`
   is the assumption here. Revisit if the timeline is meant for the whole
   household.
