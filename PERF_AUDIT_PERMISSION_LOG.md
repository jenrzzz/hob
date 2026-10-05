# Performance audit: permissions audit log (History / sentinel requests & petitions)

Scope: the iOS companion app's "History" screen (`clients/ios/Hob/Views/HistoryView.swift`),
which is the permission history / audit log — decided `SentinelRequest` and `Petition` rows,
filterable in the UI by agent, capability, and status.

Audited against `main` (HEAD at audit time: `a00b078`). No open PR adding server-side
permission-history filtering was found — `gh pr list --repo jenrzzz/hob --state all --search
<permission|filter|audit|sentinel>` turns up only unrelated merged work (`hob.capability.search`,
`hob.board.read`, etc.) and the currently-open PRs are all dependabot bumps. The filtering
described in the brief exists only as client-side `Picker` state in `HistoryView.swift`, not as
a branch in progress.

## Request path

- `GET /v1/sentinel/requests` → `V1::Sentinel::RequestsController#index`
  (`app/controllers/v1/sentinel/requests_controller.rb:34-41`), serialized at `:55-64`.
- `GET /v1/sentinel/petitions` → `V1::Sentinel::PetitionsController#index`
  (`app/controllers/v1/sentinel/petitions_controller.rb:32-39`), serialized at `:50-62`.
- Called from `clients/ios/Hob/Session.swift:106-111` (`history(days: 30)`), which fans out to
  `HobClient.requests(days:)` / `.petitions(days:)` (`clients/ios/Hob/HobClient.swift:37-51`,
  `85-90`), which only ever send `status` and `days` — never `agent` or `capability`.
- `HistoryView.swift:61-76` does all three filters (`agentFilter`, `capabilityFilter`,
  `statusFilter`) by `.filter { }` over the full in-memory array it already has.

Verified live: booted the app in `RAILS_ENV=test` against a local Postgres 16, seeded 200
`SentinelRequest` rows across 5 agents / 3 deciders / 25 days, and hit
`GET /v1/sentinel/requests?days=30` as a person (the same call the History screen makes) with
`sql.active_record` notifications subscribed. Result: **209 SQL statements for 200 returned
rows** (one request). Full query log and the `EXPLAIN ANALYZE` below are reproducible with the
snippet at the end of this report.

## Findings, highest impact first

### 1. The endpoint has no real pagination, and the client filters client-side after fetching everything

**Files:** `app/controllers/v1/sentinel/requests_controller.rb:34-39`,
`app/controllers/v1/sentinel/petitions_controller.rb:32-37`,
`clients/ios/Hob/Session.swift:106-111`, `clients/ios/Hob/HobClient.swift:37-51,85-90`,
`clients/ios/Hob/Views/HistoryView.swift:61-76,99-110`.

**Pattern:**
```ruby
rows = rows.since(params[:days].to_i.days.ago) if params[:days].present?
rows = rows.limit(100) unless params[:days].present?   # <- the only cap, and it's skipped here
```
The iOS History screen always calls with `days: 30` and never sends `status`/`agent` (and
there is no `capability` param at all — see #2 below), so this line always takes the
`since(...)` branch and the `limit(100)` is **never applied**. The only bound on result size is
calendar time, not row count. On top of that, `HistoryView` fetches that whole 30-day set and
then applies all three of its filter pickers (agent, capability, status) in Swift
(`filteredItems`, lines 66-72) — the server never sees those filters, so every load pays for
every settled petition and request in the window regardless of what's actually being looked at.

**Why it's slow:** `sentinel_requests` is explicitly a never-deleted audit log (see the comment
at `app/models/sentinel_request.rb:1-2`), so "everything in the last 30 days" only grows over
the life of the household's hob instance. Every History screen open — and every pull-to-refresh
— re-downloads and re-serializes the full window, then throws most of it away once the user
picks a filter.

**Estimated impact:** highest. This is the only part of the pattern whose cost scales with total
historical volume rather than a fixed page size; it also drives #2's N+1 linearly (more rows
fetched = more N+1 queries) and is the only one of these issues actually visible in the iOS UI
today as "slow to load."

**Fix:**
- Add a `capability` filter to both `index` actions, mirroring `status`/`agent`:
  `rows = rows.where(capability: Capability.find_by!(name: params[:capability])) if params[:capability].present?`
  (`requests_controller.rb`; petitions uses the `capability_name` string column, so
  `rows.where(capability_name: params[:capability])` there).
- Have `HistoryView` pass `agentFilter`/`capabilityFilter`/`statusFilter` through to
  `session.history(...)` → `HobClient.requests(status:days:)` as real query params instead of
  filtering the fetched array, and extend `historyQuery` in `HobClient.swift:85-90` to also emit
  an `agent`/`capability` item.
- Apply a hard page size (e.g. `rows.limit(100)` unconditionally, or real keyset pagination
  keyed on `created_at`/`id`) even when `days` is present, and add a "load more" affordance in
  `HistoryView` for anyone paging back further.

### 2. N+1 query on `decider` in both serializers

**Files:** `app/controllers/v1/sentinel/requests_controller.rb:35` (`.includes(:capability,
:principal)`) and `:60` (`decider: row.decider&.name`); `app/controllers/v1/sentinel/
petitions_controller.rb:33` (`.includes(:principal)`) and `:66` (`decider: row.decider&.name`).

**Pattern:** `decider` (`belongs_to :decider, class_name: "Principal"`,
`app/models/sentinel_request.rb:16`) is read in the serializer but never added to `includes`.

**Measured:** in the reproduction above, the main query plus the `:capability`/`:principal`
preloads cost 7 queries total; the remaining **200 of 209 queries** (one per row) were
`SELECT "principals".* FROM "principals" WHERE "principals"."id" = $1 LIMIT $2` — the `decider`
lookup, fired once per settled row (every row in History is settled, i.e. has a decider, by
construction — `HistoryView` filters to `!needsPerson`).

**Why it's slow:** classic N+1. Each extra query is cheap in isolation but round-trips the
Postgres connection once per row; at the current unbounded-by-days result size (#1) this is the
single largest contributor to request latency and connection-pool pressure, and it scales
directly with however many rows #1 lets through.

**Estimated impact:** very high — it's 95%+ of the query count in the measured request, and will
dominate wall-clock time once network round-trip per query is counted (not just planning/exec
time).

**Fix:** add `:decider` to both `includes` calls:
```ruby
rows = scope.recent.includes(:capability, :principal, :decider)   # requests_controller.rb:35
rows = scope.recent.includes(:principal, :decider)                # petitions_controller.rb:33
```

### 3. No standalone index on `created_at` for `sentinel_requests` / `petitions`

**Files:** `db/structure.sql` — `sentinel_requests` indexes at lines 2001-2032
(`index_sentinel_requests_on_capability_id`, `_on_decider_id`, `_on_principal_id`,
`_on_principal_id_and_created_at`, `_on_status_and_created_at`); `petitions` indexes at
1777-1822 (same shape: `_on_capability_name`, `_on_decider_id`, `_on_principal_id`,
`_on_principal_id_and_created_at`, `_on_status_and_created_at`). There is **no** plain
`created_at`-only index on either table, and no migration in `db/migrate/` adds one.

**Pattern:** the History screen's actual query, run as a person with no `status`/`agent`
filter (`scope` in `requests_controller.rb:51-53` returns `SentinelRequest.all` for a
non-agent principal), reduces to:
```sql
SELECT * FROM sentinel_requests WHERE created_at >= $1 ORDER BY created_at DESC
```
Neither composite index has `created_at` as its leading column, so Postgres can't use either one
for a `created_at`-only predicate — it has to use a sequential scan.

**Verified with EXPLAIN ANALYZE** (10,000-row `sentinel_requests`, 30-day window ≈ half the
table):
```
Sort  (cost=78442.23..78446.09 rows=1543 width=306) (actual time=57.511..57.768 rows=5010 loops=1)
  Sort Key: sentinel_requests.created_at DESC
  ->  Seq Scan on sentinel_requests  (cost=0.00..78360.52 rows=1543 width=306) (actual time=0.118..54.664 rows=5010 loops=1)
        Filter: (((SubPlan 1) <= app_clearance_rank()) AND (created_at >= (now() - 'P30D'::interval)))
        Rows Removed by Filter: 4990
        SubPlan 1
          ->  Index Scan using realms_pkey on realms (actual time=0.001..0.001 rows=1 loops=10000)
Execution Time: 58.383 ms
```
Every row in the table is read and RLS-checked (the `realm_visibility` policy's per-row subplan
runs once per row scanned — 10,000 times here) before the `created_at` filter and sort even get
applied.

**Why it's slow:** `sentinel_requests` is, by design, never deleted
(`app/models/sentinel_request.rb:1-2`). A sequential scan's cost is linear in *total* table size,
not in the size of the 30-day window being requested, so this query gets slower every week the
household runs hob, independent of how much the person actually looks at. 58ms at 10k rows
(a plausible few-months-in count for a single household) will keep climbing.

**Estimated impact:** high, and compounding with #1 — once #1 is fixed to always `limit`, this
scan still has to touch the whole table before the `ORDER BY ... LIMIT` can short-circuit it
(Postgres can't use `LIMIT` to stop a `Seq Scan` + `Sort` early).

**Fix:** add a migration with a plain `created_at` index on both tables:
```ruby
add_index :sentinel_requests, :created_at
add_index :petitions, :created_at
```
(`algorithm: :concurrently` in production, matching this repo's existing migration style). This
lets `WHERE created_at >= ? ORDER BY created_at DESC` — the exact shape both `since` + `recent`
produce when no `status`/`agent` filter narrows the composite indexes — use an index-only
backward scan instead of a full-table scan.

## Pagination summary (requested in the audit brief)

- **Does it paginate?** Only incidentally: `limit(100)` applies solely when `days` is *absent*.
  The iOS client always sends `days: 30`, so in practice the endpoint the app actually calls is
  unpaginated (see #1).
- **Page size:** 100 rows, but only reachable from a client that omits `days` — not exercised by
  the shipped app.
- **Total counts:** not computed anywhere in these actions (no `.count` call) — this part is
  fine; the response is just the mapped row array itself, no expensive count query to fix.

## Reproduction

```ruby
# RAILS_ENV=test bundle exec rails runner, after `include HobWorld; seed_world!; clearance!("intimate")`
10_000.times do |i|
  SentinelRequest.create!(principal: Principal.first, capability: Capability.first,
    arguments: {}, surface: "test", realm: "household", status: "completed", decision: "allow",
    decided_by: "policy", decided_at: 1.hour.ago, executed_at: 1.hour.ago, result: { "ok" => true },
    created_at: (i % 60).days.ago)
end
ActiveRecord::Base.connection.execute(
  "EXPLAIN ANALYZE SELECT * FROM sentinel_requests WHERE created_at >= NOW() - INTERVAL '30 days' ORDER BY created_at DESC"
).each { |r| puts r.values.first }
```
The 209-query count was captured the same way, subscribing to `sql.active_record` around
`get "/v1/sentinel/requests", params: { days: 30 }, headers: auth` in an
`ActionDispatch::IntegrationTest` with 200 seeded rows across 5 agents and 3 deciders.
