# casts

Status: built, 2026-11-24. The voice plane (dialogue, sound, music, the
clip cache, the ledger), the writer, the mixer, the private feed, and
feedcurator's hand-off are in. Not yet run against ElevenLabs itself: see
*Before the first episode*.

*The briefing, read to you by two people who have opinions about it.*

feedcurator writes a good morning briefing and nobody reads it while
making coffee. hob already owns the household's models and was always
going to own its voice (DESIGN.md, "Voice"). So a surface hands hob
something worth hearing, and hob **produces a show** from it: it writes
the briefing as a conversation between two hosts, has them voiced, dresses
it with a theme and stingers, mixes it down to one file, and serves it on
a private podcast feed. You subscribe once, in any podcast app.

A **cast** is a show. An **episode** is one edition of it.

```
feedcurator ── POST /v1/casts/briefing/episodes ──▶ hob
                                                    │  CastEpisodeJob
                    writer (cast-writer) ───────────┤  the script
                    ElevenLabs dialogue ────────────┤  the takes
                    ElevenLabs music, sound ────────┤  the theme, the stingers (once)
                    ffmpeg ─────────────────────────┤  one mp3
podcast app ◀── GET /casts/<token>/feed.xml ────────┘
```

## What an episode sounds like

1. **Cold open.** Two to four lines, no greeting, straight into the most
   arresting thing in the news, left hanging.
2. **The theme**, alone for six seconds, then ducking under the welcome
   and fading out over the first segment.
3. **Segments**, one per story, most important first, with a short
   **stinger** between each. The next segment starts as the sting rings
   out.
4. **Sign-off** over the theme's last stretch, which swells when the
   hosts stop and plays out to its own ending.

The whole thing is levelled to −16 LUFS, which is what podcast apps
expect, with the voices lightly compressed on a bus of their own.

## The script

One call to the `cast-writer` role (`Casts::Script`), with a schema, given
the briefing as written and the stories behind it. The prompt asks for a
conversation, not two people taking turns reading: uneven line lengths,
interruptions, disagreement that stays disagreement, opinions in
character, no radio filler, and every fact from the material it was
given. Lines carry ElevenLabs audio tags (`[laughs]`, `[sighs]`,
`[deadpan]`) that the voice model performs.

What comes back is tidied before anything is paid for: markdown, links
and addresses are stripped (tags stay), a speaker who is not a host
becomes the first host, and segments are dropped from the end until the
script fits the show's `max_characters`. The script is kept on the
episode, so a retry never writes it twice.

## Turns and beats

The lines are cut into **takes**: stretches voiced in one request, at
most 1,800 characters (ElevenLabs is reliable up to 2,000). Inside a
take, the dialogue model does its own turn-taking, which is most of why
it sounds like two people in a room.

What hob joins is take to take, and that is where kat's Playhouse pacer
came over (`Casts::Pacer`, from `voice_pacer.js`). A script's pause
conflates the **turn**, the moment between one voice and the next, which
in real talk is a fifth of a second, with the **beat**, a silence the
script means. So:

- every take is trimmed to where its voices start and stop
  (`Casts::Mixer.voice!`, kat's `voicedSpan`), because generated clips
  carry dead air at both ends and it swamps a short gap;
- a turn gets about 0.22s when a different host answers and 0.45s when
  the same one carries on, jittered so a run of them doesn't tick;
- a line the writer marked `beat` ends its take, and the silence after
  it is held for about a second.

`voicing` chooses how much of the rhythm is whose:

| `voicing` | a take is | the rhythm is |
|---|---|---|
| `dialogue` (default) | as many lines as fit | the model's inside a take, the pacer's between |
| `lines` | one line | the pacer's throughout, as in Playhouse |

`lines` gives up the model's cross-talk for control and a per-line cache.
Neither has been listened to yet; flip a cast between them and judge by
ear.

## Voice

`Voice` is the voice plane the design promised, and casts are its first
user. Audio is asked for by **role**, like every other model call:

| role | makes | seeded as |
|---|---|---|
| `voice-dialogue` | lines, each in its own voice, as one take | `elevenlabs/eleven_v4` |
| `voice-sound` | a stinger from a description | `elevenlabs/eleven_text_to_sound_v2` |
| `voice-music` | a theme from a description | `elevenlabs/music_v1` |
| `cast-writer` | the script | `anthropic/claude-opus-5-5`, then sonnet |

`elevenlabs` is a provider row of a new kind, keyed by
`ELEVENLABS_API_KEY`. `hob:role[voice-dialogue,elevenlabs,eleven_v3]`
changes the model with no deploy.

**Never paid for twice.** Every clip is kept in `audio_clips`, named by a
digest of the kind, the model, and exactly what was asked. The theme and
the stingers are therefore made the first time a show airs and found
again by their descriptions ever after; change a description and the
next episode makes a new one. A run that dies halfway resumes where the
money stopped.

**In the ledger.** Each generation is a `usage_events` row
(`voice.dialogue`, `voice.sound`, `voice.music`) with `characters` and
`seconds` in its units and the episode as its `ref`, beside the writer's
call. A voice model's price row reads `input` as USD per million
*characters*: `bin/rails "hob:price[eleven_v4,<usd per million>,0]"`.
Until then its cost is null, as for any unpriced model.

Audio lives in Postgres because hob's web and jobs containers share
nothing else. An episode is about a megabyte a minute; a show keeps its
last `keep` episodes (30) and prunes the rest with their audio.

## A cast's config

Everything a cast doesn't say comes from `Cast::DEFAULTS`.

| key | default | |
|---|---|---|
| `hosts` | Marlowe (dry, sceptical) and Pip (quick, curious) | `[{ key, name, voice_id, character }]`, one to four |
| `minutes` | 8 | what the writer aims for, at 150 words a minute |
| `max_characters` | 9000 | the hard ceiling on what is voiced |
| `voicing` | `dialogue` | or `lines` |
| `theme`, `theme_seconds` | a jazzy morning-radio theme, 40 | blank for none |
| `stingers`, `stinger_seconds` | three short stings, 2.5 | `[]` for none |
| `keep` | 30 | episodes kept |
| `audience` | none | a phrase the writer is told about the listener |
| `language`, `author`, `image_url` | `en`, `hob`, none | for the feed |

The default hosts use two voices every ElevenLabs account has (George and
Sarah). A show worth keeping names its own: design a voice at ElevenLabs
and put its id in `hosts`.

## API

```
GET   /v1/casts
GET   /v1/casts/:slug
POST  /v1/casts { slug, title, description?, realm?, config? }     a person's key; an upsert
PATCH /v1/casts/:slug { title?, description?, config?, rotate_token? }

GET   /v1/casts/:slug/episodes
GET   /v1/casts/:slug/episodes/:id?script=1
POST  /v1/casts/:slug/episodes { edition, briefing, title?, stories?, force? }
POST  /v1/casts/:slug/episodes/:id/retry { rewrite? }              a person's key
```

`edition` is the surface's own name for the episode, a date usually. **A
cast has one episode per edition**, and one that is made or being made is
handed back as it is (200), because making it again costs money. `force`
remakes it; a failed one is always tried again. Otherwise the answer is
202 and the episode to poll: `queued → writing → voicing → mixing →
ready`, or `failed` with the reason.

`stories` is `[{ title, summary, category?, sources: [{ title, url,
source }] }]`. The writer reads them; the feed's show notes link them.

`config` merges key by key; a key set to null goes back to its default.

## Listening

```
GET /casts/<token>/feed.xml
GET /casts/<token>/episodes/<id>.mp3
```

A podcast app cannot send a bearer key, so these take none. **The token
in the address is the whole of the secret.** It opens one cast, at that
cast's realm, for reading, and nothing else in hob. `GET /v1/casts/:slug`
shows `feed_url` to a person's key; `rotate_token` ends every
subscription to the old address. The feed is marked `itunes:block` so a
directory that is handed it will not list it. Audio honours `Range` and
`If-None-Match`.

Put a morning briefing at `personal` and its feed is as private as the
address. Do not point a cast at an `intimate` source unless you would
hand that address to whoever holds your phone.

## Before the first episode

1. `ELEVENLABS_API_KEY` in hob's environment (both containers). The key
   needs text-to-dialogue, sound effects, and music.
2. Deploy. The migration adds the provider and roles; the image gains
   ffmpeg.
3. `bin/rails "hob:cast[briefing,The Morning Hob,personal]"` prints the
   feed's address and whether voice and the mixer are ready. Subscribe
   to it.
4. `bin/rails "hob:provision[feedcurator,<coolify app uuid>]"` gives
   feedcurator `HOB_URL` and `HOB_KEY`. Its next morning refresh hands
   over the briefing (`hobcast.py`).

`bin/rails hob:casts` lists each cast's last episodes and what failed.

**What it costs.** ElevenLabs bills speech by the character. At the
default eight minutes an episode is about 7,000 characters, so a daily
show is roughly 210,000 characters a month; the theme and stingers are
one-time. `max_characters` is the ceiling per episode, and feedcurator
sends only the morning refresh unless told otherwise.

## Not built

- A person's own voice for a host (`Persona#voice_id` exists; a host is
  not yet a persona, so the hosts remember nothing between episodes).
- Overlap: a host's "mm-hm" under the other's line. The timeline places
  takes end to end.
- Chapters in the mp3, and cover art made by hob.
- A ping when the episode is ready. The podcast app's own refresh is the
  notification.
