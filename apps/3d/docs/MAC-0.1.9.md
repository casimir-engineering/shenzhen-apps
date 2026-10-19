# Mac 0.1.9

## Trackpad rotation

Two-finger trackpad twist rolls the view around the current sight line in the Chromium macOS application. It preserves the current view center, camera position, zoom, model coordinates and measurements. Twist applies over the viewport, not over buttons or panels. View presets reset the orientation.

The existing controls remain: left and middle drag pan; right drag orbits around the current view center; two-finger trackpad swipe pans in all directions; pinch and mouse wheel zoom. Android and iOS retain one-finger orbit and two-finger pan/pinch. In 2D drawings, orbit gestures pan.

Rotation uses AppKit events scoped to the application window. It does not require Accessibility permission or a global input monitor. Browsers and the lightweight native shell do not expose this native rotation bridge.

## Verification

Frozen runtime source: `4f7dbf54ae08bb9c0b29d08e41a4808871292303`.

The source passed 161 frontend tests, 61 Electron tests, 38 GPU-backed rotation assertions and 1,262 navigation assertions. Production browser tests passed 33 cases, with three expected viewport-specific skips. Rotation tests cover direction, inverse and combined events, unchanged camera position/target/distance/zoom and model geometry, subsequent pan/orbit, preset reset, UI boundaries, active drags and disposal.

Each signed Mac package passed 20 runtime checks, nine native file-opening checks and seven limited native addon/IPC checks. Integrity checks covered 101 frontend files, 16 runtime dependencies, the native addon, 21 file associations, source provenance, signatures and its fixed updater source.

The native fixture verifies event validation, bounded queue consumption, window/timestamp isolation and subscription lifecycle. Physical two-finger twist and phased trackpad event delivery have not been verified. The automated discrete-wheel result from 0.1.8 is not reused as proof for the changed 0.1.9 native binary.

## Delivery

The Apple Silicon app and Retina DMG are Developer ID signed, Apple notarized and stapled. Final checks verified Gatekeeper, tickets, archive hashes and the normal Finder auto-open layout with an Applications shortcut and 1×/2× artwork. Each distribution keeps its own fixed updater repository. Release evidence records final artifact hashes and native verification scope.

The user's running application and real profiles are preserved. No new native updater replacement test has been performed for this version.
