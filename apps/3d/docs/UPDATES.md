# Mac update packaging

The Chromium Mac app uses `electron-updater` 6.8.9. Each signed package has a fixed `releaseOwner` matching this repository’s owner. Its GitHub feed points to that owner’s `shenzhen-3D` repository and channel `latest`.

## Public and private releases

`PRIVATE_RELEASE_OWNER` in `electron/release-channel.cjs` is the only setting that decides how a build updates. It is `null` here: every build reads public GitHub releases through the releases API with no credential and no GitHub access step in the app. A copy that ships from a private release repository sets it to that repository's owner; builds for that owner keep the private behaviour described under [Authentication](#authentication). Packaging records the result as `releaseAccess` (`public` or `private`) in the signed package metadata and `build-info.json`, writes the matching `private` flag into `app-update.yml`, and the app refuses to update if the two disagree with its source.

## Build artifacts without publishing

Run `npm ci`, then `npm run package:electron:mac -- --release-owner=<github-owner>`, replacing the placeholder with this repository’s owner. The packaging script always runs a fresh production frontend build before creating its isolated staging directory. It invokes electron-builder with **`--publish never`**, even when publishing credentials or a Git tag are present. Publishing is a separate operator action.

For version `<version>`, the owner-labelled timestamped output directory under `artifacts/electron/` contains:

- `Shenzhen-3D-<version>-Apple-Silicon.dmg`, for installation.
- `Shenzhen-3D-<version>-Apple-Silicon.zip`, required by the Mac updater.
- `latest-mac.yml`, generated from those exact artifact bytes.
- Any builder-generated blockmap sidecars, retained with the corresponding artifacts.
- `build-info.json`, recording `releaseOwner`, source revision/dirty state, frontend SHA-256 hashes, production CJS hashes, the root lock hash, updater dependency versions/integrities and final artifact hashes.

The signed ASAR package metadata and build provenance contain matching `releaseOwner` values. `Contents/Resources/app-update.yml` contains `provider: github`, that same `owner`, `repo: shenzhen-3D`, `private` (`false` for public releases, `true` for private ones), `channel: latest`, and the updater cache directory. Packaging and runtime reject a mismatched source. The feed must contain **no token or authentication headers**. Packaging scans every file in the ASAR, `app-update.yml` and `latest-mac.yml` and fails if any of them contains a GitHub token.

The generated `latest-mac.yml` contains the application `version`, `releaseDate`, and `files` entries identifying the ZIP and DMG by filename, base64 SHA-512 and size where supplied by the target. Its compatibility `path` and top-level `sha512` identify the ZIP. The packaging script verifies those hashes and names against the files on disk. Preserve the generated YAML; renaming an artifact or recreating its ZIP changes the feed's fingerprint.

The app must remain signed with the expected Developer ID identity for Mac update verification. Current notarization configuration is unchanged. A successful local package build does not establish that private GitHub access, an actual version upgrade or notarization has been tested.

## Runtime dependency staging

Frontend dependencies are already bundled into `dist/`. The staged main-process manifest declares only the exactly pinned `electron-updater` dependency. The staging script includes production `electron/**/*.cjs` helpers, excluding test/spec files and test directories, so preload and updater helpers accompany `main.cjs`.

The staging directory contains real copies of the updater's resolved production dependency closure, including nested versions. It has no `node_modules` symlink. Every source package must remain inside the root installation produced by `npm ci`, match its root lock entry and be present in the thin staging lock. Nested `node_modules` directories are excluded while copying each package; only packages in the verified closure are copied separately. The final app does not depend on the developer's workspace.

The builder's `afterPack` hook verifies the completed ASAR **before signing**: all production CJS hashes must match, all locked package names/versions must be present, and every declared runtime dependency must resolve to a compatible version within the ASAR. Builder may hoist a nested dependency, so verification follows Node's package lookup inside the archive. This check never falls back to the workspace installation.

Verification performed with an actual unsigned `--dir --publish never` Mac build using electron-builder 26.15.3: its ASAR contains **16 updater runtime packages**, including `electron-updater` 6.8.9, without Three, React, Vite, Electron or electron-builder as app dependencies. Requiring `electron-updater` from the extracted ASAR succeeds. The new archive verifier rejects the earlier incomplete ASAR that contained only the updater itself. A collector-only check previously accepted a symlinked staging graph despite missing transitive packages in the ASAR; that staging approach has been removed.

`node electron/package-mac.mjs --stage-only --release-owner=<github-owner>` rebuilds the frontend and records the self-contained staging manifest/provenance without signing or creating installers. Full packaging additionally verifies the generated feed and artifact hashes. A signed DMG/ZIP package and real update installation must be checked separately after the app is frozen.

## Publish a complete release

Local upload helpers require an ignored `artifacts/operator/release-upload.json` owned by the current user, with file mode `0600`. Its schema is `{ "version": 1, "repositories": ["<github-owner>/shenzhen-3D"] }`. Set the owner to this repository. Missing or mismatched authorization fails before any remote operation. The assembly workflow creates its temporary configuration from `github.repository`. No publisher configuration or credentials are bundled with the app.

1. Freeze and commit the intended source; build the DMG and ZIP together. Inspect `build-info.json`, the app signature, packaged updater feed and generated `latest-mac.yml`. Run the native app smoke before publishing.
2. Create a version-tagged GitHub release with a strictly newer app version. Upload the unmodified DMG, ZIP, `latest-mac.yml`, relevant blockmaps and provenance. Keep a draft until the complete asset set is present and verified.
3. Publish each verified release as preview or stable as intended. Drafts are not eligible update releases. Upload only artifacts whose signed owner matches this repository, except when moving a private channel to the public one (below). The 0.1.6 upload guard verifies the adjacent provenance owner and source commit before uploading core assets. Verify each repository’s hashes against its own variant.
4. Test an older installed version: check, download, verify and install the update. For a private build, also test missing/expired credentials. Test an unavailable feed and cancellation using the app's raster/model workflow as appropriate.

Do not substitute a Tauri DMG, web ZIP, generic source archive or version-tag source ZIP for the updater ZIP. The updater artifact is electron-builder's ZIP containing the signed Chromium `.app`.

## Moving a private channel to the public one

Builds of a private release owner can be moved to the public channel through their own updater, once. Their updater accepts any newer release of their own repository whose ZIP is signed with the same Developer ID team and bundle identifier (Squirrel.Mac checks the replacement against the running app's designated requirement); it never reads the owner recorded inside the package it installs. Every private build so far (0.1.x, and 0.2.0 with `PRIVATE_RELEASE_OWNER` set) works this way.

1. Publish the public build of a version newer than every private release, on the public repository, as usual.
2. On the private repository, publish a release of that same version whose assets are the public release's Mac update files, byte for byte: the ZIP, the DMG, their blockmaps and `latest-mac.yml`. Leave out `build-info.json`, provenance, the README and the other platforms' packages. Its notes tell people that this version moves them to the open-source Shenzhen 3D and that updates come from there from now on.
3. A private build connected to GitHub finds that release, downloads it and installs it like any other. The installed app is the public build. It reads the public owner's releases without a credential. The GitHub access saved by the private build is deleted without being decrypted, because the saved settings name another owner. The automatic-check and preview settings are kept, and with automatic checks on it checks the public channel 20 seconds after its first start. Later releases on the private repository are no longer read, so the private channel has no other use after this.

`update-manager.test.cjs` covers the move in the app, and `tools/updater-e2e` checks it with the published private builds (`--expect-owner`, `--next-app`). Windows and Linux builds up to 0.2.1 have no updater, so installs there stay on their version until someone installs a newer package; from the first release with the updater they follow the public releases ([Windows and Linux](#windows-and-linux)).

## Authentication

Public builds have no authentication. They read the owner's releases from `api.github.com` without an `Authorization` header and ignore `GH_TOKEN`/`GITHUB_TOKEN`; the Updates panel shows no GitHub access section, and access saved by an earlier private build of the same source is discarded without being decrypted. Unauthenticated GitHub API requests are rate-limited per network address, which a daily check stays well within.

The rest of this section applies to private builds. In Shenzhen 3D, open **Updates** in the footer or **Shenzhen 3D → Check for Updates…**. The build’s repository is displayed read-only. Connect using an existing GitHub CLI login or a read-only repository token. The app verifies repository access before saving the token with Electron safeStorage encryption in a mode-0600 settings file. Credentials stay in the main process and are never returned to the viewer. Runtime source-switch requests are rejected. If a user installs a build from the other repository, credentials from the previous source are discarded without decryption; non-authentication preferences are retained. Connect again with access to the new build’s source.

Automatic checks are delayed until after the window opens and throttled to once per day. The updater module and its network stack stay off the first-paint path. Available updates are indicated in the footer. Download is explicit and runs in the background; installation requires **Restart & install** and a native reminder to save open projects. Closing the app normally does not install an update. Squirrel.Mac verifies the replacement app's code signature during installation; a downloaded ZIP alone is not proof that native signature verification has completed. Apps running from a disk image or translocated path must be moved to Applications before updating.

The current release stream uses preview releases, enabled by default. Turning previews off selects the latest stable GitHub release; until a stable release is published, that check may report that it cannot find an update feed. The web app continues to use its service worker; this updater applies to the packaged Chromium Mac app.

`private: true` selects private-feed behavior; it does not grant repository access. Shenzhen 3D explicitly supplies the connected recipient's token in the main process and refuses private-feed checks without one. It does not fall back to the library's unauthenticated public provider or bundle publisher credentials. Finder-launched apps normally do not inherit a terminal's environment, so the connection panel supplies authorized read access independently of shell environment variables.

A recipient credential needs permission to read releases/assets in the build’s repository. Keep it in the main process and appropriate OS credential storage. Never put credentials in the frontend, `electron-builder.cjs`, staged package metadata, `app-update.yml`, `latest-mac.yml`, build provenance or release assets. Publisher credentials have a separate purpose and must never be distributed with the app. No build-time credential is required to generate the feed locally with `--publish never`.

Primary implementation references: [electron-builder update metadata generation](https://github.com/electron-userland/electron-builder/blob/master/packages/app-builder-lib/src/publish/updateInfoBuilder.ts), [updater provider selection](https://github.com/electron-userland/electron-builder/blob/master/packages/electron-updater/src/providerFactory.ts), and [private GitHub provider](https://github.com/electron-userland/electron-builder/blob/master/packages/electron-updater/src/providers/PrivateGitHubProvider.ts). The installed versions and root lock remain the authority for this build.

## Android

The Android app updates itself from the same channel its APK comes from: the pre-releases of
`casimir-engineering/shenzhen-3D`, read through the public GitHub API with no account. `UpdatePlugin.kt`
(`src-tauri/gen/android/app/src/main/java/com/shenzhen3d/viewer/`) does the work; `src-tauri/src/android_updates.rs`
registers it and passes the page's calls (`window.shenzhenUpdates`, `src/core/android-updates.ts`) to it, so the
footer's Updates button and the Updates dialog are the Mac's, with **Update to X** and **Install update**.

- **When.** A few seconds after launch and then once a day while the app runs, when **Check daily** is on (the
  default), and never over a metered connection; **Check for updates** in the dialog checks at once, metered or not.
- **What.** The newest non-draft release whose tag (`preview-0.2.1`) is above the installed `versionName`, with an APK
  for the phone's ABI (`shenzhen-3d-<version>-android-arm64-….apk`) and a `SHA256SUMS.txt`.
- **Update.** On a metered connection the app asks first, giving the size. The APK is downloaded to the app's cache
  with its progress shown, checked against its line in `SHA256SUMS.txt`, then against the installed app: same
  package, a versionCode at least as high, the same signing certificate. Anything else is refused before Android sees
  it.
- **Install.** Android installs another app's APK only once the person allowed it ("Install unknown apps"). The first
  time, the app says why and opens that setting for Shenzhen 3D; back in the app, it hands the APK to
  `PackageInstaller`, and Android asks the person to confirm. Android replaces the app and stops it; the new version
  starts when it is opened again. The app's data stays.
- **Signing.** Android installs an update only when it is signed with the installed app's certificate. Every APK
  published so far (0.1.9, 0.2.0) is signed with the Android debug key of the Mac that built them,
  `~/.android/debug.keystore` (alias `androiddebugkey`, SHA-256
  `3C:BA:6B:D5:76:0E:ED:14:AE:08:B4:C9:11:B4:9A:EA:18:A8:AE:17:D6:17:22:55:4B:67:F9:C2:C1:2E:04:AD`).
  `scripts/friends/android-release.mjs` signs with it. **Keep that file**: an APK signed with any other key cannot
  update the installed app, and people would have to uninstall it, losing its data, Friends included. Moving to a
  release key later needs a key rotation (APK Signature Scheme v3 lineage) signed by this one.
- **Test.** `node scripts/android-update-e2e.mjs --serial <emulator> --old <apk> --new <apk> --new-version <x.y.z>`
  with two debug APKs (only debug builds read `files/update-api.txt`, which names the mock API): the old app finds the
  mock's newer release at launch, Update downloads it (with `--bad-sum`, a wrong checksum is refused first), the
  explanation and "Install unknown apps", Android's confirmation, and the new version running with its data.
  The mock also lists a newer Mac-only release and a newer draft, which must be passed over, as the real
  preview-0.2.1 (Mac only) is. Passed on 2026-10-20 on an Android 16 arm64 emulator, headless: 0.2.0 → 0.2.9 with a
  wrong checksum refused first, data kept. The release-profile 0.2.2 build checked the real API there and found
  itself up to date.
  `--release` runs it with release builds as people have them, the published APK included: the mock answers as
  `https://api.github.com`, with a test certificate authority trusted and the name pointed at the computer on the
  emulator only (adb root, a Google APIs image), undone at the end. Every step also fails the run if the page's red
  error banner shows, through the new version's first seconds. Passed on 2026-10-25, Android 15 arm64 emulator,
  headless: the published 0.2.2 → a test 0.2.91, data kept, no red error.
- **The page's first calls.** `node scripts/android-ipc-origin-e2e.mjs --serial <emulator> [--apk <apk>]` starts the
  app under a debugger and, while its page loads, makes its calls go out before onPageStarted, as a busy main thread
  does on phones. The page must show no red error and its calls must work. Before PageIpc.kt, it showed "Command
  plugin:event|listen not allowed by ACL", which people saw on the first launch after an update.
- **A test build over a release.** `node scripts/friends/android-release.mjs --target aarch64 --version 0.2.2` (or
  `--version-code <n>` alone; Tauri derives 2000 from 0.2.0) builds an APK that installs over a published one
  without being a release. The footer still shows `package.json`'s version; the Updates dialog shows the installed
  one.

## Windows and Linux

The Tauri app on Windows and Linux updates from the pre-releases of `casimir-engineering/shenzhen-3D`, read through
the public GitHub API with no account. `src-tauri/src/app_updates.rs` does the work and `src-tauri/src/release_feed.rs`
holds what it reads (both unit-tested); the page's `window.shenzhenUpdates` (`src/core/native-updates.ts`) is the
Mac's bridge, so the footer's Updates button and the Updates dialog are the Mac's, with **Update to X**, the download's
progress and **Restart & install**. There is one channel, so the dialog has no preview toggle.

- **When.** A few seconds after launch and then once a day while the app runs, when **Check daily** is on (the
  default), and not when Windows or NetworkManager says the connection is metered; **Check for updates** checks at
  once. On a metered connection the dialog gives the download's size before **Update to X**.
- **What.** The newest non-draft release above the installed version whose `latest.json` has an entry for this
  install and which has a `SHA256SUMS.txt`. Releases without them (Mac-only ones such as preview-0.2.1, and every
  release before this updater) are passed over for the next one down. The entry is chosen by how the app was
  installed, which Tauri's bundler writes into each installer's copy of the app: `windows-x86_64-nsis` (Setup),
  `windows-x86_64-msi` (MSI), `linux-aarch64-appimage` (AppImage), and `x86_64`/`aarch64` likewise.
- **Checks.** The installer is downloaded by Tauri's updater (`tauri-plugin-updater` 2.13.3, pinned), which refuses
  it unless its minisign signature verifies against the public key in `src-tauri/tauri.conf.json`
  (`plugins.updater.pubkey`) and names the version announced (`requireSignedVersion`). The app then checks the same
  signature itself and the file's line in `SHA256SUMS.txt`. Anything else is refused before it runs, and the dialog
  says the download didn't match.
- **Install.** Setup: the new Setup runs in passive mode (a progress window, no questions), replaces the
  installation in place and starts the new version. MSI: msiexec runs the new MSI in passive mode; MSIs install for
  all users, so Windows asks for administrator approval as it does for any MSI; the new version starts afterwards.
  AppImage: the file is replaced where it is (the folder must be writable) and the app restarts. People who installed
  the Setup keep updating with Setups, and MSI installs with MSIs.
- **deb and rpm.** A package manager installs these, and the app does not run it with administrator rights: the
  dialog says a new version is available and **Download** opens the new package of the same kind and architecture
  in the browser. No apt or rpm repository is published.
- **Before this updater.** 0.2.0 and earlier have none: people install the first release that has it by hand, once.

### The updater key

Every installer the Windows and Linux apps accept is signed with one minisign key, made with `tauri signer generate`
on 2026-10-20. The private key and its password are on the release Mac, outside any repository:

- `~/FriendsKeys/tauri-updater/shenzhen-3d-updater.key` (the private key, encrypted with the password)
- `~/FriendsKeys/tauri-updater/password.txt` (its password)
- `~/FriendsKeys/tauri-updater/shenzhen-3d-updater.key.pub` (the public key, also in `tauri.conf.json`;
  key id `03DA5522A283BC00`)

**Losing the private key or its password ends updates on Windows and Linux**: every installed app accepts only
installers signed by it, so people would have to download and install a new version by hand, once, to move to a new
key. Keep a copy of the key and the password somewhere other than this Mac. Changing the key means a release, signed
with the old key, whose `tauri.conf.json` names the new one.

### Releasing

The Windows and Linux installers are built in their own systems (`docs/PLATFORMS.md`). Once the release directory
holds them under their release names (or `--collect` copies them from the Tauri bundle folders), on the Mac with the
key:

```sh
node scripts/updates/release-updates.mjs --dir <release dir> --tag preview-<version> [--collect <bundle dir>]...
node scripts/updates/release-updates.mjs --verify --dir <release dir> --tag preview-<version>
```

The first signs the Setup, the MSI and the AppImage for that version, checks each signature against
`tauri.conf.json`, writes `latest.json` (each entry names the file's GitHub download address and carries its
signature), writes `manifest.plist` for the registered-devices `.ipa` (below) and writes `SHA256SUMS.txt` for every
file. Upload everything except the `.sig` files. A release whose `latest.json` is missing an installer simply isn't
offered to that kind of install.

## iPhone and iPad

The iOS app is the registered-devices `.ipa`, signed with the developer account's development identity and a profile
that lists the devices it installs on. It checks the same releases at launch and daily (`app_updates.rs`): a newer
release with a `manifest.plist` and a `shenzhen-3d-<version>-ios-registered-devices.ipa` is offered as **Update to X**,
with "Only iPhones and iPads registered for testing Shenzhen 3D can install it." **Update to X** gives iOS the link
`itms-services://?action=download-manifest&url=<manifest.plist's download address>`; iOS asks whether to install,
downloads the `.ipa` named in the manifest and replaces the app, keeping its data. A device that is not in the
profile cannot install it (iOS says it is unable to). To add someone, register their device on the developer
account, make a new profile with it and sign the next `.ipa` with that profile.

`release-updates.mjs` writes the manifest, after checking that the `.ipa` holds `com.shenzhen3d.viewer` at the
release's version. The manifest and the `.ipa` are served by GitHub's release download addresses, which answer
with a redirect to the file over HTTPS; iOS needs HTTPS for both. That a registered iPhone installs from these
addresses has not been tried yet: the simulator accepts the link but has no installer behind it. If a device says
it cannot connect, publish `manifest.plist` where it is served directly (without a redirect) and point the release's
`manifest.plist` asset there.

## Browser

The web build is not hosted anywhere (a ZIP in each release), so it has no update notice; whoever serves it updates
it by replacing the files.

## Testing

- **Unit.** `cargo test --lib release_feed` in `src-tauri` (tags, releases passed over, the manifest, checksums, and a
  signed file accepted while a changed one, another key's or another version's is refused), `node --test
  scripts/updates/release-updates.test.mjs` (release tooling) and `tests/native-updates.test.ts` (the bridge).
- **Windows and Linux, old to new.** `scripts/updates/vm-update-e2e.sh windows|linux <work dir> [--published <0.2.0
  release files>]` builds an old and a new test version in a Parallels VM (feature `updates-test-api`, which lets the
  app read a local copy of GitHub, `scripts/updates/mock-github.mjs`), signs the new one's installers here with the
  real key, and installs and updates them in the guest: Setup and MSI (each over the published 0.2.0), AppImage, and
  the deb's Download. The page driver (`tests/updates/drive-update.js`) clicks through the Updates dialog; the first
  download is changed by one byte and must be refused. Release builds have no such setting and always read GitHub.
- **iOS.** `node scripts/updates/ios-update-e2e.mjs --app <simulator test build> --release <dir> --tag
  preview-<version> --work <dir>` runs a simulator of its own, without the Simulator app.

Passed on 2026-10-20, with the real updater key: Windows 11 ARM64 VM (x64 builds), the published 0.2.0 Setup, then
a 0.2.2 test Setup over it, updated itself to 0.2.9 (the changed download refused first; 0.2.9 started and was up to
date); the same with the published 0.2.0 MSI and 0.2.2/0.2.9 MSIs (Windows Installer starts the new version on its
own; opened again, it was 0.2.9 and up to date). Ubuntu 24.04 ARM64 VM: a 0.2.2 AppImage updated itself in place to
the 0.2.9 file (changed download refused first); an installed 0.2.2 deb offered Download and opened the 0.2.9 deb's
address. iOS 26.5 simulator: 0.2.2 found 0.2.9, showed who can install it and handed iOS the itms-services link to
the release's manifest.plist. The test builds have no Friends, whose installer steps are the ones every install
runs; the rpm takes the deb's path in the app and was not run; installing over the air on a registered iPhone was
not tried.
