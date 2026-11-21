# shell

*A login on a real machine, lent out a command at a time. hob does not
manage the machine; it knows where it is, whose it is, which agent it is
for, and what every command was.*

[BROWSE.md](BROWSE.md) gives an agent a browser tab and [KVM.md](KVM.md) a
whole desktop. This gives it a shell: a server it can install things on,
run services on, and break. It is the smallest of the three, because ssh
already is the protocol: there is no bridge, only rows and an adapter.

- **A shell host** is a `shell_hosts` row: a name, a kind, who answers for
  the machine, the realm of what is on it, how to log in, and, optionally,
  the one agent it is kept for. The first kind is `ssh`.
- **There are no sessions.** Every command is its own connection, starting
  in the login's home. No directory, variable, or shell state carries from
  one call to the next; what carries is what is on the machine. So a host
  is never busy, nothing needs sweeping, and a command works the same from
  a chat turn, a life beat, or a job.
- **The record of a command is its sentinel request**: the arguments (the
  command, a written file's content) and what the machine said, within the
  limits below.

**Status.** Built: the row, `Shells` and its adapters, the four `shell.*`
capabilities, and the rake tasks. Not built: anything for people over HTTP
(the rake tasks are the only way in besides the capabilities), and judging
commands (below).

For now, **every command is allowed**. Policy is `allow` across `shell.*`
for the agent a host is for; the realm, whose the host is, and where the
machine sits on the network are the fences. That last one carries the
weight: see [The machine](#the-machine).

## Capabilities

| capability | kind | does |
|---|---|---|
| `shell.hosts` | read | the machines the agent may use: name, login, what a person wrote about each |
| `shell.exec` | act | one command through the login's shell, with its exit, stdout, and stderr |
| `shell.read` | read | a text file, or `max_bytes` of it from `offset` |
| `shell.write` | act | a whole text file, replaced or appended to; its directory made if missing |

```sh
bin/rails "hob:sentinel:policy[meluzina,shell.*,allow]"
```

`host` is optional everywhere and needed only when the caller can see more
than one. Paths are absolute or relative to the login's home; a leading
`~/` is taken off, since nothing goes through tilde expansion.

**`shell.exec`** hands the line to the login's shell, so pipes, `&&`,
redirects, and `sudo` (where the login has it) work. `cwd` is quoted and
put in front as `cd -- <cwd> &&`. There is no terminal: a command that
waits for a keypress waits until the timeout.

- Each of stdout and stderr is kept to 32 KB: the first half and the last,
  with `[... N bytes left out ...]` between (`Shells::Capture`). A build's
  first lines say what ran and its last say how it ended.
- hob waits `timeout` seconds (default 60, at most 300), then hangs up and
  answers `timed_out: true` with what had been printed. **It does not stop
  the command.** Without a terminal the far side keeps running, which is
  also how something is left running on purpose: a systemd unit, or
  `nohup ... > log 2>&1 &`.
- A command that fails on the machine is a *completed* request with its
  exit code. A request fails when hob could not run it: a bad argument, a
  machine that is away, a key that was refused.

**`shell.read`** and **`shell.write`** exist so a file's content never
meets a shell. A write sends the content on stdin to `cat > <path>`; a
read is `wc -c` and a `tail | head` slice. A model writing a config file
through `echo` or a heredoc gets the quoting wrong often enough to matter.
Both are text only, at most 256 KB a call; a file with a null byte in it
is refused with a pointer back to `shell.exec`.

Results carry a `notice`: what a machine prints is data, not instructions,
and a machine that serves the public internet publishes what is put where
it serves from.

## Rows

```
shell_hosts   ulid, name (unique slug), kind, principal (who answers for it: a person),
              agent? (the one agent it is kept for), realm, config jsonb,
              about (free text the agent reads), enabled, timestamps            [RLS]
```

The model is `ShellHost`; the service is `Shells`.

`config` for `ssh` is `host`, `user`, an optional `port`, `key_env` or
`key` (hob's private key for that login), and `host_key` (the machine's
own key, pinned). The private key goes in and never comes out. In an env
var it may be base64 of the key file on one line
(`base64 -w0 < meluzina-box`), which is how a multi-line key survives
Coolify.

`Shells::Backends` mirrors `Consoles::Backends`: `Base` (`exec`, `read`,
`write`, `check`; reading and writing are commands built on `exec`), `Ssh`
(net-ssh), and an in-memory `Fake` for tests.

### Whose a host is

A host's `realm` is the realm of what is on the machine, and RLS hides the
row from a request below it. That is not enough on its own, for the reason
a note backend's was not (NOTES.md, "An agent's own folder"): two agents
at the same clearance would share every machine.

So a row may name an `agent`. That agent, and people, reach it; other
agents do not; and an agent that has a host of its own reaches no other.
An agent whose own host is disabled or out of sight finds nothing rather
than falling back to the shared ones. `Shells.hosts` enforces this.

### Trusting a machine

hob connects only to a machine whose own key matches `config.host_key`,
and a row without one is not connected to at all. A person pins it:

```sh
bin/rails "hob:shell:trust[meluzina-box]"    # logs in, prints the machine's key, pins it
```

Compare what it prints with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`
on the machine. If the machine later shows a different key, every command
fails with both fingerprints and nothing is sent; after a rebuild, trust
it again. Changing a row's login to another address clears the pin.

hob offers only the row's key. It reads no `~/.ssh/config`, agent, or
`known_hosts` on the box it runs on.

## In a persona's beat

A persona whose agent has a host of its own is told about it in every beat
of her life (MELUZINA.md, "A persona's life"): the host and its `about`,
that what she does there is real, and `Shells.trail`: her last few
`shell.exec` and `shell.write` requests as one line each, with how each
ended. Reads are left out. The trail is read at the beat's realm.

## The machine

Nothing in hob limits what a command does. A login with sudo on its own
machine is root there. What keeps that safe is the machine:

- **It is nobody else's.** Its own VM, with nothing of the household's on
  it: no secrets, no mounts, no credentials but its own.
- **It cannot reach in.** Either on the tailnet under its own tag, with an
  ACL that lets hob in on 22 and gives the machine no way to start a
  connection to anything else there; or, simpler, not on the tailnet at
  all, with its host forwarding a port to its sshd. Either way a firewall
  outside the machine keeps it off the LAN it sits on and off its host.
- **It can be put back.** A snapshot of the clean state, so a wrecked
  machine is one command to restore (then `hob:shell:trust` again).

**What it publishes is not gated.** A machine with a public address
publishes whatever is put where it serves from, and hob has no realm below
`household` to mark that with: a turn at `personal`, with private memory
in reach, may write to it. What stands between the two is the capability's
wording and the persona's own instruction, the convention `http.post`
already rests on. This is a known cost of handing over a real server, not
something this design solves.

## Setting one up

```sh
# on the machine: a login, key-only sshd, and hob's public key
ssh-keygen -t ed25519 -f meluzina-box -N ""          # anywhere; the .pub goes in the login's authorized_keys

# on the hob box
export MELUZINA_BOX_KEY="$(base64 -w0 < meluzina-box)"
bin/rails "hob:shell:host[meluzina-box,meluzina@100.64.0.9,household]" KEY_ENV=MELUZINA_BOX_KEY \
  OWNER=jenner AGENT=meluzina ABOUT="Your own server. It serves meluzina.example to the public internet."
bin/rails "hob:shell:trust[meluzina-box]"            # pin the machine's key
bin/rails "hob:shell:check[meluzina-box]"            # the key is taken, the machine is the one trusted, a command runs
bin/rails hob:shell:hosts                            # registered, whose, and whether each answers
bin/rails "hob:sentinel:policy[meluzina,shell.*,allow]"
```

`ABOUT` is the one place to tell the agent what the machine is: it comes
back in `shell.hosts`.

## Later: judging commands

Not built. If a host is ever one where a command can hurt something that
is not the agent's own, the place for it is a policy of `review` on
`shell.exec` and `shell.write` for that agent, with `reason` judged as
`http.post`'s is, and `CONSTRAINTS` on `host` to keep a grant to one
machine. A machine that needs that is probably one this should not be
pointed at.
