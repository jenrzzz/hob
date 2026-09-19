# Hob companion (iOS)

A notification surface for the household. When the sentinel needs a person —
an agent petitions for a capability, or a request's policy says `confirm` —
hob pushes to this app; the item opens, you read what was asked and what the
steward or reviewer thought, comment, and grant, build, allow, or deny.
Nothing else lives here yet: it is a phone-sized `hob:sentinel:pending`.

The server side is `Push` (`app/services/push.rb`) behind `Notify.person`,
and `POST /v1/devices` for the phone to register. See
[SENTINEL.md](../../SENTINEL.md), "Petitions and the forge".

## Build

Requires Xcode 26 or later and [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The `.xcodeproj` is generated from `project.yml` and ignored.

```bash
cd clients/ios
bin/build            # xcodegen generate + simulator build
bin/build run        # …then boot a simulator, install, launch
SIM="iPhone 17" bin/build run
open Hob.xcodeproj   # or work in Xcode after `xcodegen generate`
```

To land in the inbox straight away on a simulator, hand the app a key the way
the Ruby clients take one (a key saved in the app still wins):

```bash
SIMCTL_CHILD_HOB_URL=http://devbox:3400 SIMCTL_CHILD_HOB_KEY=hob_… bin/build run
```

Without `xcode-select` pointing at Xcode, set
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the script does).

### On your phone

Push needs a real device signed by a paid developer account. Open
`Hob.xcodeproj`, set your team under Signing & Capabilities (the Push
Notifications capability is already in the entitlements), pick the phone, Run.
A development build registers a **sandbox** token; a TestFlight build a
**production** one. The app tells hob which, so either works.

### Smoke test

`HobUITests` runs against a real hob with something pending: it opens the
petition and the request the inbox shows, comments, and denies each. With a
dev server reachable from the Mac (an `ssh -R 3400:127.0.0.1:3400` from the
hob box makes it `localhost:3400`):

```bash
HOB_URL=http://localhost:3400 HOB_KEY=hob_… SHOT_DIR=$PWD/shots xcodegen generate
xcodebuild test -project Hob.xcodeproj -scheme Hob \
  -destination "platform=iOS Simulator,id=<udid>" -derivedDataPath build CODE_SIGNING_ALLOWED=NO
```

The variables go into the scheme (the generated project is gitignored, so
the key stays out of git). Screenshots land in `SHOT_DIR`; the tests skip
when nothing is pending.

## Wiring it to hob

1. **A key for you.** On the hob box:
   ```sh
   bin/rails "hob:key[jenner,phone]"        # a person's key, shown once
   ```
   Agent and surface keys are refused: only a person decides petitions.
2. **APNs on hob.** The same token-auth key kat uses works for every app on
   the team. Set on hob's Coolify app (runtime, not build-time):

   | var | value |
   |---|---|
   | `APNS_KEY` | the `.p8` contents (newlines may be `\n`-escaped), or `APNS_KEY_PATH` |
   | `APNS_KEY_ID` | the key id from the developer portal |
   | `APNS_TEAM_ID` | the team id |
   | `APNS_BUNDLE_ID` | `place.amber.hob` (the default) |

3. **In the app.** Settings: server URL, paste the key, Connect. It asks for
   notification permission and registers the phone (`POST /v1/devices`).
   *Send a test notification* goes through hob and Apple end to end and says
   what went wrong if it did not.

Every launch re-registers the token; a token Apple reports dead is deleted.
Several people can each register their phones; every person's phone hears
about every petition and request, because any person may decide.

## What arrives

| when | title |
|---|---|
| the steward refers a petition (or the charter says `confirm`) | `hob: <agent> petitions for a capability` |
| a request's rule says `confirm`, or the reviewer escalates | `hob: <agent> asks for <capability>` |
| the forge starts a build | `hob: forging <capability> for <agent>` |
| a pull request is ready | `hob: PR ready for <capability>` |
| a build fails | `hob: build failed for <capability>` |

The payload carries `hob: { kind: petition|request, id, status }`; tapping
opens that item. The ntfy message hob posts to `HOB_NOTIFY_URL` carries the
same item as its click action, `hob://petition/<id>`, so the ntfy app's
notification opens this app too. Banners for the same item collapse, so the latest state
replaces the last.

## Layout

```
Hob/
  HobApp.swift          @main; wires AppDelegate and the Session
  AppDelegate.swift     APNs token callbacks
  PushCenter.swift      permission, registration, foreground banners, tap → route
  PushEnvironment.swift sandbox or production, from the provisioning profile
  Session.swift         connection, inbox, navigation, device registration
  HobClient.swift       hob's API with a person's key
  Models.swift          Petition, SentinelRequest, JSONValue, decisions
  Config.swift          server URL in defaults, key in the keychain
  Views/                Inbox, Petition, Request, Settings
```
