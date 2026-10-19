# package/ — Shenzhen Files.app + DMG packaging (PLAN.md §5 Phase 5)

Build a relocatable `dist/Shenzhen Files.app` and a styled
`dist/ShenzhenFiles-mac-arm64.dmg`
from the installed prefix at `<repo>/install`.

## Build pipeline

Run from the repo root, in order (re-run all three whenever the binary or the
install prefix changes — e.g. after other agents rebuild and `meson install`):

```bash
./tools/setup-friends.sh              # Shenzhen Friends at the friends.lock pin
meson install -C build --no-rebuild   # refresh install/ if the build changed
./package/make-app.sh                 # assemble "dist/Shenzhen Files.app"
./package/bundle-dylibs.sh            # bundle dylib closure + rewrite + sign
./package/make-dmg.sh                 # styled UDZO DMG (needs a GUI session)
```

| Script | What it does |
|---|---|
| `make-app.sh` | Assembles the bundle: binary + compiled C launcher (`nautilus-launcher.c`), Info.plist (PlistBuddy-stamped), AppIcon, share payload (nautilus data/ontology, compiled gsettings schemas, Adwaita+hicolor icon themes with regenerated caches, shared-mime-info db, gtk-4.0 emoji data, trimmed locales), gdk-pixbuf loaders with a relocatable `loaders.cache`, GIO modules with `giomodule.cache`, minimal fontconfig config. Shenzhen Friends: refuses to start unless `tools/setup-friends.sh --check` passes, then copies the helper into `Contents/Helpers/` with its version keys stamped from `friends.lock`, and the animal set and acknowledgements into `Contents/Resources/Friends/`; ends with `check-friends-bundle.sh`. |
| `bundle-dylibs.sh` | Transitive `otool -L` walker: copies the dylib closure into `Contents/Frameworks`, rewrites ids/references to `@executable_path/../Frameworks/…`, strips absolute rpaths, audits the result, then codesigns every Mach-O and the bundle (ad-hoc by default). The Friends helper is signed on its own line before the outer bundle, after checking it links system libraries only; ends with `check-friends-bundle.sh --signed`. |
| `check-friends-bundle.sh` | What the app carries of Shenzhen Friends: the helper's identifier (`com.intuition.shenzhenfriends`, shared with ShenzhenPDF), version keys from `friends.lock`, system-only libraries, minimum macOS; the animal set and acknowledgements against the pinned checkout; the Local Network and Bluetooth strings and the `_szfriends._tcp` Bonjour service in both Info.plists; with `--signed`, the helper's signature and the app's deep strict verification. |
| `test-friends-bundle.sh` | Packages the app (ad-hoc, never launched), checks the result and `codesign --verify --deep --strict`, then plants one defect per copy to prove each check fires. Needs `install/` and the Friends build. |
| `make-dmg.sh` | Staging dir → Retina-aware multi-representation TIFF background (600×400 at 1x plus 1200×800 at 2x) → UDRW image → Finder layout via osascript (128 px icons, 150/450 slots) → UDZO compression. `--check` verifies the source dimensions and required tools. |
| `make-icon.sh` | Regenerates `AppIcon.icns` + `dmg-logo.png` from the approved full-bleed `AppIcon-source-v7.png` artwork. Its white-to-icy-blue canvas is intentionally left unmasked so LaunchServices applies the native macOS enclosure and optical sizing; bundled code must not override `NSApplication.applicationIconImage`. |
| `nautilus-launcher.c` | Source of the exec wrapper; sets `XDG_DATA_DIRS`, `GSETTINGS_SCHEMA_DIR`, `GDK_PIXBUF_MODULE_FILE`, `GIO_MODULE_DIR`, `FONTCONFIG_FILE` relative to the bundle, then execs `Contents/MacOS/nautilus`. |
| `test-updater-helper-e2e.sh` | Mandatory signed-candidate updater test. It gives the disposable source a deliberately older identity, launches `--post-update` through Foundation `Process`/`NSTask`, observes readiness, performs the move-aside swap, confirms exact-path relaunch, and compares the final tag, build, executable, and icon with the differently-versioned staged payload. Same-version swaps are rejected as invalid coverage. |

## Standalone vs. Finder integration (installer-facing)

The DMG install is **standalone by default**: dragging Shenzhen Files.app to
Applications changes nothing about macOS. On the very first launch, the app
asks once — "Use as a Standalone App" (default) or "Set Up Finder
Integration…", which merely opens Settings ▸ Finder Integration. There the
user can individually enable: opening folders in Shenzhen Files by default,
syncing Finder's sidebar favorites, and hiding the Finder desktop. Every
toggle is opt-in, off by default, and revertible at any time (the app
records the pre-change system values in
`~/.config/nautilus/macos-integration.ini` and restores them, plus a
"Revert All Integrations" button). The Info.plist also declares a passive
"Open in Shenzhen Files" Services-menu entry, which is harmless in standalone use.

## Release procedure

Every public release must include its documentation update in the same clean,
tagged source state as the code being shipped. Before creating or moving the
release tag:

1. Update `SHORT_VERSION`, `RELEASE_BUILD`, and `BUNDLE_VERSION` in
   `make-app.sh`. `BUNDLE_VERSION` must remain globally increasing across all
   releases; the GitHub/self-update tag is `SHORT_VERSION-RELEASE_BUILD`.
   The Shenzhen Friends helper keeps the version of the Shenzhen PDF build in
   `friends.lock`; move that pin only with its `helper_build_number`. In the
   Shenzhen repository there is no pin: the helper is built from `apps/pdf`,
   and `tools/check-friends-number.sh` there must pass first.
2. Update the root `README.md`: change the `Latest <b>…</b>` marker to the full
   `SHORT_VERSION-RELEASE_BUILD` tag (the value stamped as `SZFReleaseTag`) and
   document every user-visible change.
   Review this packaging guide and `docs/STATUS.md` as well, updating them when
   the release changes their claims or instructions.
3. Regenerate changed assets, run the relevant tests and packaging checks, then
   commit the code, generated artifacts, and documentation together. Require a
   clean worktree before tagging.
4. For every updater-affecting change, pass the mandatory updater gates in the
   root `AGENTS.md` using the exact signed and notarized candidate. In
   particular, the previous public app must update to the candidate and the
   candidate helper must pass `package/test-updater-helper-e2e.sh` against the
   final signed candidate. That script spawns the helper through production's
   Foundation `NSTask` path, observes its readiness marker, and requires a real
   old-tag to new-tag transition; invoking `--post-update` directly or swapping
   identical version metadata does not satisfy this gate. Record the commands
   and results in the release notes.
5. Point the release tag at that exact commit and push the branch and tag
   together. In the Shenzhen repository the tag is `files/<tag>`; the GitHub
   release on casimir-engineering/shenzhen-files keeps the plain `<tag>`.
6. Sign, notarize, staple, and Gatekeeper-test the DMG before publishing it.
   Publish a normal release, not a draft or prerelease, with the notarized
   `ShenzhenFiles-mac-arm64.dmg` asset.
7. Verify GitHub's asset SHA-256 matches the local DMG and that
   `/releases/latest/download/ShenzhenFiles-mac-arm64.dmg` redirects to the new
   tag.
8. For updater changes, complete the two network gates in `AGENTS.md`: run the
   installed old-to-new flow with the exact notarized candidate through a
   disposable GitHub HTTPS feed before replacing the production asset, then
   repeat through the actual `releases/latest` API and production asset after
   upload. Verify the relaunched tag/build, executable and icon hashes,
   `update_ok`, and removal of `.old` and staging; delete the disposable assets.

`sign-and-notarize.sh` enforces the clean-worktree rule, checks that the root
README's advertised release matches the bundle tag, runs a signed-candidate
helper preflight before notarization, and repeats the helper test against the
quarantined app copied from the notarized DMG before it can publish anything.
The separate previous-public-release to candidate test remains a manual release
gate because it exercises the live GitHub download and notarized DMG path.
If that test is impossible only because the previously published helper exits
before it can replace itself, follow the narrowly scoped bootstrap exception in
`AGENTS.md`; it requires an exact old-helper reproduction, a notarized-DMG
manual replacement test, passing candidate-side gates, prominent disclosure,
and explicit user authorization before publication.

## Release signing + notarization (optional, env-gated)

By default everything is signed **ad-hoc** (`codesign -s -`), which is enough to
run locally. For public distribution, run **`./package/sign-and-notarize.sh`** —
one command that probes the keychain prompt-free (10-s timeout, aborts with the
`security set-key-partition-list` fix if the key ACL would prompt), re-signs the
whole bundle with Developer ID + hardened runtime, rebuilds and signs the DMG,
notarizes with the stored keychain profile, staples, verifies Gatekeeper accepts
a quarantined copy, clobbers the GitHub release asset, and re-checks the
API sha256 digest the self-updater consumes.

KEYCHAIN TRAP: if the Developer ID key was imported without partition IDs,
EVERY codesign call raises a GUI password prompt and typing the password does
NOT stick ("Allow" authorizes one use). Fix once, in your own terminal:

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "<your login keychain password>" ~/Library/Keychains/login.keychain-db
```

The underlying pieces follow the shenzhen-pdf
`portable/build-mac-release.sh` pattern:

One-time setup:

1. Create a **Developer ID Application** certificate (CSR via Keychain Access →
   developer.apple.com → Certificates → Developer ID Application → download and
   double-click the `.cer`). Only the account holder can create these.
2. Store notarization credentials in the keychain:

```bash
xcrun notarytool store-credentials <profile-name> \
  --apple-id <your-apple-id> --team-id <TEAMID> \
  --password <app-specific-password>   # from appleid.apple.com
```

Per release:

```bash
export MAC_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
./package/make-app.sh
./package/bundle-dylibs.sh     # signs with hardened runtime + timestamp when
                               # MAC_SIGN_IDENTITY is set, ad-hoc otherwise
./package/make-dmg.sh

xcrun notarytool submit dist/ShenzhenFiles-mac-arm64.dmg \
  --keychain-profile <profile-name> --wait
xcrun stapler staple  dist/ShenzhenFiles-mac-arm64.dmg
xcrun stapler validate dist/ShenzhenFiles-mac-arm64.dmg

# verification
codesign --verify --deep --strict "dist/Shenzhen Files.app"
spctl -a -t open --context context:primary-signature dist/ShenzhenFiles-mac-arm64.dmg
```

## Known relocatability limitations (current binary)

* `NAUTILUS_DATADIR` is baked at compile time to `<repo>/install/share/nautilus`;
  on machines without that path the tag-manager (starring) fails to find its
  ontology and starring is disabled (app otherwise unaffected). Fix belongs in
  the source port (resolve via `XDG_DATA_DIRS`), not in packaging.
* `libtinysparql` hardcodes its loadable-module dir inside the Homebrew Cellar
  (no env override exists). Its modules (FTS parser, HTTP) are not loaded during
  normal starring operation, so this only matters if FTS search over tags is
  ever exercised on a Homebrew-less machine.
* Bundled dylibs still contain `/opt/homebrew` strings in **data** sections
  (compile-time default search paths, all overridden by the launcher env or
  simply absent on clean machines). Mach-O **load commands** are 100 % clean —
  `bundle-dylibs.sh` fails the build otherwise.
