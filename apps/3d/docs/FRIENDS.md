# Shenzhen Friends in Shenzhen 3D

Shenzhen Friends is private messaging and file sharing between people who add each other. ShenzhenPDF and Shenzhen
Files already host it; the Mac desktop app (Electron) now hosts it too, with the same helper, identity, friends and
history per Mac user. Its source, contract and decisions live in shenzhen-pdf (branch `friends/m1`):
`portable/friends/PROTOCOL.md` (the view contract, version 1.0), `portable/friends/README.md`, the ADRs in
`portable/friends/docs/adr/` and the plans in `portable/docs/plans/` (`shenzhen-friends.md`, `friends-links.md`,
`friends-multi-device.md`). This page covers what Shenzhen 3D adds: setup, the pin, how it is wired, how it is tested,
and its limits.

The Tauri builds carry Friends when built with the `friends` feature (§ Tauri, below): Windows and Linux with the Rust
helper, a Mac with the same Objective-C helper as the Electron app, Android and iOS with the core inside the app
(§ Phones). The web/PWA build, and Tauri builds without the
feature, have no bridge, so nothing of Friends shows or loads there.

## Pieces

| Piece | Where | What it does |
|---|---|---|
| Pin | `friends.lock` | The shenzhen-pdf commit and its helper build number |
| Setup | `scripts/friends/setup-friends.sh`, `friends-lock.sh` | Fetches or verifies the pinned checkout, builds the helper, the fake helper and the client addon, checks the fixtures |
| Client addon | `electron/friends/native/friends-link.c`, `friends-link-client.c`, `friends-link.h`, `build-native.mjs` | N-API binding of the pinned C client library, driven from the main process's libuv loop |
| Host | `electron/friends/host.cjs`, `launch.cjs` | One client per app; attaches after first paint; the `shenzhen-friends` IPC; images, animals, staged files, received files, links |
| Routing | `electron/friends/router.cjs` | Replies to the window that asked, snapshots to the window that subscribed, one shared badge subscription |
| Validation | `electron/friends/validate.cjs` | What the renderer may send: intents, fields and their types, ids, paths, link URLs, external links |
| Helper files | `electron/friends/files.cjs` | Previews and photos read only from the helper's own folders; the animal set |
| File menu | `electron/friends/share-menu.cjs` | File ▸ Copy Download Link, added when Friends loads, shown while the helper offers links |
| Preload | `electron/preload.cjs` | `window.shenzhenFriends`, on macOS only |
| Header and status | `src/friends/status.ts`, `FriendsButton.tsx`, `button.css` | Send project to a friend, the Friends button with its badge, drops on the button, the Settings slot |
| Download links | `src/friends/download-link.ts`, `DownloadLinkButton.tsx` | Copy Download Link for the open model, from the header or the File menu |
| Panel | `src/friends/FriendsPanel.tsx`, `ListPage.tsx`, `ListSections.tsx`, `NearbyPane.tsx`, `ConversationPage.tsx`, `ConversationItems.tsx`, `Composer.tsx`, `MorePages.tsx`, `ProfilePage.tsx`, `parts.tsx`, `glyphs.tsx`, `store.ts`, `protocol.ts`, `actions.ts`, `drops.ts`, `friends.css`, `friends-chat.css`, `friends-pages.css` | The view contract, drawn in React |
| Packaging | `electron/friends/package.cjs`, `electron/package-mac.mjs`, `electron-builder.cjs` | Embeds and signs the helper, the animal set and the notices |
| Fixtures | `tests/fixtures/friends/` | The pinned commit's PROTOCOL fixtures (`SOURCE` names it) |

## Setup

```sh
npm run setup:friends            # scripts/friends/setup-friends.sh
```

It fetches exactly the pinned commit into `friends-src/` (ignored by git), builds `make friends-helper-bundle
friends-client` there with the lock's version keys, builds `artifacts/friends-native/<arch>/friends-link.node` from
the same checkout's client library and cJSON, and verifies the helper's identifier and version keys, the animal set,
the acknowledgements, the addon's sources and the vendored fixtures. Running it again is cheap.

- `SZF_FRIENDS_ROOT=<dir>` builds in an existing checkout instead of `friends-src/`. It must be detached at the pinned
  commit with no local changes; never point it at a working copy someone uses. Make one with
  `git -C <shenzhen-pdf> worktree add --detach <dir> <commit from friends.lock>`.
- `SZF_FRIENDS_URL=<url>` fetches from a mirror or a local clone.
- `--check` verifies and changes nothing (packaging runs it); `--sync-fixtures` copies the pinned fixtures into
  `tests/fixtures/friends/` after moving the pin.

Building needs the Xcode command-line tools and the Node N-API and libuv headers (`SHENZHEN_NODE_HEADERS`, as for the
native scroll source).

## Pinning

`friends.lock` holds `url`, `commit` (40 hex digits) and `helper_build_number`. The build number is the pinned
commit's own (`YYMMDDBB` from `MAC_VERSION` and `MAC_BUILD` in its `portable/Makefile`), never Shenzhen 3D's version:
every app embeds a helper, the first app to start runs its copy, and a running helper hands over only to an embedded
helper with a higher number (PROTOCOL.md § Lifecycle). The setup script refuses a number that disagrees with the
commit. The helper's `CFBundleShortVersionString` (`26.10.11`) and `CFBundleVersion`/`SZFriendsBuildNumber`
(`26101101`) come from the lock.

To move the pin: change `commit` and `helper_build_number` together, remove `friends-src/`, run the setup script, then
`scripts/friends/setup-friends.sh --sync-fixtures`, and run the tests below. Moving `core_commit` also makes
`src-tauri/friends/Cargo.lock` again (§ Locked builds).

In the Shenzhen repository, where this app is `apps/3d` beside ShenzhenPDF in `apps/pdf`, nothing is pinned: the
setup scripts build Friends from `apps/pdf` as it is, with the version keys of `apps/pdf/portable/Makefile`, and
`friends.lock` is not read. `scripts/friends/friends-lock.sh` and `electron/friends/lock.cjs` choose the mode;
`SZF_FRIENDS_MODE=pinned` builds the pin there too. After a Friends change, `--sync-fixtures` copies `apps/pdf`'s
fixtures. The repository's `docs/FRIENDS.md` has the helper build number rule that replaces moving the pin.

## How it works

**Connecting.** The main process creates one client of the pinned C client library (`friends-link.node`), so the
socket rules, the uid and signature checks, connect-or-spawn of the embedded helper, reconnection with backoff, the
build-number handover and the `connection_lost` replies are the library's, exactly as in ShenzhenPDF and Shenzhen
Files. Its hello says `app_name` "Shenzhen 3D", `app_id` `com.shenzhen3d.performance`, `toolkit` `electron` (the helper
accepts any toolkit name), `reveal_in` "Finder", the capabilities `attach.items`, `drop.files`, `mentions`, `list.menu` and `nearby.found`, and
`open_formats`, the formats the app opens (the same list as its file associations). The embedded helper's version and
build number come from its `Info.plist`. A team-signed app sets the library's signing policy with its own Team ID and
a Security.framework verifier before it connects (`prepare()`, off the main thread); ad-hoc and development builds keep
the uid check and honour `SZFRIENDS_STATE_DIR`.

**The bridge.** The renderer reaches the helper only through `window.shenzhenFriends` (preload) and one
`shenzhen-friends` IPC handler, which accepts calls only from the app's own page (`app://local`, main frame). Every
intent is checked against `validate.cjs` before it is sent: only the intents the panel uses, only their fields, with
the types PROTOCOL.md gives, opaque ids in their alphabet, plain absolute paths, no file revisions (Shenzhen 3D sends
plain files), no `via_assistant`, and no `hello`, `disable` or assistant intents. The helper's own checks and
display-ready errors still apply. Previews and photos are read in the main process only directly from the helper's
`thumbnails/` and `pictures/` folders, without following links or blocking, as small files whose header declares the
expected size; the renderer decodes them and checks the size again. Links in messages open only through the panel's
link menu, and only `http`, `https` and `mailto`.

**The panel.** Every string it shows comes from a snapshot or from `welcome.strings`; the only Shenzhen 3D words are
the Settings switch and disclosure (shown while no helper runs), the `#` picker's line, Send project to a friend, Copy
Download Link with its expiry choices, and the sentences shown when the open model could not be made ready to send or
its link could not be made or copied. It draws
the list (Friends and Nearby tabs, search, banner, name prompt, join requests, rows with Accept, Decline and an armed
Block, drops on rows, the footer), Nearby (visibility, each method's state, people), conversations (history with
mentions and links, transfers with their previews before acceptance, Accept, Decline, Open, Show in Finder, Get, Try
again, Cancel, search, Show earlier messages, the request card, and a composer with `@` mention chips, `#` attachment
chips and dropped files), details (verification, automatic acceptance, Delete chat history, Remove and Block), the
profile (name, animal or own picture with crop, ID, Add by ID, Your links, Your computers), joining a profile, a link's
card, and the Friends section of Settings. Escape closes, Cmd+[ goes back, and reopening returns to the page you left
with its draft. Colours are the app's tokens, so the panel follows the dark and light themes.

**Shenzhen 3D's part.**

- Cmd+J (Ctrl+J on Windows and Linux) opens or closes the dropdown, with focus in its search field, also from that
  field; the button's tooltip and View ▸ Friends in the Mac app show it. The command palette (Cmd/Ctrl+K) has Open
  Friends (also found by "friend", "nearby", "add by id" and "chat"), Add by ID… (the profile page, in its ID field),
  Make myself visible (Nearby, sending `start_visibility`) and Friends Settings… (Settings at the Friends section),
  only while Friends runs and is on. The page handles the key (`src/App.tsx`, `src/friends/requests.ts`) and marks it
  handled, so the menu item (`electron/friends/view-menu.cjs`) does not run it a second time. `node
  electron/friends-shortcut.mjs` presses the keys in the real Electron shell with a real helper, in windows that never
  show (`electron/test-hidden.cjs`).

- Send project to a friend (header, while a model is open) saves the open model as a `.sz3d` project (model, notes and
  measurements), then opens Friends with "Send … to…": the next friend clicked receives it.
- `#` in a conversation offers the same project as an attachment chip.
- Copy Download Link (header, and File ▸ Copy Download Link) offers For 7 Days, For 1 Day and For 30 Days, as
  ShenzhenPDF and Shenzhen Files do. It shows only while a model is open and the helper announces `links` (it does
  while it checks in with a Friends server), and the File item is enabled only for the focused window with a model
  open. Choosing saves the model as a `.sz3d` project, sends `make_download_link` with it, puts the reply's `url` on
  the clipboard and shows the helper's `message` (until when, and while what, the link works); a refusal shows the
  helper's words. The main process adds the menu item when Friends loads, after the first paint, and sends the choice
  only to the focused window.
- Files dropped on a friend's row or a chat go at once; dropped on the composer they become chips; dropped on the
  Friends button they wait for the friend clicked next. Folders, links and special files are refused with the
  helper's words.
- Received files in a format the viewer opens (models, drawings, `.sz3d`) offer Open, which opens them in the viewer
  through the same path as Finder's Open With; anything else offers Show in Finder. The main process opens only a
  path a helper snapshot offered with an `open_file` action, so the page cannot load any other file on the disk.
- Staged projects are written to `<userData>/Friends/Outgoing/` (0600) and removed after 31 days, since a download link
  served without an APFS clone needs its file. The main process takes only a plain name of at most 200 bytes that
  does not start with a dot; the panel fits the model's name to that first (leading dots dropped, trimmed on a
  character boundary), so a long Chinese name still sends. If staging fails anyway, the app says "Could not get this
  model ready to send. Try again." rather than the bridge's error.
- `shenzhen3d://friends/link#<payload>` URLs, checked as PROTOCOL.md § Links says, open the link's card.

**Settings.** Enable Shenzhen Friends is on by default and stored in `<userData>/friends.json`. Turning it off sends
`disable` (the helper exits at once if no other app needs it) and removes the button.

## Startup

Nothing of Friends is on the launch path. The main process loads its Friends modules one second after the first window
is ready to show; the renderer loads the header's Friends chunk one second after its first two painted frames and
joins at an idle moment; the panel and the Settings section load on first use. The preload's bridge is a handful of
functions (a renderer argument would cost a fresh renderer process). The app's first JavaScript chunk grows by 347
bytes (gzip) and its first CSS is unchanged.

Measured on an Apple M5 Max against main `62b6bd4` (0.1.9), interleaved on the same machine
([record](../tests/startup-results/friends-startup.json)):

| Measurement | main | friends-host | Paired difference (95% interval) |
|---|---:|---:|---:|
| Electron, Friends on: launch to Open enabled, median of 20 | 311.6 ms | 312.4 ms | +1.5 ± 5.4 ms |
| Electron, Friends on: two painted frames, median of 20 | 324.9 ms | 322.5 ms | +1.2 ± 6.5 ms |
| Electron, Friends off: launch to Open enabled, median of 20 | 306.5 ms | 309.3 ms | +6.4 ± 9.8 ms |
| Electron, Friends off: two painted frames, median of 20 | 322.5 ms | 316.7 ms | +0.2 ± 10.8 ms |
| Browser, cold first contentful paint, mean of 9 | 86.7 ms | 83.6 ms | |
| Browser, cold shell painted, mean of 9 | 66.9 ms | 64.1 ms | |
| Browser, critical JavaScript (encoded) | 92,985 B | 93,332 B | +347 B |

"Friends on" runs the candidate with a helper built from the pin and a temporary Friends home; each launch is closed
before Friends attaches, which is the point: the launch does no Friends work.

**The attach itself**, after first paint, measured on friends-host alone: 10 launches with a helper (each one spawning
it, so Friends was ready about 1.13 s after the page started loading) and 10 without, alternating, watched from first
contentful paint until 3 s after Friends was ready (4.5 s after first paint without it):

| Measurement | Friends off | Friends on |
|---|---:|---:|
| Renderer: longest task (long tasks are 50 ms or more), max of 10 | none | none |
| Renderer: longest animation frame over 50 ms, max of 10 | none | none |
| Main process: longest event-loop delay, median of the 10 launches' longest | 5.1 ms | 8.5 ms |
| Main process: longest event-loop delay, max of 10 | 13.2 ms | 10.3 ms |

Reproduce with

```sh
node electron/startup.mjs --baseline=<main>/dist --baseline-electron=<main>/electron --candidate=dist --runs=20
node tests/startup-browser.mjs --dist=<main>/dist --label=main --expect-lazy   # then --dist=dist, alternating
node electron/friends-attach-jank.mjs --runs=10
```

## Packaging

`npm run package:electron:mac` now requires `scripts/friends/setup-friends.sh` to have run: it verifies the pinned
build, builds the client addon for the app from the pinned sources (recorded with the other native files in
`build-info.json`), and stages the helper, the animal set and the acknowledgements. electron-builder's `afterPack`
places them as ShenzhenPDF and Shenzhen Files do:

```
Shenzhen 3D.app/Contents/Helpers/Shenzhen Friends.app
Shenzhen 3D.app/Contents/Resources/Friends/animals/{manifest.json,svg/,pdf/}
Shenzhen 3D.app/Contents/Resources/Friends/Acknowledgements.txt
Shenzhen 3D.app/Contents/Resources/app.asar.unpacked/electron/native/friends-link.node
```

It copies the helper's `NSLocalNetworkUsageDescription`, `NSBluetoothAlwaysUsageDescription` and `NSBonjourServices`
into the app's `Info.plist` (macOS holds the app responsible for the helper it starts), and signs the helper on its
own before the app: ad hoc without an identity, otherwise with the hardened runtime and a timestamp.
`mac.signIgnore` keeps electron-builder from re-signing it with the app's entitlements. The finished app is checked
against `friends.lock` (identifier, version keys, animal set, notices, usage keys, addon, signature, and that the
helper links only system libraries).

## Tests

| Command | What it proves |
|---|---|
| `node --test electron/friends-share-menu.test.cjs` (part of `npm run test:electron`) | File ▸ Copy Download Link: added once after Open…, shown only while the helper announces links, enabled only for a focused window with a model open, its choice sent to that window alone |
| `npx vitest run tests/friends-download-link.test.ts` (part of `npm test`) | Copy Download Link: the intent with the staged model and expiry, the URL copied, the helper's words shown, refusals, staging and clipboard failures, when it is offered |
| `node --test electron/friends-bridge.test.cjs electron/friends-files.test.cjs electron/friends-host.test.cjs` (part of `npm run test:electron`) | Validation against every PROTOCOL intent example, routing, helper file rules, the lock read the same in Node and shell, the host's lifecycle and IPC with a fake addon (Open only for offered files), the preload |
| `npx vitest run tests/friends-views.test.ts tests/friends-panel.test.ts` (part of `npm test`) | Every pinned fixture snapshot rendered through the real store: every display string appears; every fixture action maps to its intent; drag strings; mention serialization; resubscription; no hard-coded copy; project names fitted for staging |
| `node electron/friends-smoke.mjs` | The real Electron shell against two real helpers built from the pin, on loopback with temporary Friends homes (below) |
| `node electron/friends-package-smoke.mjs` | Ad hoc package as a directory, bundle check, and the packaged app starting its embedded helper in a temporary home |
| `npm run test:friends` | All but the package smoke |

The smoke tests never touch your own Friends identity, helper or data: every helper runs with `SZFRIENDS_STATE_DIR`
in a temporary directory (so it uses a file key store, never the Keychain, and contacts no Friends server), and the
two-helper smoke finds its peer only over loopback Bonjour with a service type of the run's own
(`SZFRIENDS_TEST_SERVICE_TYPE`). macOS lets a bundle browse and advertise only the Bonjour types its `Info.plist`
declares, so that smoke runs an ad-hoc signed copy of the pinned helper that also declares the test type. Both wait
for their helpers to exit.

To try the panel in a development run, give it a helper and a Friends home of its own; without both, Friends stays
hidden:

```sh
SHENZHEN_3D_FRIENDS_HELPER="$PWD/friends-src/portable/build/friends/Shenzhen Friends.app" \
SZFRIENDS_STATE_DIR="$(mktemp -d)" npm run electron:dev
```

## Tauri

The Tauri shell gets the same panel through `tauri-plugin-szfriends`, which lives in shenzhen-pdf
(`portable/friends/tauri/`, ADR 0015 § 4). It gives the main window `window.shenzhenFriends` with exactly the
methods of the Electron preload, and applies the Electron bridge's rules (the intents and fields the panel may send,
routing, helper files, staged files, links). Desktops reach a helper over PROTOCOL.md: the Rust helper on Windows
and Linux, the Objective-C helper on a Mac. Phones run the core in the app (the plugin's embedded mode, § Phones).

| Piece | Where | What it does |
|---|---|---|
| Pin | `friends.lock` `core_commit` | The shenzhen-pdf commit the plugin and the Rust helper come from |
| Setup | `scripts/friends/setup-tauri-friends.mjs` | Fetches or verifies that commit in `friends-core-src/` (or `SZF_FRIENDS_CORE_ROOT`), builds the helper stamped with the lock's version, stages it, the animal set and its acknowledgements under `src-tauri/friends/` |
| Feature | `src-tauri/Cargo.toml` `friends`, `friends-online`, `.cargo/config.toml`, `src-tauri/friends-placeholder/` | The plugin as an optional dependency; a placeholder answers it unless a Friends build points it at the pin, so builds without Friends need nothing else. `friends-online` adds the plugin's `online` feature for phones |
| Friends lock | `src-tauri/friends/Cargo.lock`, the plugin's `tools/host-build.sh` | The lock file Friends builds use with `--locked`: the app's `Cargo.lock` with the pin's plugin and core added (§ Locked builds) |
| Wiring | `src-tauri/src/friends.rs` | The plugin's configuration: who the app is, the formats it opens, the main window only |
| Capability | `src-tauri/capabilities/friends/capability.json`, `src-tauri/build.rs` | Friends' commands for the window `main` only, no remote URLs; declared at build time in Friends builds only |
| Packaging | `src-tauri/friends/tauri.conf.json`, `installer-hooks.nsh`, `handover.wxs` | The helper beside the app (NSIS, MSI, AppImage, deb, rpm), the animal set, and the installers' handover |
| Acknowledgements | `scripts/friends/helper-notices.mjs`, `src-tauri/friends/licenses/` | `Acknowledgements.txt` beside the helper on Windows and Linux: what the Rust helper carries (the EFF word list, the online stack, SQLite) from the pin's `ACKNOWLEDGEMENTS.txt`, and libdbus (AFL-2.1 or GPL-2.0-or-later) when the helper links it for Bluetooth, as on Linux; read from the built helper |
| Android release | `scripts/friends/android-release.mjs` | A release-profile APK with Friends, its native library stripped, signed with the computer's debug key: its size, for trying what people would install |
| Mac packaging | `src-tauri/friends/mac.conf.json` | The pinned Objective-C helper in `Contents/Helpers`, its usage descriptions and Bonjour types in the app's `Info.plist`, the acknowledgements |
| File menu | `src-tauri/src/friends.rs`, `src-tauri/src/lib.rs` | File ▸ Copy Download Link after Open File…, as in the Electron app |
| Links | `src-tauri/src/friends_links.rs`, `plugins.deep-link` in `src-tauri/friends/*.conf.json`, `friends/ios/Info.plist` | `shenzhen3d://friends/link#…` registered by Friends builds only and opened as the link's card in the main window |
| Smoke | `scripts/friends/tauri-smoke.mjs`, `tauri-smoke-mac.mjs`, `tauri-smoke-page.js`, `src-tauri/src/smoke.rs` | The app with the `friends-smoke` feature against two real helpers, the page driven from a script |
| Mac package check | `scripts/friends/tauri-package-check-mac.mjs` | What a Mac package carries: the pinned helper, its signature, the app's `Info.plist` keys |
| VM checks | `scripts/friends/tauri-vm.sh`, `tauri-package-check.sh`, `tauri-package-check.ps1` | The smoke, the installers and `cargo check` inside the Windows 11 and Ubuntu VMs. A run that fails or is interrupted still stops the AppImage, its Xvfb and the helpers it started, and removes its directory in the guest |

Build a Windows or Linux package with Friends:

```sh
npm run build
node scripts/friends/setup-tauri-friends.mjs        # once per pin and target
node scripts/platform-build.mjs desktop --friends --bundles nsis,msi     # or deb,rpm,appimage
```

### Locked builds

A Friends build resolves more crates than `src-tauri/Cargo.lock` holds (the plugin, the core and what they bring), so
it builds from a second lock file, `src-tauri/friends/Cargo.lock`, committed and moved with `core_commit`.
`platform-build.mjs --friends` checks it against the pin, copies it over `src-tauri/Cargo.lock`, builds with
`--locked` and puts the app's own lock back; `phones-size.sh` does the same. The plugin's `tools/host-build.sh`
(shenzhen-pdf `portable/friends/tauri/tools/`, in `friends-core-src/` here) makes, checks and vendors it, each time on
a copy of `src-tauri` in a temporary directory, so neither the app's lock nor the pinned checkout changes:

```sh
h=$(node scripts/friends/setup-tauri-friends.mjs --print-plugin)/tools/host-build.sh
bash "$h" lock   src-tauri src-tauri/friends/Cargo.lock       # after moving core_commit: adds Friends' crates,
                                                              # moves none of the app's
bash "$h" check  src-tauri src-tauri/friends/Cargo.lock       # still fits the pin (platform-build.mjs runs it)
bash "$h" vendor src-tauri src-tauri/friends/Cargo.lock <dir> # every crate a Friends build needs, for a build
                                                              # without the network (SZF_VM_VENDOR)
```

The lock covers every feature, `friends-online` and `friends-smoke` included. At `f807fc6cd` it adds 63 packages to
the app's lock and moves none. On Windows, where bash may be missing, `platform-build.mjs` skips the check and
`--locked` refuses a lock that no longer fits, in cargo's words.

On a Mac, `scripts/friends/setup-friends.sh` builds the Objective-C helper first, and `setup-tauri-friends.mjs`
stages it in `src-tauri/friends/mac/` with its animal set, signed on its own (ad hoc, or with
`APPLE_SIGNING_IDENTITY` and the hardened runtime), beside the acknowledgements and an `Info.plist` fragment of its
`NSLocalNetworkUsageDescription`, `NSBluetoothAlwaysUsageDescription` and `NSBonjourServices`;
`platform-build.mjs desktop --friends --bundles app` then places it as `Contents/Helpers/Shenzhen Friends.app`, as
ShenzhenPDF, Shenzhen Files and the Electron app carry it (macOS holds the app responsible for the helper it starts,
so the keys go into the app's own `Info.plist`). Check the result with
`node scripts/friends/tauri-package-check-mac.mjs "<…>/Shenzhen 3D.app"`.

**What runs when.** The plugin registers its commands and a small script that defines `window.shenzhenFriends` in
the main window; nothing else runs at launch. The panel joins after its first paint, as in Electron; the first
join locates the helper, reads the Enable Shenzhen Friends setting and connects. On Windows and Linux the app never
runs the helper from its own install: it copies it to `<Friends home>/helper/<version>-<build>-<digest>/` and
starts that copy (ADR 0015 § 14), so an installer can replace the app and its helper while Friends runs, and an
AppImage's helper outlives the app that mounted it. The NSIS and MSI installers then run the new helper with
`--handover`, which asks an older running helper to step aside through the protocol and changes nothing when the
running one is as new. AppImage, deb and rpm builds hand over when the app first connects, which the protocol
does by itself.

**Files.** The app keeps the browser's drag and drop, which is what shows where a drop will land, and the plugin
also hears the system's report of the same drop: WebView2 on Windows (the page hands it the dropped files), WebKitGTK
on Linux, the drag pasteboard on a Mac. A file dropped on Friends is sent from where it is, matched by name and size;
nothing is copied. A drop the system names no file for (something dragged out of another app without a file behind
it, or a folder) is refused in the helper's words. Phones give no paths: there each dropped file's bytes are staged
(`Friends/Outgoing/`, removed after 31 days, as in Electron) up to 250 MB, and a larger one is refused before it is
read ("Gearbox.step is too large to send from this device. Files you drop here can be up to 250 MB."). On Windows a
page names only drive-letter paths, never a network share (`\\server\share`): reading one would make Windows sign in
to that server. Open on a received file opens it in the viewer through the same path as the system's Open With, and
only for files a snapshot offered.

**File ▸ Copy Download Link** sits after Open File… while the helper announces `links`, enabled while the focused
window has a model open, with For 7 Days, For 1 Day and For 30 Days, as in the Electron app; the choice goes to that
window, which stages its model and copies the link as the header's button does.

**Friends links.** A `shenzhen3d://friends/link#<payload>` URL opened in a browser or another app opens the link's page
in the main window's panel, which shows its card once Friends is ready, as in the Electron app; the plugin checks the
URL first (PROTOCOL.md § Links) and never logs it. Only Friends builds claim the scheme. Windows: the NSIS and MSI
installers register it (the Tauri bundler reads `plugins.deep-link.desktop` in `src-tauri/friends/tauri.conf.json`), and
Windows starts the app with the link as its argument. Linux: the deb and rpm desktop entries register it the same way;
an AppImage only once an AppImage integrator installs its desktop entry. On both, `tauri-plugin-single-instance` makes a
second launch hand its link, or its files, to the running app and end, as Electron's single-instance lock does. A Mac:
`mac.conf.json` puts the scheme in the app's `Info.plist` and the system reports the link with the files it asks the app
to open. iOS: `friends/ios/Info.plist` declares it, and the system reports it the same way; a link that starts the
app comes with its first scene, which the windowing library's scene delegate does not pass on, so the app's
`gen/apple/Sources/shenzhen-3d/main.mm` hands it to the delegate's link method once the scene has connected. Android:
`tauri-plugin-deep-link` adds an intent filter for `shenzhen3d://friends` from `phones.conf.json` to the manifest of a
Friends build (`platform-build.mjs` puts the committed manifest back afterwards; `scripts/friends/android-links.mjs`
writes the same filter itself, since the plugin's build script runs only when cargo runs it again) and hands the
activity's link to the app, at launch or while it runs. `node scripts/friends/phones-link.mjs --platform android
--serial <emulator>` (a debug APK installed) opens a link that starts the app and one while it runs, each with its page
in the panel; it passed on 2026-10-17 in an Android 16 (API 36) arm64 emulator. `--platform ios --udid <simulator>` does
the same against a `friends-smoke` simulator build, opening each link from a UI test (`scripts/friends/ios-link-open`,
built for the run): `simctl openurl` makes the system ask "Open in Shenzhen 3D?" first, which nobody answers in a test,
and that, not the app, was why the link never arrived. It passed on 2026-10-19 in an iOS 26.5 simulator, and without
`main.mm`'s hand-over the link that starts the app shows no page. Phone builds carry the online part
(`friends-online`), so their Friends opens links as a computer's does. A Friends that announces no `links` (a
phone build without `friends-online`) gets a page that says in the app's own words that links open on a computer,
rather than asking the helper (whose refusal has no words) and showing Loading… for good; the link pages offer
**Open in Shenzhen 3D** on Windows and Linux, not on phones.

**What a Tauri build cannot do yet.** Linux x86_64 (only Arm was built: the x86_64 toolchain with WebKitGTK is
missing).

**Test homes.** A development or test run names a Friends home of its own with `SZFRIENDS_STATE_DIR` (and may name a
helper with `SHENZHEN_3D_FRIENDS_HELPER`); only debug builds and `friends-smoke` builds look, and the plugin itself
reads no environment, so a release build always serves the person's own Friends.

**What the Rust helper serves at this pin** (shenzhen-pdf `f807fc6cd`, `friends/m1` with the portable core merged;
`portable/docs/plans/friends-portable-core.md`). Messages and files with friends, the outbox's states, the views,
naming and automatic acceptance; people nearby (the local network on Windows and Linux, Bluetooth on Linux), friend
requests and Add by ID; friends online, a direct connection first and the relay last; friend links and download links
made, served, opened and received, so the helper announces `links` and Copy Download Link works against it; Delete
history on every computer of the profile; a person's other computers joining nearby or through the host, sync between
them, a friend's other computers, and a removed computer told so. Phone builds embed the same core with its online
part (`friends-online`). The panel says what it cannot do in the helper's own words.

**Tests.**

| Command | What it proves |
|---|---|
| `cargo test` in `portable/friends/tauri` (shenzhen-pdf) | The bridge's rules case for case with the Electron tests: validation over every PROTOCOL intent example, routing, helper files, staged names, link URLs; the link against the helper's own protocol server |
| `node --test portable/friends/tauri/guest/bridge.test.mjs` (shenzhen-pdf) | The guest script: the main window only, commands, ordered events, dropped files' paths asked of the plugin (through WebView2 on Windows), none on phones |
| `cargo test --features friends …` in `src-tauri` | The formats the plugin offers are the file associations; the capability names the main window only; the File menu's expiries; Friends builds declare the link scheme on every platform and builds without Friends on none; only that scheme is taken for a link |
| `npx vitest run tests/friends-drops.test.ts` | Desktops send paths and stage nothing; phones stage what fits and refuse a larger file before reading it; folders and other kinds are refused in the helper's words |
| `scripts/friends/tauri-vm.sh smoke windows-vm\|linux-vm <checkout>` | In the Windows 11 and Ubuntu VMs: the app with the Rust helper, a peer's helper driven over the protocol, two temporary homes made friends, a message both ways, a file accepted and opened in the viewer, a drop the system did not report refused, a dropped file sent from its path and received whole, a link opened by a second launch shown in the running app's panel while that launch ends, a second window without Friends |
| `scripts/friends/tauri-vm.sh package windows-vm\|linux-vm <checkout>` | NSIS and MSI, or deb, rpm and AppImage, carry the helper, the animal set and the acknowledgements (on Linux naming libdbus); a silent NSIS install over a running older helper makes it hand over to the new build, and so does the AppImage started while an older helper runs; the AppImage starts its helper from the per-user copy, which outlives the app and exits on its own. `SZF_VM_KEEP=<dir>` copies the installers out |
| `node scripts/friends/tauri-smoke-mac.mjs --app <app>` or `--bundle <Shenzhen 3D.app>` | On a Mac: the app with the Objective-C helper (with `--bundle`, the one the package carries in `Contents/Helpers`), the peer through the Electron addon over loopback Bonjour: naming, Nearby and a request accepted, then the same exchange |
| `node scripts/friends/windows-installer-check.mjs --setup <Setup.exe> --msi <msi>` | On the Mac, from the files: both Windows installers carry the helper beside the app, an x64 GUI program with this tree's helper stamp that needs no Visual C++ runtime DLL, the same in both, with the animal set and acknowledgements. `tools/release.sh` runs it on every Windows build |
| `scripts/friends/windows-installer-smoke.sh <Setup.exe>` | In the Windows 11 VM: the Setup installed silently, its helper run, then the app opened in Friends homes of the run's own (or, with `SZF_VM_HOME`, a kept profile, so no new Friends ID is made): Ctrl+J shows Friends ready; a helper copy removed as Defender quarantines one is written again and Friends is ready; a copy that can never start makes the panel say "Friends didn't start. Quit Shenzhen 3D and open it again." instead of "Starting Friends…" without end, with the reason in the app's `logs\friends.log`; the app opened again at once while the first launch's helper still runs (`lingering`), and while that helper hangs (`wedged`: the app ends it and starts a new one); the window opened and closed five times keeps its place and size, and one that earlier versions saved 9 px tall opens at a usable size again (`bounds`); the window minimized, then closed by Close window, by WM_CLOSE and by taskkill: the app ends each time, its helper still answers, and opening the app again while it runs minimized brings the window back (`minimized`); with `SZF_VM_FIREWALL=1`, as the guest's administrator between runs: no firewall rule on a Private network (`declined`: Nearby offers Allow on Private Networks), the rule on a Public network (`public`: Nearby says how to make it Private), the rule on a Private network (`allowed`: the helper listens on 48250-48257), a Block rule (`blocked`), and the friends already added listed throughout; then uninstalled |
| `node scripts/friends/tauri-package-check-mac.mjs <Shenzhen 3D.app>` | A Mac package carries the pinned helper with its animal set in `Contents/Helpers`, signed on its own and linking only system libraries, its usage descriptions and Bonjour types in the app's `Info.plist`, the acknowledgements, and an app signature that verifies around it |

All of these passed on 2026-10-17: the smoke in the Windows 11 VM (Arm, WebView2 155) and the Ubuntu 24.04 VM (Arm,
WebKitGTK 2.52, Xvfb) with the Rust helper and on an Apple M5 Max with the Objective-C helper pinned here; the
installer checks in both VMs; `cargo check` of the shell with and without Friends for macOS (Apple silicon and
Intel), Windows (x86_64 and Arm, in the VM), Linux (Arm, in the VM), Android's four ABIs and iOS. The Electron and
browser startup measurements did not move: Electron launch to Open enabled 297.1 ms before and 295.8 ms after,
two painted frames 308.7 and 305.9 ms (medians of 20, interleaved); browser cold first contentful paint 88.9 and
89.8 ms (means of 9); the critical JavaScript 93,330 and 93,332 bytes (a chunk name). The Friends button's chunk,
loaded after the first paint, grows by 690 bytes (the drop handling it now shares).

This pass (paths for desktop drops, the File menu item, the Mac package) was checked on 2026-10-17 by the vitest,
Electron and Electron Friends suites, the shell's `cargo test` with Friends, the Tauri smoke in the Ubuntu VM and on
macOS from a package (`--bundle`, the helper from `Contents/Helpers`), and the Mac package check.

The pin's move to `2d0525484` (with the phones merged) was checked on 2026-10-17 by the vitest suite (215 tests),
the Electron suites (85) and Electron Friends suites (24 and 54, and the smoke), the shell's `cargo test` with and
without Friends, the Tauri smoke in the Windows 11 VM (WebView2, which answered again), in the Ubuntu VM and on macOS
from a package, the Mac package check, the phones' exchange on Android and iOS and their size (§ Phones). The
helper now looks for friends nearby only once a client sends `activate`, as the panel does when it opens, so the
smoke's peer sends it too. The Ubuntu guest's clock had run 95 years ahead and failed crates.io's certificate:
`SZF_VM_VENDOR=<dir>` (a `cargo vendor` of the shell with the pinned plugin and of the core's workspace) builds there
without fetching. `setup-tauri-friends.mjs` builds the Rust helper with cargo started outside this repository: from
`friends-core-src/`, this repository's `.cargo/config.toml` applied to the core's workspace too, and `--locked`
refused the core's lock file (seen building for Linux on a Mac; the VM checks build in a directory of their own).
Startup against main `62b6bd4`, interleaved on the same Mac: Electron launch to Open enabled
270.4 ms on main and 268.9 ms here, two painted frames 284.8 and 280.4 ms (medians of 20); browser cold first
contentful paint 67.3 and 68.0 ms, shell painted 51.5 and 44.9 ms (means of 6); the critical JavaScript 92,985 and
93,329 bytes.

The pin's move to `4a608bc08` (both pins) was checked on 2026-10-19 by the vitest suite (248 tests), the Electron
suites (85), the Electron Friends suites (24 and 54, and the smoke) and the package smoke, the Tauri smoke on macOS
from a package with the Mac package check, in the Windows 11 VM and in the Ubuntu VM (a link opened while the app
runs shown in its panel on each), and the phones' exchange on an Android 16 emulator and an iOS 26.5 simulator, each
made for the run. `phones-link.mjs` passed on Android (on iOS it waited for the system's "Open in" question, since
answered, above). Startup against main
`62b6bd4`, 20 interleaved pairs twice on a Mac under load from other work: the paired median of Electron launch to
Open enabled moved -1.7 and +6.2 ms, two painted frames +0.2 and +10.1 ms, the candidate slower in 9 to 11 of 20
pairs, so no change shows.

On 2026-10-19 the installers were checked at `4a608bc08` with their acknowledgements: `tauri-vm.sh package` in the
Windows 11 VM for Arm and for x86_64 (NSIS and MSI carry the helper, the animal set and the acknowledgements; a silent
NSIS install over a running older helper makes it hand over), and in the Ubuntu VM (Arm): deb, rpm and AppImage carry
them, the deb's and AppImage's acknowledgements name libdbus, the AppImage started while an older helper runs makes it
hand over, starts its own from the per-user copy, and that copy outlives the AppImage and leaves on its own. The smoke
passed in the Windows VM on x86_64 (emulated) and in the Ubuntu VM. That guest's clock reads 2121, past what an rpm's
32-bit times hold, so `tauri-package-check.sh` bundles the rpm on its own with `scripts/friends/clock-shift.c`
preloaded, which moves the times past 2100 that the bundler reads back to the check's date (the guest's clock and
files stay as they are); the AppImage's runtime comes from the linuxdeploy the bundler keeps, so nothing is fetched.
The installers are in `~/Downloads` as `Shenzhen 3D Friends Test_0.1.9_*`.

The pin's move to `f807fc6cd` (both pins; `friends/m1` with `friends/core-rs` merged again, and on a phone the line
under the ID no longer says a taken ID is replaced once the app reaches the Friends server, which a phone never does)
was checked on 2026-10-19 by the vitest suite (253 tests), the Electron suites (85), the Electron Friends suites (24
and 54, and the smoke), the Tauri smoke in the Windows 11 VM (Arm) and in the Ubuntu VM, and the phones' exchange on
an Android 16 emulator made for the run; the release-size APK started there and its Friends panel opened. The Windows
VM is now set up through `cmd.exe` alone (`tauri-vm.sh`): PowerShell could hang in a guest that otherwise answered.

The locked builds (§ Locked builds), with the large STEP, selection, navigation and public-update work merged, were
checked on 2026-10-19 by the vitest suite (266 tests), the Electron suites (99), the Electron Friends suites (24 and
54, and the smoke), the update suites (33, and the Updates panel's check), the Playwright suite (35 passed, 5
skipped), a release-size Android build from the Friends lock with `--locked`, and a Mac package. The Tauri smoke and
the VM checks were not run again.

## Phones

Android and iOS builds with the `friends` feature run Friends inside the app (ADR 0015 § 3): the same panel, the
same frames, with the core in the app's process instead of a helper. `platform-build.mjs` builds them with
`friends-online`, the plugin's `online` feature: the host connection and the data channels, so a phone reaches
friends anywhere, not only nearby, and makes and opens links. They build with the core's `phone.toml` (the bundled
SQLite without what the store never uses) beside `phones-profile.toml`, and from the Friends lock with `--locked`. Build them with
`node scripts/platform-build.mjs android --friends --apk` or `… ios --friends …` after
`node scripts/friends/setup-tauri-friends.mjs --phones` (which needs only the pinned checkout: there is no helper).

| Piece | Where | What it does |
|---|---|---|
| Wiring | `src-tauri/src/friends.rs` | `embedded` on phones; no File menu; no "drop files" hint (nothing to drop from) |
| iOS keys | `src-tauri/friends/ios/Info.plist`, `phones.conf.json` | The local network and Bluetooth usage descriptions (the Mac helper's words) and `_szfriends._tcp`, merged into iOS Friends builds only |
| Privacy manifest | `src-tauri/gen/apple/shenzhen-3d_iOS/PrivacyInfo.xcprivacy` | No tracking, nothing collected; the reasons for file timestamps, elapsed time, disk space and user defaults |
| iOS project | `src-tauri/gen/apple/project.yml` | The system SQLite, CoreBluetooth and Network linked; simulator builds sign to run locally (ad hoc), so the Keychain works there |
| Backups | `src-tauri/gen/android/…/xml/data_extraction_rules.xml`, `backup_rules.xml` | Nothing of Friends' in backups or device transfers (it lives in the no-backup directory anyway) |
| Size | `src-tauri/friends/phones-profile.toml`, the core's `phone.toml`, `scripts/friends/phones-size.sh` | Friends' crates, the online part's included, built for size; what Friends with online adds per Android ABI, against the 5 MB budget |
| Exchange | `scripts/friends/phones-exchange.mjs` (`-page.js`, `-android.mjs`, `-ios.mjs`) | The phone app and a Friends service on the Mac, made friends: a message and a file each way |
| Remove | `scripts/friends/phones-remove.mjs` | Android: a long press on a friend's row (the emulator's own touch input), Remove, confirm: the friend leaves the list, and is still off it after the app starts again |
| Reset | `scripts/friends/phones-reset.mjs` | Android: Settings ▸ Reset Friends… and its confirmation (the emulator's own touch input): a new ID at once in Settings and the panel, the friends gone, Nearby running again, the new ID kept after the app starts again |
| Keyboard | `scripts/friends/phones-keyboard.mjs`, `src/core/keyboard.ts`, `MainActivity.kt`, `AndroidManifest.xml` | Android 15 (API 35, gesture navigation, Gboard) and 16 with the system's own on-screen keyboard (real taps, `adb shell input text`): in a conversation the composer, what is typed, its caret and the last message stay above the keyboard, with a long message and sideways too; so do the conversation's and the list's search, the names, Add by ID, the join page's ID and the viewer's Find a part… and Notes; and the window is resized for the keyboard, not panned. `--withhold-ime` runs it all again with the keyboard left out of the window's insets, as on the owner's POCO F7 (HyperOS, Android 15). Drawn edge to edge, Android 15 and later no longer shrink the window for the keyboard, so the activity pads the WebView's container by the keyboard's height, read from the insets or, where the phone leaves the keyboard out of them, from the window's visible frame; the activity asks for adjustResize, since a panned window cannot bring a field of a full-screen WebView into sight. iOS and browsers shrink only the visual viewport, which `keyboard.ts` measures as `--keyboard-inset` |
| Header | `scripts/friends/phones-header.mjs`, `src/components/HeaderMore.tsx` | Android, with a model open, at 320, 360, 393 and 412 dp wide, system font scale 1 and 1.3, upright and sideways: every header button lies inside the screen and takes a tap; each header command is a button or an item of the More menu (opened with a tap); Settings, tapped, opens. A narrow header first cuts the model's name short and then drops it, then the Open file shortcut hint and the wordmark, then moves Help, Share commented project, Settings and Close document into More, and last leaves Open file its icon only |
| Get again | `scripts/friends/phones-get-again.mjs` | Android and a Mac on one profile, with a friend: a file deleted on the phone comes back from the Mac with Get (a tap), one deleted on the Mac comes back from the phone with Get (a click in the real dropdown), one deleted on both comes back from the friend with Get again, and once the friend changed it, "Fay doesn’t have this file anymore." |
| Join | `scripts/friends/phones-join.mjs` | Android and a Mac joining one profile with real taps and clicks, each way: the phone's Settings ▸ Use my existing profile… (asks first, then resets and opens the join page), Approve and the code in the Mac's dropdown; or the Mac's Use my existing profile…, Approve and the code on the phone. Then the friend, the chat and You on both, each way |
| Attach files | `scripts/friends/phones-attach.mjs` | Android with the emulator's own taps: the composer's paperclip (Attach files) opens the system's document picker, two files of any kind picked there become chips and Send gives the friend both, byte for byte; a file shared from the Files app with "Send to a friend" opens Friends on the list and a tap on the friend sends it. The plugin copies picked and shared files as it reads them (never whole in memory), and phones declare `send.files` so the list's rows take them |
| Phone and Mac | `scripts/friends/phones-mac.mjs` | What those two are made of: the Mac (friends-ui-e2e's `phone` flow), a friend (`loopback-peer`), the test network's bridge (`szfriends-testnet dir`), the phone's page and taps |

What the plugin does on a phone (shenzhen-pdf `portable/friends/tauri/README.md` § Phones): the identity's key in the
Android Keystore (a sealed file in the no-backup directory) or the iOS Keychain (this device only), Friends' files
kept out of backups, a restored store without its key shown as "Friends can't continue from a backup on this device"
with Start again, Friends paused 20 seconds after the app leaves the foreground and resumed when it comes back,
dropped or attached files staged (up to 250 MB each), received files private to the app with Open (in the viewer) and
Share… (the system's share sheet; Save… or Share… on Android), and the nearby permissions asked for only when the
person opens Friends: Bluetooth on Android 12 and later (declared never used for location), location only on
Android 11 and earlier where Bluetooth scanning needed it, the local network and Bluetooth prompts on iOS.

**Tests.** `node scripts/friends/phones-exchange.mjs --platform android --serial <emulator> --tools <dir>` with a debug
APK installed, or `--platform ios --udid <simulator>` with a `friends-smoke` simulator build installed; `--tools` names
shenzhen-pdf's `befriend` and `loopback-peer` examples. The phone opens the panel, lists the friend, opens the
conversation from its row, sends a message and a staged file, sees the reply, taps Accept on the Mac's file, which
arrives with Open and Share…, and the files arrive whole on both sides. It then types `#` in the composer: a model
the phone opened from Open file is listed among the recent files with when it was opened, typing narrows the list,
and the chosen file, sent with Send from the copy the app keeps of it, arrives whole on the Mac. Both sides find each other on the core's test
network, a directory of entries on loopback: the simulator shares the Mac's, and for an emulator the script copies
each side's entries to the other while it runs, joining their ports with `adb reverse` and `adb forward`. It passed on
2026-10-17 in an Android 16 (API 36) arm64 emulator and an iOS 26.5 iPhone 17 Pro simulator, at the phones' first
pin and again with the pin at `2d0525484`. At the first pin the key store kept the same Friends ID across app
restarts on both, a store restored without its key showed Start again on both, and Start again made a new ID on
Android and iOS; on Android, Save… wrote the received file whole to Downloads through the document picker and Share…
opened the system's share sheet. `phones-size.sh` measures 4.14 MB added on arm64 against the 5 MB budget (with
Friends' crates built for size and thin LTO), down from 5.28 MB since Friends' capability is declared when the app is
built (`src-tauri/build.rs`) rather than added at launch, which linked Tauri's capability parser. With online on
(`friends-online`, the core's `phone.toml`, the online crates built for size, from the Friends lock) it measured
6.56 MB added on arm64 on 2026-10-19 (the library 6.32 MB without Friends, 12.88 MB with it): 1.56 MB over the
budget, and `phones-size.sh` says so by failing. Fat LTO instead of thin changed nothing. The core alone measures
4.95 MB with online (the plugin's README); the rest is the plugin's phone half and what Tauri links for it. Not yet
tried: a real phone, Android 11 or earlier, iPad, the iOS share sheet's choices.

**Reset Friends.** `node scripts/friends/phones-reset.mjs --serial <emulator> --tools <dir>` with a debug APK
installed (`--tools` as above, for `befriend`): the phone, made friends with Bo and Cy, opens Settings with a tap,
taps Reset Friends… and Reset Friends in the confirmation. Settings shows a new, different Friends ID at once, with no
failure shown; the panel lists neither friend and shows the new ID; the phone writes a new entry on the test network
(Nearby started again, as it was before); after a force-stop and a start, Settings still shows the new ID. It passed
on 2026-10-21 headless on an Android 16 (API 36) arm64 emulator. Before, confirming did nothing: the core refused
the reset as not yet available, with no words for the app to show.

**Get and Get again.** `node scripts/friends/phones-get-again.mjs --serial <emulator> --tools <core-rs target/release>
--mac <shenzhen-pdf build/friends-ui-e2e> --manifest <animal manifest> [--shots <dir>]` with a debug APK installed:
the phone's test home (befriended with Fay, the core's `loopback-peer`) is joined by ShenzhenPDF's Friends dropdown on
the Mac (friends-ui-e2e's `phone` flow, offscreen, step by step through two FIFOs), the Mac's helper meeting the phone
and Fay through `szfriends-testnet dir`, which joins the test network's directory to its Bonjour test type. Fay sends
a file, the phone accepts it with a tap and it copies to the Mac; deleted on the phone, it shows "On Test computer
mac" with Get, tapped, and comes back; deleted on the Mac, it shows "On ‹the phone's name›" with Get, clicked in the
dropdown; deleted on both, "Moved or deleted" with Get again, tapped, brings it from Fay; once Fay edited it, Get again
ends with "Fay doesn’t have this file anymore." It passed on 2026-10-21 on an Android 16 (API 36) arm64 emulator.
Phones now name themselves for the person's other computers from the system (Settings ▸ About's name, else the
model), where they used to be "Computer".

**Joining the person's profile.** `node scripts/friends/phones-join.mjs --serial <emulator> --tools <dir> --mac <dir>
--manifest <file> [--joins phone|mac] [--shots <dir>]`, the same arguments as Get and Get again, on the same pieces
(`phones-mac.mjs`; the Mac's steps are SPDFMacFriendsUIPhoneFlows.mm's commands, which now also click a button, fill
a field, read a join request's code and wait for words). `--joins phone`, the owner's case: the Mac has Fay and a chat
with her, made friends nearby; the phone has its own ID and its own friend. Settings ▸ Use my existing profile… asks
"Use your existing profile here?" naming the phone's own ID; Delete and Continue resets it and the join page opens by
itself; the Mac's ID typed, Continue; Approve clicked in the Mac's dropdown and its code typed on the phone, Join:
"This device now uses your profile". `--joins mac`: the phone has Fay; in the Mac's dropdown, Use my existing
profile…, the phone's ID, Continue; Approve tapped on the phone and its code typed in the dropdown. Either way Fay
and the chat's history arrive on the new one, its message reaches Fay and shows on the other, her reply reaches both,
and You carries a note each way (a message from the Mac goes through its client protocol; everything the Mac shows
is read from the dropdown). `--route online --forwarder <udp-forward>`: nobody meets nearby (no bridge, Fay on a test network of her own); the
script starts the local Friends host with its relay (`szfriends-testnet host`, from `$SZFRIENDS_HOST_SERVER_DIR` and
`$FRIENDS_TEST_COTURN`), the Mac's helper and Fay check in with it, the Mac and Fay become friends by ID through it,
and the phone reaches it on the Mac's loopback: its WebSocket through `adb reverse`, its relay and STUN through
`scripts/friends/udp-forward.rs` running on the emulator (`rustc --edition 2021 -O --target aarch64-linux-android
-C linker=<NDK aarch64-linux-android35-clang>`), since a test home's online stack reaches only loopback. The debug
app reads the host's list and keys from its test environment (kept beside its Friends home, which Reset Friends
empties). All four (phone or Mac joining, nearby or online) passed on 2026-10-21 on an Android 16 (API 36) arm64
emulator.

**Android permissions.** `node scripts/friends/android-permissions.mjs --serial <emulator> [--apk <apk>]` opens
Friends from a cleared app and answers the system's Bluetooth dialog through uiautomator: Allow grants scan,
advertise and connect; Don't allow keeps Nearby's Allow, which asks again; after a second refusal Android stops
asking and Nearby's Open Settings opens the app's page in Settings. It passed on 2026-10-20, headless, on an
Android 16 arm64 emulator. Until then no Android build had ever asked: Nearby's Kotlin plugin was registered under
the same Tauri plugin as FriendsPlugin, which replaced it, so every Nearby call failed. One class now answers both.

**Release-size Android build.** `node scripts/friends/android-release.mjs --target aarch64` (with `JAVA_HOME` naming a
JDK) builds the APK with Friends in the release profile, the native library stripped by cargo, and signs it with the
computer's Android debug key, so it installs on an emulator or a test phone but is never a published build; the debug
flow above is unchanged. On 2026-10-19 the arm64 APK weighed 18.36 MB, its `libapp_lib.so` 16.58 MB with no symbol
table or debug sections (the debug APK is about 449 MB); installed on an Android 16 (API 36) emulator it started,
and its Friends panel opened with a new ID. Built again the same day with online on (`friends-online`, from the
Friends lock with `--locked`), the arm64 APK weighs 20.62 MB and its `libapp_lib.so` 18.84 MB, carrying the data
channels' libraries; that build has not yet been run on an emulator.

## Limits

- **Copy Download Link** was tested with a fake helper reply (unit tests and the header in a browser) and, in the smoke
  test, hidden as it should be: the two-helper smoke reaches no Friends server, so its helpers never announce `links`.
  The Tauri File menu's item is tested by its states and expiries (the plugin's and the shell's unit tests), not by
  choosing it in a running app for the same reason.
- **Dropped files in the Tauri builds.** The smoke reports its drop to the plugin the way the system's listener does
  (a script cannot make the system drag a file); WebView2's, WebKitGTK's and the drag pasteboard's listeners are built
  and installed in each smoke run, and the pasteboard's reading is unit tested, but no real drag from a file manager
  ran in these checks.
- **Markdown.** Messages show as plain text with their links and mentions (the `segments`), as PROTOCOL.md allows for a
  host without a Markdown renderer.
- **Invisible characters.** The shared invisible-character marking (`fixtures/text/invisible-cases.json`) is for
  assistant proposals and literal-text cards; Shenzhen 3D has no assistant and does not implement it, so a stranger's
  name in a mention card shows as plain text.
- **Not hosted:** Cmd+K search export (the palette has Friends' commands, not its message search), the assistant (`/`, AI chat access), `message_status`.
- **Signing.** Only ad hoc builds were made and tested. A Developer ID build should check that the helper, signed with
  the hardened runtime and no entitlements, still starts, and that it and ShenzhenPDF's helper read the Keychain item
  without prompting. The Team ID check runs only in team-signed builds.
- **Architecture.** The app is packaged for Apple Silicon only, so are its helper and addon.
- **Licence.** shenzhen-pdf, the helper and its client library are GPL-3.0; Shenzhen 3D links the client library into
  `friends-link.node` and ships the helper. Shenzhen 3D is GPL-3.0-or-later, so the combined app is under the same
  licence.
