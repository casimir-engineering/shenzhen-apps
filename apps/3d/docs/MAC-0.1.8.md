# Mac 0.1.8

## Controls

The viewport uses one automatic control scheme:

| Input                                      | Action                                             |
| ------------------------------------------ | -------------------------------------------------- |
| Left-button drag                           | Pan                                                |
| Middle-button drag                         | Pan                                                |
| Right-button drag                          | Orbit around the current view center               |
| Two-finger trackpad swipe in any direction | Pan                                                |
| Trackpad pinch or mouse wheel              | Zoom                                               |
| Single click                               | Pick for the current measurement or selection tool |

Zoom stays centered in the view. After panning, right-drag orbits around the new view center. Old input-device, navigation-preset and reverse-wheel preferences no longer override these controls. Touchscreens retain one-finger orbit and two-finger pan/pinch; orbit gestures pan in 2D drawings. See [Controls](CONTROLS.md) for view shortcuts.

The macOS desktop app uses AppKit scroll-event phases to distinguish trackpad gestures from mouse wheels. Browser events omit that information, so the browser fallback can misclassify some smooth mouse wheels and vertical trackpad swipes. No manual device chooser is required.

## Verification

The source passed 159 frontend unit tests, 56 Electron unit tests, 12 exact CAD checks, and 33 production browser tests, with three expected viewport-specific skips. Fixed controls passed 1,262 assertions in headed Chromium on Apple M5 Max Metal.

Each signed package passed 20 runtime checks and nine native file-opening checks in isolated profiles. Verification covered the frozen source, frontend inventory, 16 production dependencies, one unpacked native addon, all 21 file associations, signatures and the fixed update repository.

Native checks cover addon loading/startup, production exports, ring classification, window/timestamp isolation, IPC bounds and matching packaged native code hashes. A separate app-bound automated wheel test received a trusted DOM event classified as `wheel` through the production AppKit monitor, preload and IPC. Its canonical native code hash matched the signed addon.

That result verifies the automated discrete-wheel path only. Phased trackpad gestures and physical-device delivery remain unverified. The limited native smoke uses an isolated Electron fixture with the production loader, preload and addon; it does not claim an end-to-end packaged-main input test. Its broader `nativeEventDeliveryVerified` flag remains false.

Frozen runtime source: `adb8df7971d1dad71a4c6524a9d830e28799afb6`. Later documentation changes do not alter the packaged application.

## Delivery

The Apple Silicon app and Retina DMG are Developer ID signed, Apple notarized and stapled. Gatekeeper, the apps embedded in the ZIP and DMG, and the installer's normal Finder auto-open layout passed verification. The installer includes an Applications shortcut and 1×/2× artwork.

Release assets are specific to this repository and its fixed updater source. Final hashes and verification evidence accompany the release in `build-info.json`, `notarization-verification.json`, `runtime-report.json` and `SHA256SUMS.txt`.

No new native update-install replacement test was performed for 0.1.8: the user's running app and real profiles were preserved. The packaged updater source, dependency inventory and final feed/archive hashes were checked; the earlier isolated installation test remains documented in [Updater testing](UPDATER_TESTING.md).
