# ADR 0017: System notifications

Status: Proposed. Date: 2026-10-21.
Builds on ADR 0002 (one helper per person on a computer), ADR 0014 (sync between the person's devices) and ADR 0015
(the portable core: a helper process on desktops, the core inside the app on phones). Areas: helper (Objective-C
`service/notify/`, Rust `szfriends-helper/src/notify/`), presentation (catalog `notify.*`, `settings.notifications.*`,
`banner.notifications.*`), views (focus, the ask card, Settings switches, the `friends/conversation/` URL), the Tauri
plugin's Android and iOS code. Client contract: PROTOCOL.md § Notifications.

## Context

The owner's report, testing a phone beside a Mac: "I exchanged messages from the phone and computer, no notification
appeared on either of them". Nothing in Friends posts to the system: a message only shows as a row marker and the
Friends button's badge, which nobody sees while working in another app or with the phone in a pocket. Friends runs on
macOS (three apps share one helper), Windows and Linux (Shenzhen 3D and the Rust helper), Android and iOS (Shenzhen 3D
with the core inside the app).

## Decision

**One notifier per computer.** Whatever process owns the store posts: the helper on a computer (the Objective-C helper
on a Mac, the Rust helper on Windows and Linux), the core inside Shenzhen 3D on a phone. Views never post. Three apps
on one Mac therefore cannot post three times: they share the helper, which holds the single-instance lock. A phone's
core hands each request to the plugin's native code, which posts it.

**What notifies.** Each notification has a `kind` and a `channel` (Android channels; elsewhere a grouping only):

| Kind | Channel | When | Title | Body |
|---|---|---|---|---|
| `message` | messages | a friend's message | the friend's name | the text, or "New message" without previews |
| `file` | files | a friend offers a file that waits for an answer | the name | "Mei wants to send you Bracket.step" |
| `file` | files | a friend's file accepted automatically, once received | the name | "Mei sent Bracket.step" |
| `request` | requests | a friend request arrives | the name | "Wants to be friends" |
| `request` | requests | a friend accepts this person's request | the name | "Accepted your friend request" |
| `link` | requests | someone adds this person through their friend link (accepted by itself) | the name | "Used your friend link, so you’re now friends" |
| `link` | requests | this person added someone through that person's friend link, and it went through | the name | "You’re now friends" |
| `join` | requests | a computer or phone asks to join this person's profile | "Pixel 8 wants to join your profile" | "Approve it in Friends only if you’re setting it up now." |

Files offered together in one batch post one notification ("Mei sent Bracket.step and 2 more files"). Messages that
land in one conversation in one burst (committed within one second) post one notification for the newest; without
previews it says "3 new messages". A file a person accepted by hand does not notify again when it arrives: they asked
for it. Exact strings are catalog entries (`notify.*`), the same in both catalogs.

**What never notifies.**

- The conversation the person is looking at in a focused window (below, Focus).
- Anything the person did on another of their devices: their own messages and files, answers they gave, links they
  opened, devices they approved. Outgoing items never notify. The You conversation never notifies.
- A friend's item that reached this device by sync from another of the person's devices when it is already read
  there, or was sent more than 10 minutes before it arrived here: a friend's message is delivered to whichever device
  it reaches first (ADR 0014), and the others hear of it by sync. When it arrives fresh, each device notifies, as
  phones and computers do for other messengers.
- Anything already in the store when the helper starts, history copied when this device joins a profile, people the
  person blocked, files from download links or Get, and copies from the person's own computers.
- Anything while Notifications is off in Settings, or while the system does not allow it.

A notification is decided once, when the item is first committed to this device's store: the helper never re-reads the
store to post later, so a restart, a reconnect or a second client never posts again. When a conversation is marked
read (here, or on another device by sync), its delivered notifications are withdrawn where the platform allows.

**Focus.** Each client tells the helper which conversation its focused window shows, with `set_focus`
(`conversation_id`, or `null` when the window loses focus, the app goes to the background, the dropdown closes or shows
another page). The helper keeps one value per connection and drops it when the connection closes. A message for a
conversation any connection names is not notified. A client that did not declare `notifications.focus` but holds an
`open_conversation` subscription counts as focused on that conversation, so older apps stay quiet rather than noisy.

**Where a click goes.** The helper remembers the app the person last used Friends from: the last client that sent
`activate`, `open_conversation` or a non-null `set_focus`, with its `client.url_scheme` (hello) and, on a Mac, its
bundle path read from the peer's process; it keeps it in `<state dir>/notify-target` so clicks after a restart still
go there. Without one it is ShenzhenPDF on a Mac and Shenzhen 3D elsewhere. A click opens
`<scheme>://friends/conversation/<conversation_id>` (a join request: `<scheme>://friends`), which every host routes to
its Friends dropdown or panel, open on that conversation. The URL works whether or not the app is running.

- Mac: LaunchServices' `LSOpenFromURLSpec` (what `-[NSWorkspace openURLs:withApplicationAtURL:configuration:]` calls;
  the service layer links no UI toolkit) with the remembered bundle, activating it; the scheme's default handler when
  that bundle is gone. A click can reach a helper macOS just launched for it (no
  client, maybe not the lock holder): it routes the click before it exits.
- Windows: the toast's `activationType="protocol"` with the URL as `launch`, so Windows opens it without the helper.
- Linux: the helper listens for `ActionInvoked` (`default`) on the session bus and starts the remembered executable
  with the URL, or `xdg-open`/`gio open` with it.
- Phones: the notification's intent (Android) or response (iOS) carries the URL; the app routes it like a deep link.

**Reply.** Message notifications offer Reply where the system has inline replies: macOS
(`UNTextInputNotificationAction`) and Android (`RemoteInput`) when the core is running. The helper sends the text as
`send_message` would, in that conversation, and marks it read. A helper that macOS launched for the reply and that
does not hold the lock forwards it to the running helper over the socket, as a client.

**Permission and the ask.**

- macOS and iOS: nothing is asked at launch. After the person has used Friends (an `activate`), the list carries a
  card, the `notifications` banner: "Get a notification when friends send you a message or a file." with Turn On and
  Not Now. Turn On sends `allow_notifications`; the helper (macOS) or the plugin (iOS) then asks the system, which
  shows its own prompt. Not Now dismisses the card for good; Settings keeps Allow.
- Android 13 and later: POST_NOTIFICATIONS is asked together with the Bluetooth permissions, in the same request, when
  the plugin asks for Nearby's access; a phone updated from a build that already had Bluetooth asks once, the next time
  Friends asks for access. Settings offers Allow while it can still be asked, and Open Settings once it was refused.
  No card: the system dialog explains enough, and a second ask would come too close to it.
- Windows and Linux need no permission. Linux without a notification service on the session bus says so in Settings.

**Settings, per device.** Settings gains a Notifications block: "Show notifications" (on by default) and "Show message
text" (on by default; off hides message text and file names), the permission line with its one action, and on phones
"Stay reachable in the background" (Android, off by default) or the iPhone note. These belong to the device and never
sync: a person may want text on the Mac but not on a phone's lock screen.

**Android in the background.** Friends receives only while the app's process lives. "Stay reachable in the
background" runs a foreground service (type `specialUse`, subtype "Stay reachable to friends") while on, with a quiet
ongoing notification on its own channel, "Friends is reachable", so Android keeps the process and the core running
after the app is closed; it starts again after a restart of the phone while the switch is on. Settings says what it
costs: the phone keeps looking for friends nearby and stays connected, which uses battery all day.

**iOS.** Local notifications only, posted while the app runs or in the short time iOS gives it after going to the
background. Settings says plainly that an iPhone gets messages only while Shenzhen 3D is open: there is no push
server, by design (no server learns who talks to whom).

**The request.** Both helpers build the same request, and the test sink and the phone bridge carry it as JSON:

```json
{"key":"message:i_81f2","kind":"message","channel":"messages","conversation_id":"c_mei","thread":"c_mei",
 "title":"Mei","body":"Can you check the bracket?","time":"2026-10-21T08:12:03Z",
 "reply":{"label":"Reply","placeholder":"Message Mei","send":"Send"},
 "open":{"url":"shenzhenpdf://friends/conversation/c_mei","app_id":"com.intuition.shenzhenpdf",
         "app_path":"/Applications/ShenzhenPDF.app"}}
```

`key` is unique per notification (`message:<item id>`, `file:<transfer id>`, `request:<conversation id>:<n>`,
`join:<join id>`, `link:<conversation id>`) and is the system identifier; `thread` groups (and withdraws) by
conversation; `reply` is `null` except on messages; `app_path` is `null` off a Mac. A withdrawal is
`{"withdraw":{"thread":"c_mei"}}`. A response, from the system or a test, is `open` or `reply` with `text`, for a
`key`.

**Test sink.** A helper whose state directory was overridden (`SZFRIENDS_STATE_DIR`, a test home; team-signed builds
ignore it, ADR 0002) never touches the system's notification service. It appends each request, withdrawal, ask
(`{"asked":true}`) and routed click (`{"opened":{"url":…,"app_id":…,"app_path":…}}`, instead of opening it) as one
JSON line to `<state dir>/notifications.jsonl`, reads the permission from `SZFRIENDS_NOTIFY_PERMISSION` (`granted`,
`denied`, `not_asked`; default `granted`), and accepts `test_notification_response` (`key`, `action`, `text?`) to
drive a click or a reply through the same code a real one takes. Outside a test home that intent is
`unknown_intent`. This keeps every Mac test off the owner's screen.

## Alternatives considered

- **Each app posts for itself.** Three apps on a Mac would post three times, or would need to elect a poster, and the
  helper often runs while no window is focused. The helper already owns the store and the single-instance lock.
- **Posting from the app bundles on a Mac** (ShenzhenPDF's identity). Clicks would always open ShenzhenPDF and the
  permission would be asked per app; the helper's own bundle ("Shenzhen Friends") asks once per Mac.
- **A push server** for phones. It would learn who talks to whom and when; Friends keeps no such server. Android gets
  a foreground service instead; iOS stays honest about only receiving while open.
- **Deciding from snapshots in the views.** A view sees only the views it subscribed to, may not be running, and
  three views would each decide. Deciding at commit time in the store's owner is exact and posts once.
- **Opening through the helper link only** (a frame telling a connected client to show a conversation). It does not
  work when the app is closed; the URL route does both, and the routes for friend links already exist.

## Consequences

- A new helper capability `notifications` and client capabilities `notifications.focus` and `notifications.ask`;
  intents `set_focus`, `set_notifications`, `allow_notifications`, `test_notification_response` (test homes); the
  settings view's `notifications`; the list banner kind `notifications` with a second, dismissing action; the hello
  field `client.url_scheme`; a URL route `friends/conversation/<id>` in every host.
- The Mac helper bundle gains an icon and links UserNotifications; it is the only Friends process that talks to the
  notification centre. Its build number moves to 26102005.
- The Rust helper gains Windows toasts (its own AppUserModelID, registered under HKCU with the display name Shenzhen
  Friends and its icon) and freedesktop notifications on the bus it already uses.
- Android: POST_NOTIFICATIONS and FOREGROUND_SERVICE(_SPECIAL_USE) in the manifest, four channels (Messages, Files,
  Requests, Reachable in the background), the service and a boot receiver. iOS: UserNotifications in the plugin.
- Notifications do not change the protocol's frames, the sessions or the store schema.

## Verification

- Mac (helper suite, test homes, sink): three clients (ShenzhenPDF, Shenzhen Files, Shenzhen 3D test clients) on
  one helper and a friend's helper sending a message, an offer, a request and an acceptance: one request each, with
  the expected title, body, channel and URL; none while one client's `set_focus` names the conversation; none for the
  person's own device's messages (a second own device); withdrawal after read; preview off hides text and file names;
  `test_notification_response` open routes to the last-used app's bundle and conversation, reply sends the text.
- Rust: unit tests with the sink for the same matrix; Linux run against a real notification daemon under Xvfb on
  the Ubuntu VM; Windows toast XML built and checked in unit tests.
- Android emulator: POST_NOTIFICATIONS granted, a test helper sends a message, `dumpsys notification` shows it on the
  Messages channel, tapping it opens that conversation; again with the app in the background and the switch on.
- iOS simulator: the request path (authorization asked after Turn On, a local notification requested for a message).
