# Shenzhen 3D 0.1.9 delivery

The `preview-0.1.9` release adds native two-finger trackpad twist to the Chromium macOS app. It rolls the view around the current sight line without changing the model, measurement coordinates, current view center or zoom. Left and middle drag pan; right drag orbits around the current view center; trackpad swipe pans; pinch and mouse wheel zoom. Android and iOS retain one-finger orbit and two-finger pan/pinch.

Frozen runtime: `4f7dbf54ae08bb9c0b29d08e41a4808871292303`. All packages use 101 frozen frontend files, including `assets/index-C5HXuWIs.js`; `index.html` SHA-256 is `3f490eece7af43861f9d63a97718ddaa68ec2f9d024d665b15247d7d25a78159`.

## Packages

| Platform | Assets and scope |
| --- | --- |
| macOS Apple Silicon | Developer ID signed, notarized and stapled Chromium app in a Retina drag-to-Applications DMG and updater ZIP, with separate blockmaps/feed and verification evidence. Each distribution updates from its own fixed repository. |
| Windows x64 | NSIS EXE and MSI; unsigned. |
| Linux ARM64 | AppImage, Debian and RPM. Linux x64 is unavailable in this release. |
| Android ARM64 | Development-signed APK for direct installation and unsigned AAB requiring production Play signing. |
| iOS ARM64 | Development IPA for the existing 19 registered devices; profile expires 15 October 2027. Simulator archive preserves executable modes. Neither is an App Store distribution. |
| Web | Static ZIP; serve over HTTP(S). HTTPS or localhost enables the offline PWA. No hosted site was deployed. |

The full inventory contains 21 assets: ten Mac installer/updater/evidence files and eleven additional platform/provenance files. Published hashes and platform validation scopes are recorded in `build-info.json`, `notarization-verification.json`, `runtime-report.json`, `SHA256SUMS.txt` and `platform-provenance.json`.

## Verification

161 frontend tests, 61 Electron tests, 38 GPU rotation assertions and 1,262 navigation assertions passed. Production browser tests passed 33 cases with three expected viewport-specific skips. Each signed Mac package passed 20 runtime checks, nine native file-opening checks and seven limited native addon/IPC checks. Physical trackpad twist remains unverified; the native fixture establishes queue/IPC behavior and the GPU tests establish camera behavior.

Windows startup survived 15 seconds under x64 emulation in a Windows ARM64 VM. The final Linux ARM64 AppImage survived 15 seconds under Xvfb. Installer payloads, architecture, versions, permissions and frozen frontend assets were checked. These startup tests do not establish model rendering, physical input or GPU performance on those platforms.

The Android APK installed and launched in an API 35 emulator; signature and 16 KB ZIP/ELF alignment passed. Native touch was not tested because app-bound automation could not select the SDK emulator. The iOS simulator rendered the demo and measured two selected points; drag attempts did not establish camera movement, and pinch remains unverified. No physical mobile device was tested.

GitHub Actions jobs could not start because of account billing or spending limits. Packages were built locally instead. An isolated Linux x64 Rosetta build failed during chroot setup; no x64 package is claimed. The user's running applications and real profiles were preserved. There was no new native update-install replacement test for this version.

Earlier releases remain unchanged. See [Mac release notes](MAC-0.1.9.md), [controls](CONTROLS.md), [platform details](PLATFORMS.md) and [performance evidence](PERFORMANCE.md).
