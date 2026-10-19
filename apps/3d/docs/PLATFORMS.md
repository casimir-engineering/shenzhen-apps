# Platforms and packaging

Shenzhen 3D uses one local React/Three.js viewer. The primary macOS application uses Electron for Chromium GPU rendering and native trackpad classification/rotation; Windows, Linux, Android and iOS use a Tauri 2 native shell. Files are parsed locally. Native applications package the same static assets as the web application; they do not need a running web server.

| Platform | Package | Build command |
| --- | --- | --- |
| Web | Static site / installable PWA | `node scripts/platform-build.mjs web` |
| macOS 13+ Apple Silicon (Chromium) | `.app`, `.dmg`, updater ZIP | `npm run package:electron:mac -- --release-owner="<github-owner>"` |
| macOS 12+ (lightweight Tauri) | `.app`, `.dmg` | `node scripts/platform-build.mjs desktop --bundles app,dmg` |
| Windows | NSIS `.exe`, MSI | `node scripts/platform-build.mjs desktop --bundles nsis,msi` |
| Linux | AppImage, Debian, RPM | `node scripts/platform-build.mjs desktop --bundles deb,rpm,appimage` |
| Android 7+ | APK, AAB | `node scripts/platform-build.mjs android --apk --aab` |
| iOS/iPadOS 15+ | App archive, simulator app | `node scripts/platform-build.mjs ios --archive-only` |

Desktop packages with Shenzhen Friends add `--friends` after `node scripts/friends/setup-tauri-friends.mjs` has staged the pinned helper (the Rust helper on Windows and Linux; on a Mac the Objective-C helper `scripts/friends/setup-friends.sh` builds, placed in `Contents/Helpers`; see [Friends](FRIENDS.md#tauri)); without it the Tauri builds carry no Friends.

Build on the target desktop operating system. Windows uses WebView2; its installer bootstraps the runtime when needed. Linux requires WebKitGTK 4.1. Browsers and native webviews need WebGL2 and WebAssembly. Complex CAD documents require enough memory for both the CAD kernel and triangulated geometry; mobile devices generally have lower limits.

## 0.1.9 build checkpoint

Runtime source: `4f7dbf54ae08bb9c0b29d08e41a4808871292303`. Builds use 101 frozen frontend files with `assets/index-C5HXuWIs.js`. The historical records below describe earlier versions. See [current delivery](DELIVERY.md) for the 0.1.9 package inventory and validation limits.

| Platform | Build and verification |
| --- | --- |
| macOS Apple Silicon | Signed Chromium app and DMG; packaged runtime, file opening, native addon and integrity checks passed. App and DMG notarization, stapled tickets, Gatekeeper and final Finder layout passed. |
| Windows x64 | EXE and MSI built locally in Windows; executable architecture/version and embedded frontend checked; isolated startup passed for 15 seconds. Unsigned. |
| Linux ARM64 | Debian, RPM and AppImage built locally in Ubuntu; final AppImage startup passed for 15 seconds under Xvfb. Package permissions and extracted payloads passed verification. |
| Android ARM64 | Development-signed APK and unsigned AAB built; APK signature and 16 KB alignment passed. Installed and launched in an API 35 emulator. Native pan/pinch unverified. |
| iOS ARM64 | Simulator archive and development-signed IPA built. IPA covers the existing 19 registered devices, with profile expiry 15 October 2027. Simulator rendered the demo and measured two selected points; drag/pinch unverified. |
| Web | Static ZIP verified against every frozen frontend file. Production browser tests passed 33 cases with three expected viewport-specific skips. No hosted deployment. |

GitHub Actions jobs could not start because of account billing or spending limits, so these packages were built locally. The isolated Linux x64 Rosetta build failed during chroot setup; there is no 0.1.9 Linux x64 artifact. Native startup checks do not establish full interaction coverage. No physical phone, tablet or Intel Mac was tested. Android's development signature and the registered-device IPA are not store distributions.

## Local development

Install Node.js 24+, Rust stable, and the [Tauri platform prerequisites](https://v2.tauri.app/start/prerequisites/), then run:

```sh
npm ci
npm run tauri dev
```

For the browser use `npm run dev`. Vite runs on port 1420. Production assets go to `dist/`. Native desktop installers go to `src-tauri/target/release/bundle/`.

The native shell provides standard File/Edit/Measure/View/Window/Help menus, keyboard shortcuts, resizable windows, full screen, additional viewer windows, and saved window geometry. File dialogs and filesystem access use Tauri's permission system. Only files chosen through the native picker are added to the filesystem scope; there is no blanket home-directory grant. Dropping files uses the viewer's HTML drop handler. Browser file input remains the portable fallback.

Menu actions are delivered to the focused window as `native-menu` events with `{ action }`: `open`, `export`, `fit`, `isometric`, `front`, `top`, `right`, `clear`, `point`, `feature`, `settings`, `help`. New Window is handled by Rust.

## Android

Install JDK 17, Android SDK API 36, build tools 36, and NDK 28.2.13676358. Set `JAVA_HOME`, `ANDROID_HOME`, and `NDK_HOME`. Install Rust targets:

```sh
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android
node scripts/platform-build.mjs android --debug --apk --target aarch64 x86_64
```

The platform script initializes missing native projects. Committed Android project settings use API 36. Debug APKs are signed with the machine's development key and can be installed using `adb install -r path/to/app.apk`. Release APK/AAB signing requires the product's private keystore. Do not commit keystores or passwords. Native projects ignore `key.properties`, `keystore.properties`, local SDK paths and generated binaries. See [Android signing](https://v2.tauri.app/distribute/sign/android/).

APK/AAB outputs are under `src-tauri/gen/android/app/build/outputs/`. Use NDK 28+ for 16 KB native library page alignment. The platform script prefers Rust's rustup toolchain so mobile standard libraries are found even when Homebrew Rust is also installed.

## iOS and iPadOS

A Mac with Xcode, CocoaPods and XcodeGen is required. Install the Rust targets:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
node scripts/platform-build.mjs ios --target aarch64-sim --no-sign --ci
node scripts/platform-build.mjs ios --target aarch64 --no-sign --archive-only --ci
```

An unsigned archive proves compilation but cannot be installed on an iPhone. For devices or App Store/TestFlight distribution, set `APPLE_DEVELOPMENT_TEAM` to the authorized team, open `src-tauri/gen/apple` in Xcode, and configure the app's signing/provisioning. Then build with the appropriate `--export-method` (`debugging`, `release-testing`, or `app-store-connect`). Signing credentials remain outside the repository. See [iOS signing](https://v2.tauri.app/distribute/sign/ios/).

## Continuous integration

`.github/workflows/build.yml` runs web tests and packages macOS, Windows, Linux, Android and iOS on their respective GitHub runners. Artifacts are private while the repository is private. macOS CI packages a universal binary for Apple Silicon and Intel. CI creates development Android APKs and unsigned release packages/Apple archives without requiring distribution credentials. Store publication, Windows signing, macOS notarization and iOS provisioning are separate release operations. macOS distributions should be signed and notarized before public download; see [macOS signing](https://v2.tauri.app/distribute/sign/macos/).

## Verification record

- Desktop Rust native shell: `cargo check` passed on Apple Silicon macOS.
- Intel macOS native shell: `cargo check --target x86_64-apple-darwin` passed.
- Android native shell: `cargo check --target aarch64-linux-android` passed.
- iOS native shell: `cargo check --target aarch64-apple-ios` passed. Optional desktop logging is excluded on mobile to avoid an upstream local-time dependency incompatibility on iOS.
- Cross-platform build and runtime results are recorded in the project validation report and CI logs. A configured packaging job alone is not evidence of a successful build or a device runtime test.


### Historical 0.1.0 native runtime checks (16 October 2026)

The production macOS app imported the sample STEP assembly locally in 2.76 seconds in the final signed build. Native Open and Save dialogs worked; a viewport PNG was exported. The native Settings shortcut (Command-comma) opened the settings panel. The universal build includes Apple Silicon and Intel binaries. This local runtime test used Apple Silicon.

The iPhone 17 Pro simulator on iOS 26.5 rendered the demo model and measured two selected points (62.048 mm in the final build), with markers and the mobile measurement panel visible. A native Files Save dialog exported a nonempty PNG to the app Documents folder. The sample STEP also opened successfully through Files and rendered all instances. Documents are exposed in Files for opening local models. Simulator behavior does not establish performance on a physical iPhone or iPad.

The Android API 35 ARM64 emulator installed and launched the APK, rendered the WebGL welcome screen, and had no AndroidRuntime crash in the launch log. Android touch gestures have not been exercised. The native activity applies status/navigation-bar and display-cutout insets and uses light system-bar icons on the dark application background.

Evidence images are in the local `artifacts/` directory. CI has also successfully built Linux packages and the iOS simulator/device archives. CI build success is distinct from interactive testing on those operating systems.

A local device IPA was successfully exported with the authorized Apple Development identity and a team provisioning profile covering 19 registered devices, expiring 15 October 2027. Its code signature passed strict verification. This development IPA can be installed on devices covered by that profile; it is not an App Store distribution. No physical iOS device was used for runtime testing. Credentials and profiles are not in the repository.

The optimized local Android ARM64 APK is development-signed for direct installation (approximately 18 MB); the unsigned release APK and AAB are also retained. This signing key is for development, not a production Play release.

CI includes Linux and Windows startup smoke tests that check whether the packaged executable remains alive for 15 seconds (Linux under Xvfb). These checks do not establish that rendering, file dialogs, or interaction work on those systems. The web CI job also runs the real CAD-kernel measurement fixtures with `npm run test:cad`.


### Historical 0.1.0 local deliverables

The final native packages use `index-BsJDuriz.js` and `index-B8pKqrJx.css`, from the frozen production assets with `dist/index.html` SHA-256 `711dcf41688d1d9b18a7bec00657378539ddc717158caa0dbbf8545685f7824c`. The embedded JavaScript filename was checked in both macOS architectures, Android APK/AAB, iOS simulator binary, and the exported device IPA.

Packages are copied into `artifacts/releases/`:

| File | Status |
| --- | --- |
| `shenzhen-3d-0.1.0-macos-universal.dmg` | Developer ID signed, Apple Silicon + Intel; strict code-signature verification passed for app and DMG. Not notarized. The signed app launched and imported the sample STEP. |
| `shenzhen-3d-0.1.0-android-arm64-development.apk` | Optimized ARM64 release with development signature; APK v2/v3 verification passed; installed and launched on emulator. |
| `shenzhen-3d-0.1.0-android-arm64-unsigned.aab` | ARM64 Play bundle; requires production signing/release setup. |
| `shenzhen-3d-0.1.0-ios-registered-devices.ipa` | Signed development IPA for the team's registered devices; archive strict signature verification passed. |
| `shenzhen-3d-0.1.0-ios-arm64-simulator.tar.gz` | ARM64 simulator app, preserving executable modes; installed and tested on iOS 26.5. |

Final iOS checks confirmed safe header/toolbar/footer layout, point selections without activating the panel beneath the tap, and the sample STEP opening through Files. `artifacts/native-ios-measurement.png` and `artifacts/native-ios-step.png` record those final checks. `artifacts/native-android-launch.png` records the final Android startup layout. Android touch interaction and physical iOS-device runtime behavior remain unverified.


### Performance preview 0.1.1

Both private repositories publish `preview-0.1.1` with 16 SHA-256-verified assets, adding an Apple Silicon Chromium Performance DMG to the lightweight native packages. The source checkpoint is `3d33afb`; the release manifest records independent build inputs. The frozen web/frontend entry hash is `d11268b9fdc47eb5ed1768abcf7144a8cb7e1008f0e6d8b530f80a22112b8772`.

All nine platform jobs passed in both repositories at `0e030c1`; the web job now also checks GPU shader parity and desktop protocol isolation. Locally, 81 unit tests, 12 CAD checks and 10 browser workflows passed, with two deliberate viewport skips.

The signed lightweight Mac 0.1.1 app imported the sample STEP in 2.54 seconds and saved a PNG. The signed Chromium Mac package passed 11 runtime checks, including STEP/WASM, native Open, delayed PNG and CSV downloads, sandbox isolation and no native service worker. Its actual renderer sustained approximately 120 fps in the specified large-model stress cases; see [the hardware report](PERFORMANCE.md). Mac packages are not notarized.

The development-signed Android ARM64 0.1.1 APK installed and launched on an API 35 emulator; welcome/grid rendering, crash-log checks and 16 KB ZIP/ELF alignment passed. The iOS simulator and registered-device packages were rebuilt and their versions inspected; the IPA passed strict development-signature verification. Interactive iOS testing remains the earlier 0.1.0 evidence. No physical mobile device was tested. Windows/Linux startup checks passed in CI; full interactive native coverage remains outstanding.


### Review and rendering preview 0.1.2

Source `44761a8` passed all nine platform CI jobs. The release adds portable commented projects, new render styles/lights and optional progressive WebGPU tracing. The frozen frontend has 79 files, `index.html` SHA-256 `5b2e883a9034762dff05e565a6176259cf1540892adc14636d0b98cf4f718350` and `assets/index-dpyKHpus.js`. CI web assets match byte for byte. Every Windows/Linux binary contains all 79 asset keys, including the tracing worker; versions and startup smoke tests passed.

Local verification passed 115 unit tests, 12 CAD checks and 18 production desktop/mobile browser workflows, with two expected viewport skips. Genuine GPU tracing and display/export pixel parity passed on hardware. The signed Chromium Mac app passed 19 packaged checks, including native `.sz3d` save/open, CAD-face note/exact measurement restoration, tracing and PNG export. All 79 ASAR frontend assets match the freeze. Mac packages remain signed but not notarized.

The signed lightweight Mac app imported the STEP assembly in 3.02 seconds, rendered hidden lines, saved PNG and saved/reopened a portable project. Its native smoke did not add annotations; the full commented-project workflow was tested in Electron and both browser viewports. Rendering settings stayed unchanged in that same session; `.sz3d` does not persist render/light settings.

The Android ARM64 API 35 emulator installed and launched 0.1.2, rendered welcome/grid and showed no AndroidRuntime crash. ZIP and native ELF 16 KB alignment checks passed. Android native touch/STEP/review workflows remain untested.

The iOS 26.5 simulator installed/launched 0.1.2, rendered the four-part demo and accepted a note's model point and text. Native Files export produced an integrity-checked demo `.sz3d` archive without saved notes. End-to-end annotation saving and native touch scrolling remain unverified: the automation could not reveal the Save button below the panel fold with its simulator gestures. This is not established as a product scrolling failure. A separate real touch-event sequence in mobile Chromium scrolled the review panel and exposed Save successfully. The earlier 0.1.0 simulator STEP/measurement evidence remains historical.

The 0.1.2 device IPA passed strict development-signature verification for the team's 19 registered devices; the profile expires 15 October 2027. The simulator archive preserves executable modes. No physical iOS/Android device or Intel Mac runtime was tested. Full Windows/Linux interaction coverage remains outstanding. Per-package evidence and hashes accompany the private release in `build-manifest.json`.
