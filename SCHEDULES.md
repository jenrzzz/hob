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

## Upkeep (next)

Not built yet. The second use this was made for: keep every app the
household runs on Coolify current, frameworks and dependencies alike,
so nothing goes crusty.

- **Which apps.** Discovered from Coolify: every application with a git
  source, read with hob's `COOLIFY_TOKEN`. A weekly `upkeep-discover`
  schedule reconciles the list into one `upkeep-<repo>` schedule per
  repo, staggered across the week. Each can be disabled like any other
  schedule, and a disabled one is never re-enabled by discovery.
- **The work.** A `forge.upkeep` mission (`{ kind, repo, branch }`) for
  the forge, built in a fresh Coder workspace like a capability build,
  with its own brief: upgrade the framework and dependencies within
  their constraints, run the repo's own tests, open one PR. Never touch
  secrets, deploy config, or the database.
- **Merging.** A PR of only patch and minor bumps whose checks pass is
  merged by the forge, and Coolify deploys it. A major version, a
  framework upgrade, a language-version change, or any code change
  beyond the lockfile stays a PR for a person.
- **What it needs first.** `Forge::Build` assumes it is building a hob
  capability, and the workspace image carries hob's toolchain only; the
  household's apps are Ruby (airing, mise, parboil, hob), Node
  (chatelaine, lumen), and Python (feedcurator). Dependabot covers
  mise, parboil, and hob already; upkeep should merge its green PRs
  rather than duplicate them.
