# egress

*A second front door. The house has one address it is known by; this is
another, rented, that it can choose to leave by.*

**Status: proposal.** Nothing here is built. The household has a NordVPN
dedicated IP: one address that is only ours, instead of a shared exit
that a thousand strangers have already gotten flagged. Its first use is a
person's: a VPN that sites do not treat as sketchy. This collects what
hob could do with it, so the choice is easier once a need turns up.

## Why a dedicated IP is different

A shared VPN exit is anonymous and burned: captchas, blocks, "unusual
activity" on every login. A dedicated IP is the opposite on both counts.
Sites see the same address every time, so it builds a reputation (good,
if we are polite) and it can be put on someone's allowlist. And it is
traceable to us: anything that leaves by it is the household's, as
plainly as the house's own address. Every idea below has to live with
that.

## Ideas

### 1. The VPN as a sidecar, reachable only from inside

Whatever else happens, the tunnel runs in one container on cadance
(gluetun, or bubuntux/nordlynx), connected to the dedicated-IP server,
with a proxy (SOCKS5 or HTTP CONNECT) on an internal Docker network. No
published port, not bound to the tailnet or the public address. An open
proxy on a dedicated IP is worse than one on a shared IP: whatever anyone
sends through it is ours. (The ward has notes about a nordlynx proxy on
cadance:8888 answering publicly; whatever that is, it is the thing not to
repeat.)

Dedicated IPs work over OpenVPN configs from Nord's site, and over
NordLynx/WireGuard in the app; a container wants a WireGuard private key
pulled from Nord's API. Check Nord's current docs before relying on
either.

### 2. A tailnet exit node that leaves by the dedicated IP

The person's case, done once for every device. A Tailscale node in a
container whose traffic goes through the sidecar (`network_mode:
service:gluetun`), advertised as an exit node named something like
`nord`. A laptop, phone, or iPad then gets the less-sketchy VPN by
picking that exit node from the Tailscale menu: no Nord app, no Nord
device slot, and it stays on the tailnet while it does.

Agents never use this; it is for people. But it is the same sidecar as
everything below, so the tunnel is set up and watched in one place.
Worth checking that Tailscale's own control and DERP traffic is happy
going out through Nord, and that the exit node's ACL limits it to the
household's people.

### 3. Named egress routes for `http.get` and `http.post`

`Web` (HTTP.md) connects straight from the box today, and on purpose
takes no proxy from the environment. A route would be named, not
ambient:

```
HOB_HTTP_EGRESS=nord=socks5://nordvpn:1080

http.get  { url, via?: "nord", ... }
http.post { url, via?: "nord", ... }
→ { ..., via: "nord" | null }
```

No `via` is the direct path, as now. What has to stay true on every
route:

- **The address is still checked by hob, and still pinned.** hob
  resolves, checks against `BLOCKED` and `HOB_HTTP_DENY`, and asks the
  proxy for the *address*, not the name. A proxy given the name does its
  own lookup and DNS rebinding is back. Net::HTTP sends `CONNECT` with
  the host name and has no separate SNI setting, so this is a small
  custom CONNECT, or SOCKS5 to the IP and our own TLS wrap with the name
  for SNI and the certificate check.
- **The tunnel is not a firewall.** Traffic leaving through Nord cannot
  reach the LAN, but the sidecar's own routing to its Docker network or
  the host might. The same checks apply as on the direct path.
- **No quiet fallback.** If the tunnel is down, the request is
  `Unavailable`. A request meant to leave by the dedicated IP that left
  by the house's address instead has told a site something it was not
  meant to know.

### 4. The route is something the sentinel judges

`via` is an argument, so it is in the request row, the reviewer reads
it, and the record says which address spoke. A rule can hold an agent to
one route or keep it off one:

```sh
CONSTRAINTS='{"via":{"enum":["nord"]}}'   # always leave by the dedicated IP
CONSTRAINTS='{"via":{"const":null}}'      # never
```

Since the dedicated IP is ours and builds a reputation, an agent that
burns it costs the person who uses it as a VPN. Starting it at
`person` (a person approves every request by it) and loosening later is
the cautious version.

### 5. A browser that leaves by the dedicated IP

A second `browsers` row (BROWSE.md) whose gofer Chrome runs with
`--proxy-server` pointed at the sidecar, in its own profile. For a site
that wants a stable, allowlisted address, or one that blocks datacenters
but has no login worth having. For logged-in shopping the existing gofer
on the Mac mini is still the better address: residential, and the one
the person's logins already know. Two profiles, so cookies never tie the
house's address to the dedicated one.

### 6. The sandbox's one exit

If agentbox's sandboxed compute (DESIGN.md §5) gets an egress allowlist,
the dedicated IP could be its only way out. A service that allowlists
the IP then only ever hears from the sandbox, and the house's own
address never shows up in a sandbox's traffic.

## Which one, for what

| if the IP turns out to be for | start with |
|---|---|
| a person's VPN that sites do not flag | 1, 2 |
| a service that allowlists one address (an API, a home-lab admin page) | 1, 3, 4 |
| getting past datacenter blocks | gofer first (BROWSE.md); 5 if gofer cannot |
| not showing the house's address to the web | 1, 3, 4, with `nord` the default for `http.*` rather than an opt-in |

## Open questions

1. **Default or opt-in.** If privacy turns out to matter, every `http.*`
   request should leave by the dedicated IP and the direct path becomes
   the exception. That makes the IP's reputation the agents' to keep.
2. **Watching the tunnel.** The ward could check that the sidecar is up,
   that its exit is the dedicated IP and not a shared one (Nord moves
   things), and that its proxy answers nowhere it should not.
3. **One route or several.** A shared-IP Nord route alongside the
   dedicated one would give agents a burnable exit for anything
   scrapey, and keep the dedicated IP's reputation for people.
