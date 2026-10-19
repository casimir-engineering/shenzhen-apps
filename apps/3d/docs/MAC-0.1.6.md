# Mac 0.1.6 delivery

## Navigation correction

Middle-button dragging pans in screen X/Y, matching two-finger trackpad panning. It no longer follows left-button orbit. This applies when opening a model and when changing between perspective and orthographic projection. Left drag still orbits 3D models; left drag pans 2D drawings. Help and mouse navigation labels describe the corrected controls.

Wheel and pinch zoom sensitivity increased from 1.1 to 1.3 (about 18%). Trackpad swipes continue to pan; zoom buttons retain their existing step.

The 0.1.5 copy cleanup is retained. The signed 0.1.5 checkpoint remains available for comparison; its unpublished release drafts are superseded by 0.1.6.

## Validation and delivery

The production frontend build, 135 unit tests and 46 actual Apple M5 Max Metal navigation/measurement checks pass. The hardware checks verify 2D/3D and perspective/orthographic pan invariants, equivalence with actual trackpad wheel deltas, unchanged left-drag behavior, no accidental selection after a drag, and an 18.18% increase in logarithmic wheel/pinch zoom response. Measurement overlay/export checks also pass.

The signed package identifies its fixed update repository; the Updates panel displays that source read-only. All 46 Electron unit tests pass, covering source binding, credential migration and feed validation.

Each final signed package passed 20 runtime checks on Apple M5 Max Metal, including its configured source and rejection of switching to a different source. All 361 ASAR files passed the repository-isolation scan; 99 frontend hashes and 16 updater dependencies were verified. The upload helper passed 22 guard tests, including rejection of cross-repository artifacts.

The app and Retina DMG are signed with Developer ID, accepted by Apple notarization, and stapled. Final ZIP and DMG embedded tickets, code signatures, Gatekeeper acceptance, artifact hashes, and actual Finder drag-to-Applications layout pass. The `preview-0.1.6` release is published with the DMG, updater ZIP and verification records. The real released 0.1.4 app upgraded to 0.1.6 in an isolated fixture: the downloaded ZIP matched SHA-512, native Squirrel replaced the fixture, and the resulting app passed signature, ticket, Gatekeeper and frozen-ASAR checks. Relaunch retained the same temporary profile and the distribution’s fixed update source. Published 0.1.4 remains unchanged.

Runtime source: `5a657b3647ebfeccba512a9e2cf2da7990e6435a`. Later release-tool and documentation commits do not change these frozen binaries.
