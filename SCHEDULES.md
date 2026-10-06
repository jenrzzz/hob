# schedules

*The hearth keeps the hours. Nobody asks the fire when it is morning.*

hob had no clock. The ward kept time by asking (every ingest and status
read swept, and a Coolify scheduled task swept hourly), its worker ran
its own `--every` timer on agentbox, and anything else that wanted
"every Monday" had to keep its own cron somewhere. A **schedule** gives
hob the clock instead: a mission template and a cron line, and when it
comes due hob queues the mission for its assignee exactly as if someone
had asked just then.

Missions are already how hob says "do this" to anything that polls: the
ward worker, the forge, Muse, a surface's worker. So a schedule needs
nothing new from whoever does the work. It leases, heartbeats,
completes, and the result goes back to whoever made the schedule, as
with any mission.

## The clock

Solid Queue runs it. `config/recurring.yml` holds hob's own jobs, never
the household's schedules:

| job | when | does |
|---|---|---|
| `ScheduleTickJob` | every minute | fires every schedule that is due (`Schedule.tick!`) |
| `WardSweepJob` | hourly at :07 | the ward's sweep (WARD.md), formerly a Coolify scheduled task |
| `clear_solid_queue_finished_jobs` | hourly at :12 | Solid Queue's own housekeeping |

The queue lives in its own database (`hob_production_queue`, schema in
`db/queue_schema.rb`, loaded by `db:prepare` like the rest), and the
jobs run in their own process, `bin/jobs`, never inside Puma: a stuck
job must not take the API with it, and the API's deploys must not drop
the clock mid-tick. Development and test use the async and test
adapters; `bin/rails hob:schedules:tick` fires what is due by hand.

## A schedule

| field | |
|---|---|
| `name` | lowercase, digits, `.`, `_`, `-`; unique per creator (hob's own included) |
| `cron` | a cron line (`0 7 * * 1-5`) or fugit's words (`every day at 7am`), read in `time_zone` |
| `time_zone` | IANA; `HOB_TIME_ZONE` for ones made by rake, `Etc/UTC` otherwise |
| `assignee` | the principal each mission goes to |
| `created_by` | who made it: a person, an agent, or nobody (hob itself, from a rake task) |
| `realm` | of every mission it queues; the assignee must be cleared for it |
| `title`, `brief`, `payload`, `priority` | the mission |
| `enabled` | a disabled schedule has no `next_fire_at` and never fires |

Three rules make it safe to leave alone:

- **It never stacks.** If the last mission a schedule queued is still
  queued or leased when it comes due, the firing is skipped and counted
  (`skipped_count`, `last_skipped_at`). The first skip of a streak pings
  whoever made it (the household, for hob's own) with the stuck
  mission's id; a worker that stopped leasing must not look like a quiet
  week. The next skip after a fire starts a new streak.
- **It never catches up.** hob down for three days means one mission
  when it is back, then the next firing after now. A backlog of
  identical audits helps nobody.
- **It fires once.** The tick takes due rows one at a time with
  `FOR UPDATE SKIP LOCKED`, so two job processes never fire one schedule
  twice.

Schedules are realm-scoped rows under the same RLS policy as missions.
Each mission carries its `schedule` id (in `GET /v1/missions` and the
lease), so a worker can tell a scheduled run from an asked-for one.

## Agents

Three native capabilities (SENTINEL.md), granted by policy like any
other:

| capability | kind | does |
|---|---|---|
| `hob.schedule.create` | act | a schedule for the agent itself or another principal, at the request's realm; the same name replaces it |
| `hob.schedule.list` | read | the agent's own schedules and the ones assigned to it |
| `hob.schedule.cancel` | act | end one the agent made |

An agent's schedule fires at most every 15 minutes, and an agent keeps
at most 25. Scheduling a mission for another principal is the same power
as `hob.mission.create`, so the same policy thinking applies:

```sh
bin/rails "hob:sentinel:policy[muse,hob.schedule.*,review]"
```

## By hand

```sh
bin/rails "hob:schedules:set[name,0 7 * * *,assignee]" TITLE='...' BRIEF='...' PAYLOAD='{"kind":"..."}' \
  REALM=household TZ_NAME=America/Los_Angeles PRIORITY=0 DESCRIPTION='...' ENABLED=0|1
bin/rails hob:schedules:list
bin/rails "hob:schedules:drop[name]"            # BY=<principal> for one an agent made
bin/rails hob:schedules:tick                    # fire what is due now, without bin/jobs
```

`set` creates or updates, so re-running it retimes a schedule in place.

## The ward on the clock

The ward's weekly audit is a schedule: `ward-exposure`, owned by hob,
queuing the same `ward.audit` mission `ward.audit.run` does, for the
ward worker. `hob:ward:setup` makes it; `hob:ward:schedule[exposure]`
makes or retimes it without rotating the worker's key. The worker then
runs `ward.py work` without `--every`, and the stale-check alarm still
catches a clock that stopped.

## Upkeep

Keep every app the household runs on Coolify current, frameworks and
dependencies alike, so nothing goes crusty.

**Which apps.** `UpkeepDiscoverJob` (Sundays at 1am, and
`bin/rails hob:upkeep:discover`, `DRY=1` to look first) reads Coolify's
applications with hob's `COOLIFY_TOKEN` and keeps those built from a
GitHub repo whose owner is in `HOB_UPKEEP_OWNERS` (default `jenrzzz`):
not a Docker image, not someone else's project. Each repo, once however
many apps it backs, gets two hob-owned schedules for the forge:

| schedule | when | scope |
|---|---|---|
| `upkeep-<repo>` | weekly, 2 to 5am on the repo's own weekday | `minor` |
| `upkeep-<repo>-major` | monthly, 3am on the repo's own day | `major` |

A schedule is known by the repo and scope in its payload, not by its
name. Where two repos would share a name (`alice/site` and `bob/site`,
or `x`'s major and `x-major`'s minor), the newcomer's carries its owner,
`upkeep-<owner>-<repo>`, and failing that the repo's checksum too; a
schedule that already has a name keeps it. Discovery owns the payload
(repo, branch); a person owns the timing and the switch, so a retimed or
disabled schedule stays that way. A repo
that leaves Coolify has its schedules disabled, not deleted.

**The work.** A `forge.upkeep` mission (`{ kind, repo, branch, scope }`,
priority -1 so capability builds go first) is built like a capability:
in a fresh Coder workspace with the same image, by `Forge::Upkeep`
(`lib/forge/upkeep.rb`). It clones the repo with `gh`, hands Claude Code
a brief for the scope, then decides for itself what happens next:

- **minor.** First, Dependabot's open PRs that bump one dependency within
  its major and whose checks passed are merged. Then the implementer
  takes everything to its newest patch or minor release, lockfiles only,
  holding back whatever breaks the tests, and lists the majors waiting in
  `.forge/MAJORS.md`. The forge reruns the repo's tests itself, with a
  plan it reads off the repo (`bundle exec rspec` or `bin/rails test`,
  `npm test`, `uv run pytest`), pushes `upkeep/minor`, and opens or
  refreshes the PR. It **merges** only when every one of these holds:
  only lockfiles changed (`Gemfile.lock`, `package-lock.json`, `uv.lock`,
  `poetry.lock`); no version in them crossed a major (below 1.0, a minor
  counts for what the app depends on itself: the `Gemfile`'s gems, or
  `package.json`'s packages, and every Python one, since the forge cannot
  tell those apart; a transitive `reline` 0.6 → 0.7 does not hold a PR);
  its own test run passed; and no GitHub check failed (pending ones are
  waited on for half an hour). Otherwise the PR waits, with the reasons in
  the mission's result. A run that changes nothing is `current` only if the
  stack's own tools agree (`bundle outdated`, `npm outdated`, `uv lock
  --upgrade --dry-run`, within the app's requirements and majors); if
  they find something newer, or cannot run (a Ruby the sandbox lacks),
  the mission fails with what they said and what the implementer said, so
  an implementer that gave up quietly does not pass for a repo with
  nothing to do.
- **major.** One framework, runtime, or major upgrade, with the code
  changes it needs, on `upkeep/major`. Never merged by the forge.

A repo with no dependency manifest at its root (`Gemfile`,
`package.json`, `pyproject.toml`, `requirements.txt`, `uv.lock`,
`poetry.lock`), a static site or a bare Dockerfile, is `current` at
once, with no implementer run and nothing to hear about; and a major run
that finds nothing behind commits nothing and is `current` too, not a
refusal.

Each scope has one branch per repo, rebuilt from the base and
force-pushed on every run, so an unmerged PR is refreshed in place, not
joined by another. A merge to an app's branch is a deploy: Coolify
builds it as for any push.

**Hearing about it.** Missions from hob's own schedules report to the
household (`Notify.person`): always when they fail, and when they
complete only if the worker sets `notify` in its result. Upkeep sets it
for a PR left for review, not for one it merged or a repo already
current. The result carries the repo, status (`current`, `merged`,
`review`), the PR, why it needs review, what moved, the forge's test
run, the Dependabot PRs merged, the majors waiting, and what the
implementer said.

```sh
bin/rails hob:upkeep:discover                 # DRY=1 to only show
bin/rails "hob:upkeep:run[airing]"            # now, as if due; "hob:upkeep:run[jenrzzz/airing,major]"
bin/rails "hob:schedules:set[upkeep-airing]" ENABLED=0   # leave one alone
```

**Limits.** The workspace image (`agent-workspace-hob`, in the infra
repo) carries what the household's apps declare in their Dockerfiles and
CI: one Ruby (hob's, with no version manager, so an app's `.ruby-version`
is ignored and only a Gemfile `ruby` line could refuse it), Node 22,
Python 3.12 and 3.14, PostgreSQL 16 with pgvector, libvips, ImageMagick,
ffmpeg, the sqlite3 CLI, and Chromium for system specs. A new app that
needs more (Redis, MySQL, another system library) fails in the sandbox
until the image has it, and the implementer refuses rather than guess;
those PRs wait for a person. The sandbox's GitHub token needs push and
merge on every repo discovery finds. Branch protection that requires a
review stops the merge; the PR waits, which is the point of it.
