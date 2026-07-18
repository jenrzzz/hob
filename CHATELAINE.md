# chatelaine

*The keeper of the keys, wearing the `chat` on her belt.*

chatelaine is the chat frontend for [hob](DESIGN.md): a SillyTavern-class roleplay and prompt-management UI without the cruft. Chat-completions-only, DAG-native, tablet-first, and built so that a new model release is a config row, not a two-month wait for maintainers to come back from vacation.

This document scopes chatelaine v0 and the hob vertical slice it rides on. It **resequences DESIGN.md**: chatelaine was v2 there; it's now being pulled forward, and the hob v1 worker port is deferred in exchange.

---

## Positioning

Two audiences, in order:

1. **The household** — chatelaine is how Jenner (and eventually guests) talk to hob personas from any device, especially the iPad.
2. **Others, later** — chatelaine is intended to be shared publicly, and hob to grow into a self-hostable "home AI substrate" API that chatelaine (and other surfaces) target.

The second audience imposes discipline now, cheap now and wrenching later:

- chatelaine couples to hob's **documented API contract only** — never to hob internals, never to the shared Postgres. If chatelaine needs data, the API grows an endpoint.
- The hob slice stays **trivially self-hostable**: single `docker-compose.yml` (Rails + Postgres/pgvector), config via env vars, no household-specific assumptions baked into code.
- The SSE event shape, auth scheme, and REST surface are treated as **public API from day one**: versioned, documented, changed deliberately.

### The niche

SillyTavern's complexity is not accidental — it comes from abstracting over text-completion backends (Kobold, ooba, NovelAI), where every model needs instruct templates, context templates, tokenizer config, and forty sampler sliders. Going **chat-completions-only** doesn't trim features; it deletes entire subsystems.

**Dies with text completion:**
instruct/context templates, story strings, per-model tokenizer settings, sampler zoo (chat APIs expose temperature, top_p, max_tokens, reasoning effort — that's the whole settings panel), CFG, the extensions framework, group-chat turn hacks.

**Stays, rebuilt on better primitives:**

| ST concept | chatelaine primitive |
|---|---|
| Character cards | Personas (v2/v3 card import, converted to native form) |
| Swipes | Sibling nodes under the same parent |
| Chat file copies for branching | Named refs over the DAG (`branches`) |
| Prompt manager | Assembly pipeline stages with visible token budgets |
| Message edit/regenerate | New node + ref move; nothing destroyed |
| User personas | Principals / user-persona stage |

**New — the actual pitch:**

- **Prompt snapshot inspector.** Every assembled prompt is hash-snapshotted, so any reply answers "what exactly did the model see?" ST fundamentally cannot do this. Same component renders pre-send preview and post-hoc inspection.
- **Day-one new-model support by construction.** No per-model templates means a new model is a config row: provider + model ID + params passthrough. The model picker populates from the provider's `/models` endpoint, so new releases appear without a deploy. Unknown params pass through untouched.
- **Cache-aware assembly.** Stable prefix ordering (persona/lore first, volatile context last) so Anthropic prompt caching actually hits. ST's prompt manager scrambles prefixes and torches the cache. Cheaper *and* purer. (Long-term this pairs with hob's push-a-little-pull-the-rest tool model — see DESIGN.md Plane 4 — where the long tail of context arrives via retrieval tools instead of bloating the prompt.)
- **Reasoning as a first-class node kind.** Thinking/reasoning blocks persist in the DAG and render collapsed, not bolted on.
- **Tablet-first PWA.** ST's mobile story is miserable; a real iPad experience is a genuine wedge.

---

## Architecture

```
┌──────────── iPad / desktop browser ────────────┐
│  chatelaine  (Svelte 5 + Vite SPA, PWA)        │
└───────────────┬────────────────────────────────┘
                │  REST + SSE, bearer key  (public contract)
┌───────────────┴────────────────────────────────┐
│  hob slice on cadance.jfave.com                │
│  Rails 8 API · Postgres + pgvector · RLS       │
│  Gateway (Anthropic + OpenAI-compat)           │
│  Conversation DAG · assembly pipeline          │
└────────────────────────────────────────────────┘
```

- **Frontend:** Svelte 5 + Vite. Fast to hack, tiny runtime, compiles to custom elements later for the embeddable web-component form DESIGN.md promises. No component library — the design surface is small and iPad Safari quirks are easier handled by hand.
- **Transport:** SSE (works in Safari; sufficient until multi-user presence matters — per DESIGN.md open question 5).
- **Auth:** bearer API key, stored client-side. Fine for household use; a real session story is a prerequisite for public sharing (open question below).

### hob vertical slice

Only these tables from the DESIGN.md schema: `providers`, `model_roles`, `conversations`, `message_nodes`, `branches`, `personas`, `prompt_snapshots`, `api_keys`, `usage_events`, `realms`, `principals`. Realm columns and **RLS policies from day one** (cheap now, wrenching later), even though only one realm is exercised initially.

**Deferred entirely:** memory plane, promotion queue, tools/IFC gate, GPU queues, workers, voice.

Endpoints that matter:

- `POST /conversations/:id/chat` — streaming SSE, normalized events (`delta`, `usage`, `done`; `tool_call` reserved for the v2 tool loop — chatelaine will eventually be a **client-session tool venue**: hob emits `tool_call`, the browser executes locally and POSTs the result back). The one endpoint that matters most.
- CRUD: conversations, branches (`fork` at any node), personas, presets.
- `GET /snapshots/:hash` — the inspector's data source.
- `GET /models` — roles + concrete models, proxied from provider `/models` endpoints.

---

## Prompt management model

A **preset** is a named pipeline configuration: an ordered list of stages, each with `enabled`, `order`, `budget` (tokens), `role`, and a template.

Default stage list: `persona → scenario → user-persona → history → style`. The memory-recall stage slots in later without UI changes — it's just another stage.

UI: a reorderable toggle list, deliberately ST-prompt-manager-shaped so refugees feel at home — but with per-stage token budgets visible and a **"preview assembled prompt"** button rendering exactly what will be sent (the snapshot inspector component, pointed at a dry-run).

**Chains** (multi-step prompt sequences where step N's output fills a template slot in step N+1) are designed-for but not built: they fall out of the pipeline once `complete` exists. No chain UI in v0.

---

## DAG UI

- **Linear chat view** = walk from branch head to root. 90% of usage.
- **Swipes:** left/right on a leaf message cycles siblings; regenerating creates a sibling. Indicator dots.
- **Branching:** dropdown on the conversation header; long-press any message → "fork from here" creates a ref and switches to it.
- **Tree view v0:** indented list of branches with fork points. Graph visualization is a later toy, not weekend-critical.

## iPad specifics (Saturday work, not Sunday retrofit)

- PWA manifest + add-to-homescreen.
- `visualViewport` handling so the composer doesn't hide under the virtual keyboard (the classic Safari failure).
- `safe-area-inset` padding; touch targets ≥ 44px; zero hover-dependent UI.
- Literal swipe gesture on the last message for swipes.
- Test on the actual device by end of Saturday — this is where plans die.

---

## Deployment: cadance.jfave.com

hob deploys to the VPS **cadance.jfave.com** so it stays up when home internet doesn't. This **reverses DESIGN.md open question 6**, which leaned toward tabitha (home) *because hob holds `intimate` data*. Recording the trade-off, not hiding it:

- **Accepted:** availability beats physical custody for the substrate itself. A VPS provider (and anyone who compromises the box) can read the disk.
- **Mitigations, cheapest first:** full-disk / at-rest encryption on cadance; hob API not exposed publicly beyond TLS + keys (tailnet-only ingress is still an option even on a VPS); secrets in env, not repo.
- **Escape hatch kept open:** the realm model already tags every sensitive row. If the placement ever feels wrong, `intimate`-realm data can be pinned to owned hardware later (per-realm database was explicitly kept possible in DESIGN.md — ULIDs, no cross-realm FKs). Until kat moves onto hob, cadance holds nothing above `personal` anyway — the decision has a long fuse.

Weekend reality: develop on the laptop, deploy to cadance at the end; the iPad reaches either over the tailnet. Confirm Tailscale-on-iPad + SSE works before Saturday night.

---

## Weekend plan

**Friday night — the door.**
Rails skeleton · schema + RLS · Anthropic + one OpenAI-compat provider · model roles · non-streaming chat round-trip via curl.

**Saturday — the DAG and the stream.**
Message DAG, content addressing, branches · SSE streaming end-to-end · assembly pipeline (default stages) writing snapshots · Svelte shell streaming chat **working on the iPad by end of day**.

**Sunday — the porcelain.**
Swipes · branching UI · persona CRUD + preset editor · snapshot inspector · PWA polish.
*Stretch:* ST character-card PNG import (kat's parser extracts; if fiddly, JSON card import is 20 minutes and covers it).

**Cut line if behind:** one hardcoded persona, read-only default preset, no import. Must-keeps: streaming DAG chat + swipes + branches + snapshot inspector — that's the demo that proves the thesis.

---

## Open questions

1. **Public auth story** — bearer keys are fine for the household; sharing chatelaine publicly needs real sessions (device-scoped keys? OAuth? passkeys?). Not a weekend problem; is a pre-announcement problem.
2. **Licensing & repo split** — chatelaine as its own public repo from the start, or extracted from hob later? Lean: separate repo before first public commit; the API contract is the boundary anyway.
3. **API versioning scheme** — path (`/v1/`) vs header. Lean: `/v1/` path, boring and visible.
4. **Multi-provider params surface** — how much of each provider's param space to expose in the preset UI vs passthrough JSON. Lean: common params get controls, everything else is a raw JSON field per preset.
