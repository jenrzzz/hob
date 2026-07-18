# hob

The household spirit: a personal LLM substrate. One backing service through
which every LLM interaction in the household flows — providers, conversations,
personas, memory, tools, compute, voice. See [DESIGN.md](DESIGN.md) for the
full design and [CHATELAINE.md](CHATELAINE.md) for the chat frontend.

## Running

Rails 8 API + Postgres 16 with pgvector. Row-level security enforces realm
clearance from day one, so the app must connect as a non-superuser role.

```sh
bin/rails db:prepare db:seed   # seeds print a dev API key once
ANTHROPIC_API_KEY=sk-... bin/rails server
```

Providers resolve API keys from env at request time (`ANTHROPIC_API_KEY`,
`HOB_OPENAI_COMPAT_KEY` + `HOB_OPENAI_COMPAT_BASE`). A model role with no
available provider fails with a 422, and new models are config rows in
`model_roles` — never code changes.

## API sketch

```
POST /v1/conversations                 { title, realm }
GET  /v1/conversations/:id?branch=main
POST /v1/conversations/:id/chat        { content, branch, persona, context, role }
                                       Accept: text/event-stream → SSE deltas
POST /v1/conversations/:id/branches    { name, at: <node hash> }   # fork = ref
GET  /v1/personas · /v1/models · /v1/snapshots/:hash
```

Auth is `Authorization: Bearer <key>`; `X-Hob-Clearance` can cap a request's
realm clearance downward (never up). Postgres RLS makes rows above the
request's clearance structurally invisible.
