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

`update-manager.test.cjs` covers the move in the app, and `tools/updater-e2e` checks it with the published private builds (`--expect-owner`, `--next-app`). Windows and Linux builds have no updater, so installs there stay on their version until someone installs the public package.

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
- **A test build over a release.** `node scripts/friends/android-release.mjs --target aarch64 --version 0.2.2` (or
  `--version-code <n>` alone; Tauri derives 2000 from 0.2.0) builds an APK that installs over a published one
  without being a release. The footer still shows `package.json`'s version; the Updates dialog shows the installed
  one.

Windows and Linux (Tauri) have no updater: the footer shows the version only, and people install a newer MSI, Setup
or Linux package from the release by hand.
