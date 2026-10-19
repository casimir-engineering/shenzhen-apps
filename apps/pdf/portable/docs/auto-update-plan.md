# Auto-update plan for Shenzhen PDF

## TL;DR

Add a **lazy, once-per-day, very-low-priority** GitHub-release self-updater for the supported non-sandboxed Developer ID build. A runtime sandbox gate remains as a defense against unsupported third-party repackaging that cannot safely replace its own bundle. At launch, strictly after first paint, the primary process checks the latest GitHub release at most once per machine per day. If a genuinely newer, non-skipped version exists, it asks the user; on consent it downloads the notarized DMG, **verifies it offline (Developer ID + Team ID `66LJ4BV7Q3` pin + stapled notarization ticket)**, extracts the inner `.app`, atomically swaps the running bundle, and relaunches — restoring the full multi-window session.

The single integrity boundary is the **code-signature + Team-ID + stapled-ticket gate on the downloaded file**. Everything else (size, optional SHA-256) is a corruption heuristic, never a trust decision.

**Ship only the existing DMG.** No separate zipped `.app`.

All file:line references are to `/Users/raph/Projects/shenzhen-pdf/portable/`.

---

## DMG vs separate .app — recommendation (answer the user's exact question)

**Ship ONLY the existing notarized + stapled `ShenzhenPDF-mac-arm64.dmg` in the GitHub release. Do NOT add a separate zipped `.app`.** The updater mounts the DMG and `ditto`-extracts the `.app` itself.

Reasons, grounded in the real pipeline:

1. **The DMG is the single canonical, already-notarized+stapled artifact.** A second zipped artifact doubles upload size and creates divergence risk (two payloads that could disagree) for zero benefit. The mount → extract → verify → detach path is cheap (~1s, once per update) and idiomatic in this codebase (NSTask shell-outs already used at `ShenzhenPDFMac.mm:1936` / `:8244`).

2. **Correcting a common (wrong) justification — and an important caveat.** The reason is *not* "only the DMG is offline-stapled." I verified `Makefile:137` is exactly `xcrun stapler staple "$(MAC_DMG)"` — it staples **only the DMG**; `stapler` does **not** recurse into the DMG's contents, and there is no separate staple of the inner `.app` in the committed pipeline. So whether the *extracted* inner `.app` carries its own ticket depends on the build path and is **not guaranteed**. The DMG-only recommendation stands for the correct reasons (single canonical artifact, cheap one-time mount, no divergence) — and the verification design below is built so it **does not depend on the inner app being independently stapled** (see Security gates §5.6).

3. **The installer DMG layout is source-pinned.** The committed installer builder creates one root `ShenzhenPDF.app`, an `Applications` symlink, the custom background, and `.DS_Store`. The verifier deliberately discovers exactly one non-symlink root app and never pins the hdiutil-generated DMG codesign Identifier.

**Reconsider a zip only if** delta/binary-diff updates or a zip-only host appear later — neither applies today.

---

## Daily lazy update check (launch hook, QoS, 24h throttle, settings keys)

### Launch hook (exact)
Append to the **end of the inner `dispatch_after(kAfterFirstPaintDelay)` block** at the tail of `-applicationDidFinishLaunching` (`ShenzhenPDFMac.mm:865–885`), **inside the existing `if (self.restoreWindowID.length == 0)` gate (line 872)**, after the permissions-wizard / shortcut-help calls, additionally guarded by `!self.detachedTabLaunch`:

```objc
if (self.restoreWindowID.length == 0 && !self.detachedTabLaunch) {
    // ... existing default-reader / permissions wizard / shortcut help ...
    [[SPDFUpdater shared] scheduleDailyUpdateCheckIfNeeded];
}
```

This runs **strictly after first paint** (the block is dispatched after `[_pageScrollView displayIfNeeded]`), **after** `resumePersistentStateSavesAfterLaunch` lifts the save suspension (`:1962`), and **only in the primary user-launched process**. Every restored/detached sibling is a separate process running the same `applicationDidFinishLaunching` (proven by `spawnPendingRestoredWindowsIfNeeded` `:1927–1943` + `--restore-window` / `--detached-tab` parsing in `main()` `:15199–15235`); without this gate, N windows = N checks.

### `scheduleDailyUpdateCheckIfNeeded` body (fail-closed order)
1. `if (spdf_is_sandboxed()) return;` — unsupported sandboxed repackaging never self-updates.
2. `if (!_autoUpdateEnabled) return;` — persisted opt-out.
3. **Cross-process 24h gate.** Open `update.lock` (`O_CREAT|O_RDWR, 0600`), `flock(LOCK_EX)` — copying the exact idiom from `withLockedSessionStore:` (`:1816–1829`). Read `lastUpdateCheck` from `update.json` via `jsonObjectFromFile:` (`:1383`). If `now - lastUpdateCheck < 86400`, unlock and return. Otherwise **write `lastUpdateCheck = now` immediately** (`writeJSONObject:toFile:@"update.json"` `:1399`), then unlock. Stamping **before** the network call means a crash/abort/403 still consumes the day's slot — no hammering. (Note `writeJSONObject` is byte-idempotent and skips unchanged writes at `:1406–1408`; fine, the timestamp changes daily.)
4. **Idle delay:** `dispatch_after(~5s)` on a Background-QoS queue, then run the network check.

### QoS / queue
Use a dedicated `NSOperationQueue` (or `dispatch_get_global_queue`) at **`NSQualityOfServiceBackground`** — strictly below every existing queue (`_renderQueue`/`_findQueue` are UserInitiated; `_preloadQueue` and warming queues are Utility, set `:765–803`). There is no existing Background queue — create one. Do **not** reuse `_preloadQueue` or the launch-tail constants `kAfterFirstPaintDelay` (`:70`) / `…ColdLaunch` (`:78`) — those are tuned for render warming. The updater uses its own ~5s idle delay.

### Settings / state files
In `~/Library/Application Support/ShenzhenPDF` (resolved by `supportDirectory` `:1366`):

| File | Key | Type | Default | Purpose |
|---|---|---|---|---|
| settings.json | `autoUpdateEnabled` | BOOL | YES (Dev ID build) | gates daily check; menu toggle |
| settings.json | `skippedUpdateVersion` | NSString | nil | tag the user chose to skip permanently |
| update.json | `lastUpdateCheck` | number (epoch) | 0 | once/day gate, stamped pre-network |
| update.json | `highestVersionSeen` | NSString | nil | downgrade/replay high-water mark |
| update.json | `etag` | NSString | nil | `If-None-Match` conditional request |
| update.json | `remindAfter` | number (epoch) | 0 | "Later" snooze for a specific tag (see UI) |
| update.json | `deferredTag` | NSString | nil | tag that `remindAfter` applies to |
| update.json | `updateInProgress` | {pid,timestamp} | absent | cross-process single-driver **liveness lease** |

**Why split files.** `savePersistentState` participates in the launch save-suspension scheme (`_suspendPersistentStateSaves` set YES at `:827`, lifted ~50ms after first paint at `:1962`). Putting the daily timestamp in `settings.json` would defer/coalesce it during launch and force a daily full-settings rewrite. A dedicated `update.json` written via direct `writeJSONObject:toFile:` sidesteps the suspension and is the natural flock unit. `autoUpdateEnabled` / `skippedUpdateVersion` are user prefs and live in `settings.json` (load `:1424–1448`, save `:2001–2005`).

---

## Version comparison

**Self version:** read `CFBundleShortVersionString` + `CFBundleVersion` **directly from `NSBundle.mainBundle.infoDictionary`** (the source `-displayVersion` reads, `:2343–2350`) and join `"YY.M.DD-BUILD"`. **Do not** use the hard-coded `--version` printf at `:15203` (`"Shenzhen PDF portable mac 26.6.25-1"` — a literal that will silently drift from the plist on the next bump). **Fail closed:** if `CFBundleShortVersionString` is missing/unparseable, return **no update** — do **not** fall back to `displayVersion`'s `@"26.6.25"`/`@"1"` literals (`:2347–2348`), which could mask a real release or trigger a spurious install. *(Optional cleanup: fix the `:15203` printf to read the plist so the two never disagree.)*

**Remote version:** the release `tag_name`, same grammar (real tags `26.6.25-1`, `26.6.19-3`, `26.6.11-2`, `26.6.4-1` — month/day/build are **not** zero-padded).

**Comparator `spdf_compare_versions(a, b)`:** split each string on `[. -]` into integer components, compare element-by-element (shorter list zero-padded). **Must be numeric per-field** — lexical compare is provably wrong (`"26.6.25-1" < "26.6.4-1"` lexically but is newer). Treat **YY.M.DD as the primary key**; the `-BUILD` suffix is only a same-day tiebreaker (the build script never passes `MAC_BUILD`, so shipped `CFBundleVersion` may always be `1` even for a `…-2`/`…-3` tag — confirmed `MAC_BUILD` defaults at `Makefile:70`).

**Update available iff ALL hold:**
- `spdf_compare_versions(tag, runningVersion) == NSOrderedDescending`, **and**
- `tag != skippedUpdateVersion`, **and**
- `spdf_compare_versions(tag, highestVersionSeen) == NSOrderedDescending` (downgrade/replay guard), **and**
- release is not `draft` / `prerelease`, **and**
- an asset named exactly `ShenzhenPDF-mac-arm64.dmg` is present.

**`highestVersionSeen` policy (explicit):** advance it whenever a tag is observed as latest from a `200` response (replay/downgrade protection), **independent** of the user's Skip/Later choice. `skippedUpdateVersion` is orthogonal — it suppresses the prompt on the silent daily path only and is ignored on the manual path.

**Unit tests (required, pure functions):**
- `26.6.25 > 26.6.4` (non-padded)
- `26.6.11 > 26.6.4` (multi-digit day)
- `26.6.19-3 > 26.6.19-1` (build tiebreaker)
- `26.6.25-1 == 26.6.25-1` (no update)
- malformed input → ordered-same / no update
- **downgrade feed:** `tag < highestVersionSeen` → no update, even when `tag > running`

---

## GitHub release check (endpoint, asset pick, rate limits, ETag, failures)

**Endpoint:** `GET https://api.github.com/repos/casimir-engineering/shenzhen-pdf/releases/latest` via `NSURLSession` with `ephemeralSessionConfiguration` (no cookie/cache persistence). Greenfield — zero existing `NSURLSession` in the repo. No ATS exception needed (GitHub hosts are TLS 1.2+).

**Headers:**
- `User-Agent: ShenzhenPDF/<displayVersion> (macOS; +https://github.com/casimir-engineering/shenzhen-pdf)` — **required** (GitHub rejects UA-less requests).
- `Accept: application/vnd.github+json`
- `X-GitHub-Api-Version: 2022-11-28`
- `If-None-Match: <etag>` when a saved `etag` exists.

**Config:** `request.timeoutInterval = 15`; `configuration.waitsForConnectivity = NO` (offline launch fails fast and silently).

**Rate limit (60/hr/IP unauthenticated):** the file-locked once/day gate is the throttle — ≤1 API call per machine per day. Conditional `If-None-Match` requests returning **304 do not count** against the limit. On `304`: no new release, store nothing, return. On `200`: save the new `ETag`.

**Redirect / transport hardening (download phase):** the asset `browser_download_url` is an `api.github.com` redirect to `objects.githubusercontent.com`. Implement `URLSession:task:willPerformHTTPRedirection:` to: **reject any non-`https` hop** (no downgrade to http), **bound the redirect count** (e.g. ≤5), and continue only on https. Cap the download: if `totalBytesExpectedToWrite` (or bytes received) exceeds a sane max (e.g. **64 MB**, ~2× the current 32.6 MB DMG), abort the task.

**Asset selection:** parse `tag_name`, `draft`, `prerelease`, `assets[]`; pick the asset whose `name == "ShenzhenPDF-mac-arm64.dmg"`; capture `browser_download_url` and `size` (and `digest`/`sha256` if present).

**Failure handling (daily path is fully silent):** 403 rate-limit, non-200/non-304, timeout, offline, malformed JSON, missing asset → no-op. `lastUpdateCheck` is already stamped, so the next attempt is tomorrow. The explicit **"Check for Updates…"** menu path runs the same method but **bypasses the 24h gate**, **does not stamp `lastUpdateCheck`**, surfaces both outcomes (up-to-date / available), and routes failures through `-showError:detail:` (`:15189`).

---

## Download → verify → install → relaunch (security gates, atomic swap, rollback)

All steps run off-main on the Background-QoS queue with bounded timeouts; only the consent prompt, progress UI, and final relaunch touch main. Target path is **`NSBundle.mainBundle.bundlePath` resolved at runtime** (the app already self-resolves at `:1930` / `SPDFMacDefaultReader.mm:115`) — **never** hardcode `/Applications/ShenzhenPDF.app`.

**Single-driver liveness lease.** Before starting, take `update.lock` (flock) and write `updateInProgress = {pid: getpid(), timestamp: now}` to `update.json`. On entry, if an existing lease is present, treat it as **stale and reclaim it** when `kill(pid,0) == -1/ESRCH` (driver gone) **or** `timestamp` is older than a ceiling (e.g. 1 hour) — and sweep any orphaned staging dir. Only block when the recorded pid is **alive and recent**. Clear the lease on every exit path. This prevents a crash/SIGKILL mid-update from permanently wedging all future checks. Also keep an in-process flag so the same process clicking "Check for Updates…" while its own daily download is running takes the fast "already in progress" path.

### 5.0 Translocation guard (before anything)
If `bundlePath` contains `/AppTranslocation/` or is under `/private/var/folders` (Gatekeeper App Translocation), or the app is running from a DMG/Downloads, the bundle path is a throwaway shadow copy. **Do not self-update.** Show: *"To enable automatic updates, move Shenzhen PDF to your Applications folder."* (Moving the app clears quarantine/translocation, mirroring `install-mac-from-source.sh:86` `xattr -dr com.apple.quarantine`.)

### 5.1 Staging dir
`[NSFileManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:bundleURL.parentURL create:YES]` — guarantees the temp dir is on the **same volume** as the install target so the final rename is atomic. Pre-check free space ≥ ~3× DMG size before downloading. On launch, sweep stale `NSItemReplacementDirectory` staging dirs left by an interrupted prior run.

### 5.2 Download
`NSURLSession downloadTaskWithURL:` on the asset URL. Drive a **determinate** progress bar whose `maxValue` is wired to the **API `asset.size`** (not `totalBytesExpectedToWrite`, which is `-1` for chunked/CDN responses). Compute "X MB of Y MB" from `totalBytesWritten / asset.size`. Only fall back to indeterminate if `asset.size` was absent.

### 5.3 Content integrity (corruption heuristic ONLY — not a trust boundary)
- Reject if downloaded length `!= asset.size`.
- If the API exposed a `sha256` digest, compute `CC_SHA256` over a streamed read and reject on mismatch.

> **Adversary model:** `browser_download_url`, `size`, and any API `digest` all arrive over the **same channel**, so a full-channel MITM can lie about them consistently. These checks catch corruption, **never tampering**. **Never branch a trust decision on the API digest.** The only anti-tamper boundary is §5.4/§5.6.

### 5.4 Verify the DMG offline (BEFORE mounting) — exact gates
Use **Security.framework in-process** (not PATH-hijackable in a non-sandboxed process). The app and updater tests link `-framework Security`; removing it is a build failure.

- `SecStaticCodeCreateWithPath(dmgURL, …, &code)`.
- `SecRequirementCreateWithString(req, …)` with a **full Developer ID requirement**, not just an OU match:
  ```
  anchor apple generic and
  certificate leaf[subject.OU] = "66LJ4BV7Q3" and
  certificate 1[field.1.2.840.113635.100.6.2.6] exists and
  certificate leaf[field.1.2.840.113635.100.6.1.13] exists
  ```
  (pins the Apple Worldwide Developer Relations intermediate + the Developer ID Application leaf marker, so a leaf from any other Apple-anchored program with the same OU cannot satisfy it).
- `SecStaticCodeCheckValidityWithErrors(code, kSecCSDefaultFlags, req, &err)`.
- Independently `SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info)` and assert `info[kSecCodeInfoTeamIdentifier] == @"66LJ4BV7Q3"`. **Pin the Team ID, NEVER the DMG codesign Identifier** (it is the hdiutil-generated `ShenzhenPDF-installer`, verified live — an Identifier pin would break).

**Notarization — offline, authoritative on the stapled ticket:**
- The DMG carries a valid **stapled ticket** (verified live: `stapler validate <dmg>` succeeds). **Require the embedded/stapled ticket to be present and valid** — `SecAssessmentTicketLookup` against the embedded ticket, or `SecStaticCodeCheckValidityWithErrors` against a requirement that includes notarization.
- **Policy (no fail-open):** absence or invalidity of the embedded ticket is a **hard rejection**. A properly stapled DMG must **pass even when the machine is offline** (the ticket is embedded). **Never** fall back to an online assessment that a MITM/offline attacker could influence. `SecAssessment`/`spctl` may touch the network; use them only as best-effort corroboration with a short timeout — a network timeout alone must **not** abort an install whose signature + Team ID + stapled ticket already verified offline. CLI fallbacks, if used, must use **absolute paths** (`/usr/bin/xcrun stapler validate`, `/usr/sbin/spctl -a -t open --context context:primary-signature`).

**Abort on any verification failure**, routed to a verification-failed message that does **not** offer to install.

### 5.5 Mount read-only
`/usr/bin/hdiutil attach -nobrowse -readonly -noautoopen -plist <dmg>` via NSTask. Parse the returned plist and read the **real mount-point** solely from `system-entities` of **this attach's** output — **never** construct or assume `/Volumes/Shenzhen PDF` (a user's pre-mounted copy lands at `/Volumes/Shenzhen PDF 1`; verified the volname forces the mount point). Wrap the whole mount scope so it **detaches the exact returned mount-point in every exit path** (success, verify-fail, exception), with `hdiutil detach -force` fallback. Do **not** pre-detach a pre-existing user mount.

### 5.6 Extract + re-verify the inner .app (do NOT assume layout or inner stapling)
- **Discover the payload by globbing the mount**, not by hardcoding `<mount>/ShenzhenPDF.app`: scan for the single **non-symlink** `*.app` whose `CFBundleIdentifier == com.intuition.shenzhenpdf`; **skip the `Applications` symlink and `.background`**; abort if zero or >1 match.
- `/usr/bin/ditto "<discovered.app>" "<staging>/ShenzhenPDF.app"` (preserves signature + xattrs + any ticket).
- **Re-verify the extracted app offline via SecStaticCode** (always available, genuinely offline):
  - Same full Developer ID requirement + `kSecCodeInfoTeamIdentifier == 66LJ4BV7Q3`.
  - Assert the **hardened-runtime flag** (`info[kSecCodeInfoFlags] & 0x10000`, verified present live).
  - Assert `CFBundleIdentifier == com.intuition.shenzhenpdf` (this bundle-id pin applies to the **app**, never the DMG).
  - Assert the extracted bundle's `CFBundleShortVersionString` equals the tag's `YY.M.DD` (catches asset/tag mismatch or swapped payload).
- **Inner-app notarization is best-effort, not required.** The committed pipeline staples **only the DMG** (`Makefile:137`), so the extracted `.app` may carry no ticket of its own. The **authoritative notarization gate is the DMG-level stapled ticket already verified in §5.4** — it covers the payload. Re-asserting the inner app's Developer ID + Team ID + hardened-runtime + bundle-id offline is sufficient; do **not** make a passing inner-app *notarization* assessment a precondition (that would brick legit updates whenever the DMG-only build path is used).

### 5.7 Detach + strip quarantine
`/usr/bin/hdiutil detach <real-mount-point>` (force on failure) in the cleanup/finally path; delete the temp DMG. `/usr/bin/xattr -dr com.apple.quarantine "<staging>/ShenzhenPDF.app"` to avoid Gatekeeper translocation. **Never** execute the app from the mounted DMG or a quarantined/translocated dir. *(Note: files written by our own non-sandboxed process aren't auto-quarantined, so the downloaded DMG should mount cleanly; strip defensively anyway.)*

### 5.8 Quit sibling processes (bounded, with escalation)
Each window is a separate process holding the old bundle's text pages, so all must fully exit before the swap. Before quitting, the `updateInProgress` lease is already set so a waking sibling won't start its own update. Enumerate via `otherRunningShenzhenApplications` (`:1898–1906`). To avoid the N² terminate storm (each process's `applicationShouldTerminate` re-broadcasts `[app terminate]` to others; the guard `gSPDFTerminatingAllWindows` `:395` / `_terminateOnlyThisProcess` `:713` is process-local), have the driver send each sibling a "quit for update" request that sets `_terminateOnlyThisProcess = YES` so siblings don't re-cascade. The detached helper (§5.9) then **polls for zero instances with a bounded timeout (~10–20s)**; on timeout, escalate to `forceTerminate`; if instances still remain, **abort the swap** (bundle untouched), clear the lease, relaunch the original, and show *"Please quit all Shenzhen PDF windows and try again."* — the user is never left without a running app.

### 5.9 Atomic swap via detached helper (run from the CURRENT, trusted binary)
**Critically: spawn the swap helper from the CURRENTLY-RUNNING in-place binary** (known-good, already verified, not translocated) — **not** from the staged binary. Pass the staged path as an argument:
`--post-update <stagedAppPath> <targetBundlePath>`, parsed in `main()`. The §5.6 verification gate is a **hard predecessor** to executing any staged code: no unverified staged binary is ever exec'd; the staged app is exec'd only **after** it has been renamed into the final target path and re-registered.

**`main()` short-circuit (exact):** detect `--post-update` in the **first argv loop** (the same one that handles `--version` at `:15201–15206` and already `return 0`s without touching the delegate). Run the entire swap/relaunch helper inline as a plain Foundation function (no AppKit, no `NSApplication`, no `startLaunchPrerender` at `:15224`) and `return 0;` **before** constructing `ShenzhenMacDelegate`. Spawn the helper with the existing NSTask self-launch idiom (`executableURL`, std fds → `/dev/null`, `launchAndReturnError:`, `:1936–1941` / `:8244–8251`), and have the helper `setsid()` to detach from the parent's process group so it survives the parent's exit and the sibling-terminate cascade. Parent then exits.

The detached helper:
1. **Bounded poll** until zero running instances (§5.8). A short settle delay after exit (kernel map release).
2. **Probe writability by attempting the operation**, not by trusting `access(W_OK)` (which misses ACL/ownership/SIP edge cases). Current state: `/Applications` is `drwxrwxr-x root:admin`, the `.app` `raph:admin`.
3. **Swap — move-aside two-rename is PRIMARY** (battle-tested, matches the rest of this codebase's plain-`rename` usage; `renamex_np(RENAME_SWAP)` has **zero existing use** here and is fragile around firmlinks/mapped bundles):
   - `rename(bundlePath → bundlePath.old)`, then `rename(stagedApp → bundlePath)`.
   - `renamex_np(stagedApp, bundlePath, RENAME_SWAP)` is an **optional optimization** gated behind a same-volume + availability check; handle `EINVAL`/`ENOENT` (target missing) by falling through to the two-rename.
4. **Re-register Launch Services on the FINAL path:** `LSRegisterURL((CFURLRef)finalBundleURL, true)` (idiom at `SPDFMacDefaultReader.mm:115`) or `lsregister -f` — before relaunch, so LS never resolves a stale record.
5. **Relaunch** the new binary with **no path argument** so the standard restore path fans the **full multi-window session** back out (`:1499–1505` / `:1927–1943`): `NSWorkspace openApplicationAtURL:configuration:` (`:14191–14195`). Verify the relaunched app runs from the **real** `/Applications` path, not a translocated copy.
6. **Health signal + `.old` cleanup:** the relaunched process compares the complete date-and-build identity with `pendingTag`. On an exact match after `applicationDidFinishLaunching`, it writes `update_ok <newVersion>` to `update.json` (under `update.lock`), deletes `bundlePath.old`, and shows the one-time "now on `<newTag>`" confirmation. A mismatch keeps and reveals `bundlePath.old` for explicit manual recovery; it does not claim an automatic rollback.

### 5.10 Rollback
If move-in fails after move-aside, `rename(bundlePath.old → bundlePath)` restores the working install before relaunch. Retain `.old` until the new version confirms healthy (§5.9.6). If a later launch reports a different date or build than `pendingTag`, keep and reveal `.old` in Finder for manual recovery; the current updater has no watchdog that can safely replace a failed app after launch. **Never** `rm -rf` the running bundle (unlike the `Makefile install:` target, which assumes the app isn't running).

### 5.11 Not-writable fallback
If the actual rename attempt fails on bundle or parent (installed by another admin / root-owned / hardened `/Applications`): **do not** attempt sudo (no privileged-helper infra exists). Re-mount the DMG, reveal it in Finder, and `showError:` instructions to drag `ShenzhenPDF.app` to `/Applications` (the manual-update gesture). A future `SMAppService` privileged helper is the path to silent privileged install.

---

## UI interactions (every state, concrete copy, menu placement; non-intrusive)

All updater UI is **built only in the non-sandboxed build** (gate creation on `!spdf_is_sandboxed()`), and every action **re-checks the gate at runtime** (one binary, two builds). Reuse existing AppKit surfaces; the only new view is a cloned progress panel.

### Menu placement (`-buildMenu` `:2058`, app-menu block `:2063–2072`)
Insert a separator-bounded group **between "About Shenzhen PDF" (`:2064`) and "Set Up Permissions…" (`:2066`)**:
- **"Check for Updates…"** → `@selector(checkForUpdates:)`
- **"Automatically check for updates"** (checkbox) → `@selector(toggleAutomaticUpdateChecks:)`

### validateMenuItem (`-validateMenuItem:` `:15090`)
The no-document fallthrough at `:15175` (`if (!hasDoc) return action == @selector(unimplementedMenuItem:);`) disables any non-whitelisted selector when no document is open — the common cold-launch updater scenario. Therefore:
- Add `checkForUpdates:` to the always-enabled whitelist (`:15093–15101`). Keep it **always enabled** (don't gate on a cross-process file read in this hot path).
- Add a dedicated clause **before `:15175`** for `toggleAutomaticUpdateChecks:`: `menuItem.state = _autoUpdateEnabled ? On : Off; return YES;` (mirrors `toggleDefaultMinimapForNewDocuments:` `:15106`).

### States & copy

**A. Idle / silent.** Daily background check shows nothing on no-update or any failure.

**B. Update available — non-intrusive presentation (no focus theft).** The daily path fires ~5s after first paint on a background queue, by which point the user may be in another app. **Do not `runModal` and do not steal focus.**
- If `NSApp.isActive`: present a **non-activating sheet** on `_window` via `beginSheetModalForWindow:completionHandler:` (never `runModal` from a background context).
- If not active: **defer** — set a lightweight menu/About affordance and surface the sheet on the next `applicationDidBecomeActive`.
- The explicit "Check for Updates…" path (user just asked) may use a modal/centered alert when `_window == nil`.
- Copy — messageText: **"A new version of Shenzhen PDF is available"**; informativeText: **"Shenzhen PDF `<newTag>` is available — you have `<displayVersion>`. Would you like to install it now?"** (+ optional release notes, see below).
- Buttons in order: **"Install and Relaunch"** (`NSAlertFirstButtonReturn`), **"Skip This Version"** (`NSAlertSecondButtonReturn` → persist `skippedUpdateVersion = tag`), **"Later"** (`NSAlertThirdButtonReturn`).
- **Nag cap (no daily re-prompt):** "Later" sets `deferredTag = tag` + `remindAfter = now + 7 days`; the silent daily path suppresses re-prompts for that exact tag until `remindAfter`. "Skip This Version" is the permanent per-version suppression. The silent path respects both `skippedUpdateVersion` and `remindAfter`; the explicit menu path ignores both.

**C. Downloading** — clone the determinate translation progress panel (`:12376–12448`): `NSPanel` (titled) + `NSProgressIndicator` (Bar, `indeterminate=NO`, `maxValue = asset.size`) + semibold title **"Downloading Shenzhen PDF `<newTag>`"** + truncating-middle detail **"12.4 MB of 30.1 MB"** + **Cancel**. Cancel aborts the URLSession task, cleans staging, detaches the DMG.

**D. Verifying / preparing** — flip the bar to indeterminate (`startAnimation:`, as `:12444`) with detail **"Verifying signature…"** then **"Preparing update…"**. Post an accessibility announcement on each phase change so VoiceOver reads it.

**E. Ready to install — honest disruptive confirm (point of no return).** Because install quits **all** windows/processes and reopens them, before kicking the detached helper show: messageText **"Shenzhen PDF will close all windows and reopen them to finish updating."**, buttons **"Install Now"** / **"Cancel"**. The moment "Install Now" is accepted and the helper launches, **disable/dismiss Cancel** — after that, the only control is the helper's bounded-wait state, so the user can never believe they aborted while the swap proceeds.

**E′. Waiting for windows to close** — while the helper polls (§5.8): a non-modal status **"Waiting for other windows to close…"** with a Cancel that aborts cleanly (bundle untouched) until the point of no return.

**F. Up to date** (explicit check only) — `NSAlert`: **"You're up to date."** / **"Shenzhen PDF `<displayVersion>` is the latest version."**

**G. Failure** — every error funnels through `-showError:detail:` (`:15189`). The **verification failure** message must **not** offer to install: **"The update could not be verified and was not installed."** A failed swap restores the prior bundle immediately. A relaunch-version mismatch preserves and reveals `.old` in Finder for manual recovery.

**H. Already in progress** — when the user clicks "Check for Updates…": take `update.lock`; if a **live, recent** lease exists, show **"An update is already in progress."** (the daily auto-path returns silently). This moves the cross-process check off the validate hot path.

**I. Post-update success** — keyed off the `--post-update`/`update_ok` marker: a one-time confirmation **"You're now on Shenzhen PDF `<newTag>`."** after the disruptive relaunch.

### About panel (`-showAboutPanel:` `:2352`)
Under the version label (`:2380–2384`), **non-sandboxed only**, add a borderless link-style **"Check for Updates"** button calling `checkForUpdates:`. Give it an accessibility role of button + clear label, and make it keyboard-focusable. Tolerate `_window == nil` (`[panel center]`). `showAboutPanel:` is already whitelisted, so no validate change. **Do not** use `_statusLabel` (created `:3043`, never added to a view hierarchy) for any banner.

### Release notes (state B, optional)
The GitHub release `body` comes from the tracked `portable/docs/releases/YY.M.DD-BUILD.md` file. The release gate validates bullet highlights above one `---` divider, requires detailed notes below it, and caps updater highlights at 500 characters. The updater still treats API content as untrusted plain text and never renders it as rich Markdown.

**Accessibility:** all alert buttons have distinct self-describing titles; Esc → "Later"/"Cancel", Return → primary; post `NSAccessibility` announcements when indeterminate-phase detail text changes; set `accessibilityValue` on the progress indicator.

**Non-intrusiveness guarantees:** silent on no-update and all failures; surfaces a prompt only for an actionable, non-skipped, non-snoozed newer version; scheduled strictly post-first-paint on Background QoS; never steals focus from another app; nothing downloads or relaunches without an explicit click (no silent pre-download in v1).

---

## Settings, opt-out & repackaging defense (Developer ID distribution)

**Sandbox detection — add `spdf_is_sandboxed()`** (none exists; only prose comments at `:1679–1729`):
- Primary: `SecCodeCopySelf` → `SecCodeCopySigningInformation(self, kSecCSDynamicInformation, &info)` → inspect `info[kSecCodeInfoEntitlementsDict]` for `com.apple.security.app-sandbox == true`. The supported Developer ID app has **empty entitlements** (verified live); an unexpected sandbox entitlement indicates an unsupported repackaging.
- Cheap corroboration: `getenv("APP_SANDBOX_CONTAINER_ID") != NULL`.

**Every** entry point — daily check, both menu items, About affordance, all action bodies, `--post-update` — early-returns when sandboxed. The gate is a runtime defense because a sandbox forbids replacing `/Applications/*.app` and spawning the relaunch helper.

**Settings (user prefs, `settings.json`):**
- `autoUpdateEnabled` (BOOL, default YES for Dev ID) — load `:1424–1448` (`NSNumber* x = settings[@"key"]; if (x) _ivar = x.boolValue;`), save `:2001–2005`, mirroring `showShortcutHelpOnLaunch`. Toggled by the menu checkbox (calls `savePersistentState`).
- `skippedUpdateVersion` (NSString) — same load/save path.

**Opt-out:** unticking "Automatically check for updates" sets `autoUpdateEnabled = NO` → daily check early-returns at step 2; the manual "Check for Updates…" still works. A future Preferences window can bind `autoUpdateEnabled` directly; today the menu checkbox + About affordance are the surface.

---

## Security model & threats mitigated

| Threat | Mitigation |
|---|---|
| **MITM / compromised CDN serving a malicious payload** | The **only** trust boundary is the offline Developer ID signature + Team ID `66LJ4BV7Q3` pin + valid **stapled notarization ticket** on the file actually written to disk (§5.4/§5.6). Size/SHA-256 are corruption heuristics, never trust decisions. |
| **Forged "Dev-ID-but-unnotarized" DMG forced offline** | Stapled ticket is **required** and validated offline; absence/invalidity = hard reject. **Never** fail open to an online assessment a MITM could influence. |
| **Leaf cert from another Apple-anchored program with same OU** | Requirement pins the WWDR intermediate marker (`…6.2.6`) + Developer ID Application leaf marker (`…6.1.13`), not just OU. |
| **Wrong-Identifier pin breaking legit updates** | Pin Team ID, never the DMG Identifier (`ShenzhenPDF-installer`, verified) nor the inner-app-only bundle id on the DMG. |
| **Downgrade / replay (old signed release re-offered)** | `highestVersionSeen` high-water mark; numeric per-field comparator; `draft`/`prerelease` excluded. |
| **Transport downgrade / redirect abuse / zip-bomb** | https-only on every redirect hop, bounded redirect count, capped response size (~64 MB). |
| **PATH-hijack of `codesign`/`spctl`** | Security.framework **in-process**; CLI fallbacks use absolute paths only. |
| **Executing unverified staged code** | Swap helper runs from the **current trusted in-place binary**; staged binary exec'd only **after** §5.6 verification **and** after it's renamed into the final path. |
| **Rate-limit abuse / launch impact** | flock'd once/day gate stamped pre-network; Background QoS; strictly post-first-paint. |
| **Crash mid-update wedging all future updates** | `updateInProgress` is a **liveness lease** (pid + timestamp) that is reclaimed when the pid is dead or the lease is stale. |
| **Unsupported sandboxed repackaging self-updating** | Hard runtime gate on `spdf_is_sandboxed()` at every entry point. |
| **App Translocation corrupting the swap target** | Refuse to self-update from a translocated/DMG path; instruct user to move to `/Applications`. |
| **Untrusted release-notes Markdown injection** | Plain-text only, escaped, length-capped. |

---

## Open decisions for the user (each with a recommended default)

1. **Commit the installer-DMG pipeline before shipping the updater.** The shipped DMG (layout + `Applications` symlink + `ShenzhenPDF-installer` Identifier) is produced by **untracked** scripts (`dmg-background.swift`, `dmg-background.png`, `dmg-background@2x.png`), so the verifier's assumptions aren't source-pinned. **Recommended: commit them first**, and consider adding `xcrun stapler staple "$(MAC_APP)"` before `hdiutil create` so the inner app is deterministically stapled (defense-in-depth; the design does not require it).

2. **Post-"Later" snooze window.** **Recommended: 7 days** per tag, then re-surface. (Alternative: 3 days, or no re-prompt until a newer tag.)

3. **`renamex_np(RENAME_SWAP)` as an optimization?** **Recommended: skip it in v1** — ship the move-aside two-rename only; it's simpler and matches existing codebase patterns. Add `RENAME_SWAP` later if measured churn warrants.

4. **Release-notes display.** **Recommended: show a plain-text, length-capped excerpt + "Read more on GitHub"**, gracefully omitted when empty. (Alternative: omit notes entirely in v1 and just link to the release.)

5. **Privileged install for read-only `/Applications`.** **Recommended: v1 falls back to the manual drag-to-Applications instruction**; defer an `SMAppService` privileged helper to a later version.

6. **Sandbox detection signal.** **Recommended: entitlements-dict primary + `APP_SANDBOX_CONTAINER_ID` corroboration**, as specified.

7. **Fix the hard-coded `--version` printf (`:15203`)** to read the plist, as a small separate cleanup so it can't drift from the real version. **Recommended: yes.**

---

## Implementation outline (new files + edit points)

### New files
**`portable/mac/SPDFUpdater.h`**
- `+ (instancetype)shared;`
- `- (void)scheduleDailyUpdateCheckIfNeeded;`
- `- (void)checkForUpdatesUserInitiated:(BOOL)userInitiated;`
- free fns: `BOOL spdf_is_sandboxed(void);`, `NSComparisonResult spdf_compare_versions(NSString*, NSString*);`, `BOOL spdf_verify_signed_bundle(NSURL*, BOOL isApp, NSError**);`

**`portable/mac/SPDFUpdater.mm`** (`#import <Security/Security.h>`)
- `spdf_is_sandboxed()` (entitlements dict + getenv corroboration).
- `spdf_compare_versions()` (split on `[. -]`, integer per-field).
- `scheduleDailyUpdateCheckIfNeeded` (sandbox gate → autoUpdate gate → flock 24h gate → Background-QoS dispatch_after).
- `performNetworkCheck` (ephemeral NSURLSession, headers, ETag/304, https-only redirect + size cap, asset selection, version compare, `highestVersionSeen` update).
- progress panel clone (`:12376–12448`) + `updateDownloadProgress:detail:`.
- download task + content-integrity (size + optional CC_SHA256).
- `spdf_verify_signed_bundle` (SecStaticCode + full Dev-ID requirement + Team-ID + hardened-runtime + bundle-id for apps).
- DMG verify (stapled-ticket authoritative offline; SecAssessment best-effort; absolute-path CLI fallback).
- mount (hdiutil `-plist`, real mount-point from `system-entities`), glob-discover inner `.app`, ditto extract, re-verify, detach (finally), xattr strip.
- liveness-lease helpers + sibling-quit (bounded, `forceTerminate` escalation) + detached `--post-update` spawn (from current binary, `setsid`).
- `update.json`/`update.lock` read-modify-write helpers (flock idiom from `:1816`).

**`portable/mac/SPDFUpdaterTests.mm`** — the 6 comparator/downgrade cases in *Version comparison*.

### Edits to `portable/mac/ShenzhenPDFMac.mm`
- **`:865–885`** post-first-paint tail: add `[[SPDFUpdater shared] scheduleDailyUpdateCheckIfNeeded];` inside `if (self.restoreWindowID.length == 0 && !self.detachedTabLaunch)`.
- **`:764–803`** (optional) add an `_updateQueue` (`NSQualityOfServiceBackground`) ivar, or use the global Background queue.
- **`:1424–1448`** `loadPersistentState`: read `autoUpdateEnabled` (default YES), `skippedUpdateVersion`.
- **`:2001–2005`** `savePersistentState`: write the same two keys.
- **`:2058` / `:2063–2072`** `buildMenu`: insert the two updater items (gated `!spdf_is_sandboxed()`); add `checkForUpdates:` + `toggleAutomaticUpdateChecks:` action methods that forward to `SPDFUpdater` (runtime sandbox re-check).
- **`:2352` / `:2380–2384`** `showAboutPanel:`: add the non-sandboxed "Check for Updates" link button.
- **`:15090–15101`** `validateMenuItem:`: whitelist `checkForUpdates:`; add the `toggleAutomaticUpdateChecks:` state clause before `:15175`.
- **`:15201–15206`** `main()` first argv loop: parse `--post-update <stagedAppPath> <targetBundlePath>`, run the inline Foundation-only swap/relaunch helper, `return 0;` **before** delegate construction / `startLaunchPrerender` (`:15224`) / `NSApplication`.
- New delegate ivars: `BOOL _autoUpdateEnabled;` (init YES), `NSString* _skippedUpdateVersion;`.
- *(Optional)* fix the hard-coded `--version` printf at `:15203` to read the plist.

### Implemented `portable/Makefile` integration
- The app link includes `-framework Security` and keeps `-framework CoreServices`.
- `SPDFUpdater.mm` is in `MAC_SRCS`; `mac-updater-tests` links Cocoa and Security.
- The canonical release remains the single signed, notarized, stapled DMG.

---

## How we'll test it safely

1. **Comparator unit tests** — build/run `SPDFUpdaterTests`: the 6 cases (non-padded, multi-digit day, build tiebreaker, equality, malformed, downgrade-feed). Pure functions, no I/O.

2. **Sandbox gate** — test `spdf_is_sandboxed()` as a pure repackaging defense: the supported Developer ID build must return `NO`; an isolated temporary test fixture carrying the sandbox entitlement must return `YES` and expose no updater entry point.

3. **Network check in isolation (no install)** — hidden `--check-updates-now` argv flag (Dev ID only) running `performNetworkCheck` with `userInitiated=YES`, logging parsed `tag_name`/asset/decision and **stopping before download**. Verify ETag/304 by running twice; verify the 24h gate by inspecting `update.json`.

4. **Verification gates against the real artifact** — point the verifier at local `dist/ShenzhenPDF-mac-arm64.dmg` (notarized+stapled, Team `66LJ4BV7Q3`, verified live) → expect pass. Negative tests, each must fail before the swap: (a) ad-hoc re-sign (`codesign -f -s -`) → Team-ID/Dev-ID requirement fails; (b) flip a byte → SecStaticCode validity fails; (c) different-team DMG → requirement fails; (d) strip the stapled ticket → notarization gate fails; (e) DMG with a payload `.app` whose `CFBundleShortVersionString` ≠ tag → §5.6 version assert fails.

5. **Install/swap against a throwaway target — never `/Applications` first:**
   - Copy the app to `/tmp/ShenzhenTest/ShenzhenPDF.app`, launch from there (updater targets `NSBundle.mainBundle.bundlePath`).
   - Stage a fake "newer" DMG: bump `CFBundleShortVersionString`, **re-sign with the same Developer ID + staple**, host on `python3 -m http.server`, point a debug `updateFeedURL` override at a hand-written `releases/latest` JSON.
   - Exercise the full flow: move-aside swap, install-time restoration on failure, `.old` retention, exact date-and-build `update_ok` health marker, relaunch from the new binary, post-update success banner, and manual-recovery reveal after a relaunch mismatch.
   - Liveness lease: kill the driver mid-download, confirm the next run reclaims the stale lease.
   - Not-writable fallback: `chmod a-w /tmp/ShenzhenTest` → expect the drag-to-Applications instruction, no crash.
   - **Multi-process:** open 2–3 windows (separate processes), trigger install from one; confirm siblings terminate (with a wedged-sibling timeout/forceTerminate test), only one process drives the swap (others see "already in progress"), and the **full multi-window session is restored** after relaunch.
   - Translocation: run a quarantined copy from a mounted DMG → expect the "move to Applications" message, no swap.

6. **Per MEMORY constraint:** after any test launch, **kill the app and restore `session.json`** before finishing.

Only after all of the above passes against `/tmp` should you test a real `/Applications` self-update on a recoverable machine.

---

**Current load-bearing facts:** the pipeline staples and authenticates the DMG before mounting; verifies the contained app before executing it; links Security.framework; source-controls the installer layout; pins Team `66LJ4BV7Q3`, bundle `com.intuition.shenzhenpdf`, arm64, and macOS 12.0; and publishes one exact-name DMG asset from tracked notes.
