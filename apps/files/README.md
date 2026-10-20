<h1 align="center">Shenzhen Files</h1>
<p align="center"><b>GNOME Files (Nautilus), ported to macOS as a fast native-feeling file manager.</b></p>

<div align="center">

<a href="https://github.com/casimir-engineering/shenzhen-files/releases/latest/download/ShenzhenFiles-mac-arm64.dmg"><img src="https://img.shields.io/badge/Download%20for%20macOS-Apple%20Silicon-2ea44f?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS (Apple Silicon)" height="46"></a>

<sub>Latest <b>26.9.14-1</b> · Apple Silicon</sub>

<a href="https://github.com/casimir-engineering/shenzhen-files/releases/latest">All releases</a> · <a href="https://github.com/casimir-engineering/shenzhen-files">Source</a>

</div>

<p align="center">Browse with tabs, grid and list views, starring, and batch rename — with native macOS thumbnails, Spotlight search, and a Finder-like Dock lifecycle. <b>Based on GNOME Files (Nautilus), a separate project, not affiliated with it.</b></p>

---

## What the port adds on macOS

- **Native menu bar** — the full GNOME Files menu rendered as a real NSMenu bar (File · Edit · View · Go · Window · Help), with working key equivalents.
- **Search commands with Cmd-K** — type a few letters to find a command (New Folder, Show Hidden Files, Preferences…, and Friends' own), move with the arrow keys, and press Return to run it. Each command shows its shortcut. Also in Help ▸ Search Commands….
- **Friends with Cmd-J** — opens Shenzhen Friends with the cursor in its search field, and closes it again, even from that field. Also in View ▸ Friends and in the Friends button's tooltip; does nothing while Friends is off.
- **Finder-like Dock lifecycle** — closing the last window keeps the app alive; clicking the Dock icon or pressing Cmd-T opens a new window, while Cmd-T adds a tab when a window exists.
- **Mounted drives in the sidebar** — the startup disk, external disks, disk images, and network volumes appear under mounts with native eject or unmount controls and automatic hot-plug refresh. Ejecting a volume that is open in Shenzhen Files first returns every affected window and tab to Home, releases its directory handles, and then safely ejects it.
- **QuickLook everywhere** — real macOS thumbnails in the grid, space-bar preview, and LaunchServices file-type icons for anything QuickLook can't draw.
- **Finder-compatible clipboard** — copying in Finder and pasting in Shenzhen Files transfers the original files, including from read-only locations, instead of mistaking Finder's preview image for the file.
- **Spotlight-backed search** — the search field streams results from Spotlight, scoped to the folder you're in; plain text entered in the location field searches there, while paths and addresses still navigate.
- **System integration, strictly opt-in** — open folders by default, sync Finder's sidebar favorites, hide the Finder desktop. Everything is off by default, revertible, and records the prior system state before changing anything.
- **Native Trash and permanent delete** — regular deletion moves items to the system Trash; Shift+Delete asks for confirmation before permanently deleting them. Show in Finder, Open in Terminal, and "Open With" are also bridged to native macOS services.
- **Useful Open With chooser** — installed apps show their real macOS icons, and apps explicitly chosen for a file type are promoted into a private, bounded Frequently Used section.
- **Full Disk Access onboarding** — a one-time walkthrough for the TCC grant that browsing the Trash needs.
- **Native-sized macOS icon** — the blue folder and legible 深圳 mark use the LaunchServices-rendered enclosure and optical safe area, matching neighboring Dock icons without a nested tile or oversized raw canvas.
- **Auto-update** — a silent daily check against GitHub releases plus a "Check for Updates…" menu item; updates download into persistent secure staging, verify offline (Developer ID + notarization, pinned Team ID and bundle id), atomically swap the bundle, refresh the app icon, and relaunch the exact new build in place.
- **Production-path updater testing** — release packaging exercises the signed helper through Foundation's real process-launch path, forces a genuinely different old-to-new version swap, and repeats the complete installed update through GitHub HTTPS with the notarized DMG. Final identity reads the `Info.plist` bytes on disk instead of a path-cached bundle object.
- **Retina installer artwork** — the DMG background carries native 1x and 2x representations, keeping its logo, wordmark, instructions, and arrow sharp on Retina displays.

## Install

Download the DMG above and drag **Shenzhen Files** onto **Applications**.

Releases are signed with Developer ID and notarized by Apple, so the app opens normally after download — no Gatekeeper workarounds needed.

> **Upgrading from a build through 26.9.12-1:** the
> already-installed helper can exit before readiness when Foundation launches
> it as a process-group leader. A direct shell test did not reproduce that
> production behavior. Those builds cannot repair their own installed helper;
> install `26.9.14-1` once by replacing the app in Applications. Automatic
> updates after that bootstrap use the corrected, production-path-tested
> helper.

<details>
<summary>First launch of an old, un-notarized build</summary>

If macOS blocks an older build with *“Apple could not verify 'Shenzhen Files' is free of malware”*: click **Done** (not *Move to Trash*), open **System Settings ▸ Privacy & Security**, scroll to the Shenzhen Files message, and click **Open Anyway** (on macOS 15+ the old right-click ▸ Open bypass no longer works). Terminal alternative: `xattr -d com.apple.quarantine "/Applications/Shenzhen Files.app"`. Better: just re-download the current notarized DMG.

</details>

For Trash browsing, grant Full Disk Access when the app offers the walkthrough (System Settings ▸ Privacy & Security ▸ Full Disk Access).

## Build from source

The port is maintained as a patch against upstream GNOME Nautilus plus a packaging pipeline:

```bash
# Homebrew deps: gtk4 libadwaita glib meson ninja pkgconf gettext \
#   gdk-pixbuf librsvg tinysparql gnome-autoar blueprint-compiler icu4c@78 \
#   libarchive json-glib desktop-file-utils shared-mime-info

# Fetch upstream at the pinned commit, apply patches/, verify, configure,
# build and install into ./install (safe to re-run)
./tools/setup-nautilus-tree.sh

# Fetch Shenzhen PDF at the commit in friends.lock into ./friends-src and
# build the Shenzhen Friends helper the app embeds (safe to re-run). In the
# Shenzhen repository it builds Friends from ../pdf instead, nothing fetched.
./tools/setup-friends.sh

./package/make-app.sh          # assemble dist/Shenzhen Files.app
./package/bundle-dylibs.sh     # bundle dylib closure + rewrite + sign
./package/make-dmg.sh          # styled installer DMG
```

See [`package/README.md`](package/README.md) for the packaging details and [`docs/STATUS.md`](docs/STATUS.md) for the current state of the port.

## Updater trust model

Releases are signed with Developer ID and notarized (the same setup as Shenzhen PDF); the updater verifies each downloaded update offline with Security.framework — full Developer ID requirement with a pinned Team ID, a stapled-notarization check on the DMG, and hardened-runtime + bundle-id pins on the extracted app. The sha256 digest from the GitHub API is checked as a corruption heuristic. The helper acknowledges verified persistent staging before the parent exits; the swap is a move-aside two-rename with checked rollback, and the relaunched app confirms the exact release tag before the previous bundle is discarded. A separate globally increasing `CFBundleVersion` keeps macOS bundle and icon caches ordered correctly. Release signing runs through `package/sign-and-notarize.sh` (sign every Mach-O with hardened runtime → exercise the signed updater helper through Foundation's production launch path → styled DMG → `notarytool` → staple → Gatekeeper-simulate on a quarantined copy → publish). Repository rules also require a real update from the previous public release to the candidate before publication.

## License

GPL-3.0-or-later, same as upstream Nautilus. The port patch and packaging scripts are under the same license.

The app also contains Shenzhen Friends, built from [Shenzhen PDF](https://github.com/casimir-engineering/shenzhen-pdf) (GPL-3.0) at the commit in [`friends.lock`](friends.lock), so Shenzhen Files.app as a whole is distributed under the terms of GPL-3.0 ([`LICENSE`](LICENSE), [`NOTICE`](NOTICE)). Shenzhen Friends includes libsodium (ISC), cJSON (MIT) and a selection from the EFF Large Wordlist for Passphrases (CC BY 4.0); their notices ship in the app as `Contents/Resources/Friends/Acknowledgements.txt`.
