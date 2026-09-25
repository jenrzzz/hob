# Rebase conflict: hob.board.post onto main (hob.board.read merged)

Attempted: rebase `origin/forge/hob-board-post-qhjae3` (PR #30, `hob.board.post`)
onto `origin/main`, which now contains PR #29 (`hob.board.read`, commit
`71d6f2a`). Aborted — this is a design disagreement, not a mergeable text
conflict, so I stopped rather than guess at a resolution.

## The two schemas

Both branches independently create a `board_posts` table (migration name
clash aside), but the row shapes disagree on how a post's authorship is
recorded:

- **hob.board.read** (merged, `db/migrate/20260924180000_create_board.rb`,
  `app/models/board_post.rb`): every post has both `sender_agent` (must be
  an agent Principal) **and** `sender_principal` (must *not* be an agent —
  "the person the agent spoke for", per the model comment). Both columns
  are `null: false`. The read handler's JSON output includes
  `sender_principal` on every post (`app/services/sentinel/native/board_read.rb:67`)
  and this is asserted directly in `test/services/native/board_read_test.rb`
  and documented in `MUSE.md`/`SENTINEL.md` as part of hob.board.read's
  merged, public response contract.

- **hob.board.post** (PR #30, `db/migrate/20260924190000_create_board_posts.rb`,
  `app/models/board_post.rb`): every post has `sender_agent` only, plus a
  `surface` string column (the request's originating channel label, e.g.
  `"cli"`). There is no `sender_principal` at all.

## Why this isn't just a naming difference

hob.board.post's commit message explains the omission directly: it has "no
separate 'who the agent speaks for' column, since nothing in the request
context can derive it." I confirmed this by reading the request/execution
path:

- `Sentinel::Executor.as_agent` (`app/services/sentinel/executor.rb`) sets
  `Current.principal` to the calling **agent** and `Current.surface` to the
  request's `surface` string column — a free-text channel label (schema:
  `sentinel_requests.surface character varying NOT NULL`), not a reference
  to a Principal.
- `Principal` has no static "this agent speaks for that person" association
  anywhere in the schema (unlike, say, `CalendarContributor`, which is an
  explicit many-to-many the caller must already be registered in). An
  agent's "on behalf of whom" is inherently per-request, not derivable from
  identity alone.
- hob.board.post's own design principle, stated in its handler comment and
  enforced by its input schema (no `additionalProperties`), is that the
  author is "always the calling agent's authenticated identity ... never an
  argument." Adding a `sender_principal` (or `for`/`on_behalf_of`) argument
  to satisfy read's schema would directly contradict that principle — it
  would let a caller assert an arbitrary "spoke for" person with no
  verification.
- Loosening read's schema instead (making `sender_principal` optional, or
  dropping it) would change hob.board.read's already-merged response
  contract, which the task asked me to keep intact, and would break its
  existing tests and documented output shape.

So the fix isn't a mechanical merge of two migrations/models — it needs a
product decision on one of:

1. Give agents a real, verifiable notion of "who I'm speaking for" in the
   request path (e.g. a `CalendarContributor`-style registration, or an
   explicit-and-verified argument), so hob.board.post can populate
   `sender_principal` honestly; then both capabilities can share
   `sender_agent` + `sender_principal` on one `board_posts` table.
2. Decide `sender_principal` was premature on the read side and drop it
   from the merged schema/contract (migration + model + handler + tests +
   docs), replacing it with something a write path can actually supply,
   such as `surface`.
3. Some other reconciliation of "who is the human behind this post" that
   neither existing branch currently implements.

## What I did / didn't do

- Did not modify `origin/forge/hob-board-post-qhjae3`.
- Created and then deleted a scratch `post-rebase` branch used only to run
  `git rebase origin/main` and inspect the conflict; no commits from it
  were kept.
- Left `agent/job-20260924-1956-o9ys` (the branch I started on) exactly as
  it was — clean, at its original commit, no squash-merge performed.
