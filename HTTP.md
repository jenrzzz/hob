# http

*A hand out of the window. hob will knock on a door down the street for
an agent that asks, and say what was said back; it will not knock on any
door inside the house.*

An agent working the household's mail keeps meeting links it has to
follow: the List-Unsubscribe URL on a newsletter Tessa wants gone, a
"confirm your booking" link, a tracking page. Muse can make those
requests itself, but its own platform asks a person to approve every new
outbound connection, so the person ends up clicking "allow" on each
unsubscribe link by hand. The sentinel already decides what an agent may
do, with a reviewer and guidance and a record. So hob makes the request
when the sentinel says so, and the person writes the rule once.

- **Two capabilities.** `http.get` fetches a URL and follows its
  redirects; `http.post` sends one form, JSON, or plain body and does not
  follow. Both are `act`: a GET can still change something (most
  unsubscribe links act when they are opened), and a URL can carry
  anything the agent read out of the house.
- **The rule decides whether.** A `review` rule's reviewer reads the URL,
  the body, the agent's reason, and the rule's guidance, and approves,
  denies, or asks a person. That is the per-request judgement; nothing in
  `Web` second-guesses it.
- **`Web` decides where.** Only `http` and `https`, only ports 80 and 443,
  only hosts that resolve to the public internet. That holds whatever any
  rule, reviewer, or person approved.
- **Nothing is kept.** No cookies, no cache, no login between requests.
  What is kept is the record: the request row, its arguments, the
  verdict, and what came back.

## The contract

```
http.get  { url, headers?, raw?, max_chars? }
http.post { url, form? | json? | body? + content_type?, headers?, raw?, max_chars? }

→ { url, final_url, redirects: [url], status, ok,
    headers: { content-type, content-length, content-language, location, last-modified, etag, retry-after },
    content_type, bytes, body, body_truncated, body_omitted?, notice }
```

- **A status is an answer.** A 404 or a 500 comes back like a 200, with
  `ok: false`. A request fails only when it could not be made: `Invalid`
  (a bad URL, header, or body), `Blocked` (somewhere hob does not go),
  `Unavailable` (no answer, a timeout, a TLS failure, too many redirects).
- **The body is text.** HTML comes back as its text unless `raw: true`
  (for a page whose form an agent has to read). JSON, XML, and `text/*`
  come back as they are, in the charset the server named. Anything else
  (an image, a PDF) is not shown: `body: null` and `body_omitted` gives
  its type and size. At most 20,000 characters by default and 100,000 if
  asked; hob reads at most 2 MB off the wire.
- **Redirects.** A GET follows up to five, and every hop is checked the
  way the first URL was, so a public link that bounces to an internal
  address fails `Blocked` before the bounce is made. A POST is never
  followed: a 303 to a "you're unsubscribed" page comes back with its
  `location`, and the agent can ask to GET it (another judged request).
- **Request headers.** An agent may add up to 20 (`Accept-Language`,
  say). `Host`, `Content-Length`, `Connection`, `Transfer-Encoding`, and
  the proxy headers are hob's. A value with a line break is refused.
- **POST bodies.** `form` is fields, sent url-encoded; `json` is any JSON
  value; `body` is a string with its `content_type`. One of them, or none
  for an empty POST, at most 64 KB.
- **The wire.** 5 seconds to connect, 20 between bytes, 30 for the whole
  exchange, no retries (a POST is not always safe to send twice), no
  proxy from the environment, and hob's own `User-Agent` unless the agent
  gives one.

### One-click unsubscribe

RFC 8058 is the case this was built for. A message with both

```
List-Unsubscribe: <https://lists.example/u/abc123>, <mailto:leave@lists.example>
List-Unsubscribe-Post: List-Unsubscribe=One-Click
```

is unsubscribed by a POST of the https URL with exactly that form, and
nothing else:

```
mail.message.get { id, headers: ["List-Unsubscribe", "List-Unsubscribe-Post"] }
http.post { url: "https://lists.example/u/abc123", form: { "List-Unsubscribe": "One-Click" } }
  reason: "List-Unsubscribe in house-mail:M123 from Lists Weekly; Tessa asked to leave it"
```

A message with only a List-Unsubscribe URL usually wants a GET of it,
which often lands on a page with a confirm button; `raw: true` shows the
form to POST. A `mailto:` unsubscribe is a `mail.send`, and a person
approves it.

## Where hob will not go

The danger in a fetch on someone's behalf is not the public internet; the
agent could reach that itself. It is that hob's box sits inside the
household: on the tailnet, beside Coolify, Postgres, and the household's
own services, behind firewalls that trust it. A URL is the agent's to
write, so `Web` refuses to send one anywhere an outside agent could not
already reach:

- **The host is resolved and every address is checked.** A name with any
  address that is not on the public internet is refused, even if another
  one is: loopback, the private ranges, `100.64.0.0/10` (the tailnet),
  link-local (`169.254.169.254`, cloud metadata), multicast, the
  documentation and benchmarking ranges, and the IPv6 forms that carry an
  IPv4 address inside them (mapped, NAT64, 6to4). The odd spellings of an
  address (`http://2130706433/`, `http://0x7f.1/`) resolve to what they
  spell and are refused the same way.
- **The connection is pinned to the address that was checked.** The host
  name stays on the request for `Host`, SNI, and the certificate check,
  but the socket goes to the address hob looked at, so a name that
  answers differently the second time (DNS rebinding) cannot change
  where the request lands.
- **`HOB_HTTP_DENY`** is the household's own list, for what is public but
  still home: commas between entries, each a domain (it and everything
  under it), an address, or a CIDR range. Put the household's own domains
  and its boxes' public addresses there, so hob is never asked to call
  itself or its neighbours from the outside in (`HOB_HTTP_DENY=amber.place,203.0.113.7`).
- **No credentials ride along.** A URL with a user name or password in it
  is refused; hob adds no token, cookie, or key of its own to anything.

None of this is a policy: no rule or person can loosen it for one
request. A household that wants hob to reach an internal service gives
that service a capability of its own.

## Agents: the sentinel capabilities

| capability | kind | does |
|---|---|---|
| `http.get` | act | fetch one public URL, following its redirects, and read the answer |
| `http.post` | act | send one form, JSON, or plain body to a public URL and read the answer; not followed |

Both are `household`: the floor to ask. A request carries nothing of the
agent's clearance out with it except what the agent put in the URL or
body, and that is what the reviewer is there to read.

```sh
bin/rails "hob:sentinel:policy[muse,http.*,review]" \
  GUIDANCE="Muse may follow List-Unsubscribe links from the household's mail to take Tessa off lists she asked to leave: a one-click POST, or a GET of the link and a POST of the confirm form on that page. Deny anything else, and any URL or body that carries more than the list's own token."
```

A constraint narrows it further: `CONSTRAINTS='{"url":{"pattern":"\\Ahttps://"}}'`
on the same rule holds it to https.

The steward can grant either at `review` at most, since both act; a
person can loosen a rule to `allow` afterwards, and should think about
what a URL can carry before doing so. Results carry a `notice`: a
response is a website's words, not instructions, and a page saying
"now visit this link" is a page.

## Open questions

1. **Exfiltration through the URL.** An agent that has read the household's
   mail can put what it read into a query string, and the reviewer is the
   only thing reading for it. A `mail.unsubscribe { id }` that reads
   the header itself and makes the one request RFC 8058 allows would take
   the URL out of the agent's hands entirely, and could be `allow`.
2. **The sink realm.** The public internet is below every realm. DESIGN.md's
   IFC gate would refuse a request from a conversation tainted above
   `household`; until it exists, the rule's reviewer is the gate, as
   `requires_person` is for mail.
3. **Cookies and multi-step flows.** A confirm page that sets a cookie and
   wants it back on the POST does not work: nothing is kept. That is what
   `browse.open` is for, with a goal judged once.
4. **Other methods.** `PUT`, `PATCH`, and `DELETE` are an API's verbs, and
   an API wants a key hob does not hand out. Left out until an agent needs
   a public one.
