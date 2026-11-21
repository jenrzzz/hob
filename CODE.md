# code

*An agent hands a piece of building to Claude Code, which does it in a
sandbox and pushes it to a repo that is the agent's own. hob carries the
brief there and the report back.*

[SHELL.md](SHELL.md) gives an agent a machine. Writing a program on it
through `shell.write`, a turn at a time, is slow and is paid for by the
token. The forge (SENTINEL.md, "The forge") already runs Claude Code
headless on agentbox, signed in with a subscription, for hob's own
capabilities and for upkeep. A **commission** is the same loop pointed at
an agent's own work.

- **A code repo** is a `code_repos` row: a GitHub repo, the one agent it
  is kept for, who answers for it, and the realm of what is in it.
- **A commission** is a mission for the forge with `kind:
  forge.commission`: a title, a brief in the agent's words, and a branch.
  The forge clones the repo in a fresh workspace, runs Claude Code on the
  brief, commits what it left, and pushes the branch. There is no pull
  request and nobody reviews it: the repo is the agent's workshop.
- **It is asynchronous.** `code.start` returns at once. The agent reads
  how it went with `code.status`, or in its next beat.
- **The agent deploys.** Claude Code cannot reach the agent's machine. The
  agent pulls the branch there and runs what arrived, with `shell.*`.

**Status.** Built: the row, `Commissions`, `code.start` and `code.status`,
`Forge::Commission`, the beat's lines, and the rake tasks. The sandbox
side (a secrets directory of its own) is infra's; see
[The sandbox](#the-sandbox).

## Capabilities

| capability | kind | does |
|---|---|---|
| `code.start` | act | queue a commission: `title`, `brief`, optional `branch` and `repo` |
| `code.status` | read | the agent's last ten commissions in brief and its repos; with `id`, one in full |

```sh
bin/rails "hob:code:repo[meluzina-box,jenrzzz/meluzina-box,personal]" AGENT=meluzina OWNER=jenner \
  ABOUT="Cloned at ~/workshop on your machine: git pull there"
bin/rails "hob:sentinel:policy[meluzina,code.*,allow]" LIMITS='{"per_day":6}'
bin/rails hob:code:repos                    # the repos, and the last ten commissions
```

A brief is 40 to 20,000 characters and has to stand alone: Claude Code
sees it and the repo and nothing else, and cannot ask. An agent may have
two commissions under way at once. A commission's states, as the agent
reads them, are `waiting`, `working`, `done` (with `outcome: pushed` or
`nothing`), `failed`, and `cancelled`.

The result is what `Forge::Commission#call` returns: the branch, the
commits (`abc1234 subject`), how many files changed, Claude Code's last
message as `summary` (at most 4,000 characters), and its cost. In brief,
`said` is the first line of that message; in full, all of it.

`ABOUT` on the row is where to tell the agent where the repo is cloned.

## In a persona's beat

A persona whose agent has a repo and may start commissions is told so in
every beat (`PersonaLife::Beat#commissions_section`): that anything bigger
than a few lines goes to Claude Code, and how its last three commissions
went. A commission finishes long after the turn that started it, and a
beat is where she finds out.

## The build

`Forge::Commission` (`lib/forge/commission.rb`), run by `bin/forge build`
inside the workspace:

1. **Guard.** If the workspace's GitHub token can push to the forge's own
   repo, refuse. See below.
2. **Clone** the repo; check out the branch (from `origin` if it exists
   there, otherwise new from the default branch). The brief goes in
   `.forge/BRIEF.md`, which git is told to ignore.
3. **Claude Code**, headless, `acceptEdits`, with the tools a small
   project is built and tried with. It may commit and may not push.
4. **A refusal** (`.forge/REFUSED.md`) fails the commission with its text.
5. **Leftovers are committed** under the commission's title, in the
   agent's name.
6. **Leak check.** If any secret the build can see (a token in its
   environment, a file under `/secrets`) appears in what would be pushed,
   nothing is pushed.
7. **Push** `HEAD` to the branch. Never forced.

## The sandbox

A brief is written by an agent, and an agent may have read anything: a
web page, a message, a file on a public server. So the brief is untrusted
in a way a steward's spec or an upkeep run is not, and a commission must
not run beside the forge's own GitHub token, which can write to the
household's repos.

- **Its own secrets.** The forge creates a commission's workspace with
  the template parameter `secrets=secrets-commission`
  (`FORGE_COMMISSION_SECRETS`), so `/secrets` there is a different host
  directory: a fine-grained GitHub token with contents read and write on
  the agent's repo and nothing else, and the Claude token. A template
  without the parameter fails the create, and the commission with it.
- **The guard** is the same rule checked from inside: a token that can
  push to the forge's repo refuses the build before Claude Code starts.
  The test is git's write handshake against that repo, which GitHub
  answers 200 only to a token that may push, and which changes nothing.
  (The REST API's `permissions.push` reports what the token's owner may
  do, not the token.) A check that cannot be made is a refusal.
- **What is left.** Claude Code still holds the Claude token while it
  works, and a brief that talked it into misusing that is caught only by
  the leak check and the sandbox's egress allowlist (GitHub, Anthropic,
  package registries). The code it writes is then run by the agent on its
  own machine, which has the open internet. That machine is fenced from
  the house (SHELL.md, "The machine"), which is what that fence is for.

**Realms.** The mission is created at the request's realm, and the brief
is whatever the agent wrote. It leaves hob for the sandbox and then for
GitHub. As with `shell.*`, nothing gates what an agent puts in a brief
but its own instruction and the capability's wording.
