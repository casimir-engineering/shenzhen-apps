<h1 align="center">Shenzhen Files</h1>
<p align="center"><b>GNOME Files (Nautilus), ported to macOS as a fast native-feeling file manager.</b></p>

<div align="center">

<a href="https://github.com/casimir-engineering/shenzhen-files/releases/latest/download/ShenzhenFiles-mac-arm64.dmg"><img src="https://img.shields.io/badge/Download%20for%20macOS-Apple%20Silicon-2ea44f?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS (Apple Silicon)" height="46"></a>

<sub>Latest <b>26.10.31-1</b> · Apple Silicon</sub>

<a href="https://github.com/casimir-engineering/shenzhen-files/releases/latest">All releases</a> · <a href="https://github.com/casimir-engineering/shenzhen-files">Source</a>

</div>

<p align="center">Browse with tabs, grid and list views, starring, and batch rename — with native macOS thumbnails, Spotlight search, and a Finder-like Dock lifecycle. <b>Based on GNOME Files (Nautilus), a separate project, not affiliated with it.</b></p>

---

## What it does on a Mac

- **Feels at home on the Mac.** A real menu bar with the usual shortcuts, Quick Look thumbnails and the space bar preview, real app icons in Open With, the system Trash, and Show in Finder or Open in Terminal.
- **Tabs, grid and list views, stars and batch rename,** as in GNOME Files.
- **Drives in the sidebar.** The startup disk, external disks, disk images and network volumes appear as you plug them in, with an eject button. Ejecting a drive that is open first takes its windows back to Home.
- **Search as you type.** The search field finds files with Spotlight in the folder you are in. Plain words typed in the location field search too; paths and addresses still go there.
- **Copy and paste with Finder.** Files copied in Finder paste as the files themselves, even from read-only places.
- **⌘K finds any command** and shows its shortcut, such as New Folder or Show Hidden Files.
- **Stays open like Finder.** Closing the last window keeps the app running; click the Dock icon or press ⌘T for a new window.
- **Only changes your Mac when you ask.** Opening folders with Shenzhen Files by default, syncing Finder's sidebar favourites and hiding the Finder desktop are all off until you turn them on, and can be turned off again.
- **Updates itself.** It checks once a day, or when you choose **Check for Updates…**, and installs an update only once it has checked its signature and Apple's notarization.

## Friends (Beta)

Message people nearby or by their Friends ID, and send them files. **⌘J** opens and closes Friends. It is the same Friends as in ShenzhenPDF and Shenzhen 3D.

- Type **#** in a message to attach a file: the files selected in the front window come first, marked **Current**, then the folder's other files.
- Paste (⌘V) to attach files copied in Finder, or a screenshot.
- When new messages arrive while you read older ones, **New message ↓** takes you to them.

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
