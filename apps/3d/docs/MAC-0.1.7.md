# Mac 0.1.7

## Changes

- Six CAD navigation presets with right-drag orbit/middle-drag pan by default. Mouse mode zooms for every wheel step; explicit Trackpad mode retains two-finger swipe panning and pinch zoom. View shortcuts, selection fit and planar-face normal commands are documented in [Controls](CONTROLS.md).
- Recent files reopen directly after restarting. The Electron app keeps authorized file paths and companion files; it reports moved/missing files instead of opening an unrelated chooser. Browser recent storage retains files within its 256 MiB budget. Old history containing only names cannot reconstruct file access.
- All 21 supported model/project extensions are declared to the OS with Viewer roles. Native file-open events reach the viewer at cold start and while running. Images, material libraries and binary sidecars are not registered as standalone model formats.
- Switching from a DXF back to perspective 3D preserves suitable camera clipping distances. This fixes depth artifacts on thin STEP geometry without altering model data.

## Validation

Source validation passed 157 frontend unit tests, 54 Electron unit tests, and Rust type checking. Desktop/mobile browser workflows passed, including direct recent reopening after reload, input settings persistence, keyboard guards, delayed-read cancellation and production offline STEP import. The final native UI check passed nine cold/warm open and restart scenarios in an isolated profile.

Actual Metal navigation passed 1,165 assertions on the Apple M5 Max, including six presets, mouse/trackpad wheel behavior, modifier priorities, touchscreen gestures, 2D/projection changes and dashed measurement overlays.

A sample STEP and a DXF passed three repeated import cycles with stable geometry counts and zero WebGL errors. Before the clipping fix, each return to 3D differed from the correct-depth reference by 1,444 model pixels. The fixed camera produces zero such differences. The full App also passed seven imports and three renderer close/recreation cycles.

Isolated native recent-file tests reopen files and OBJ/MTL companions across a complete Electron restart. Browser tests cover a 33 MiB file after reload, companion bytes, distinct same-name files, quota failures and missing data. File-association metadata is validated against installed schemas and generated macOS plist/Linux MIME output.

The signed Apple Silicon package passed 20 runtime checks and nine native file-opening scenarios in isolated profiles. Verification covered all 101 bundled frontend files, 16 production dependencies, the frozen source commit, all 21 file associations, and the app's fixed update repository.

## Delivery

The app and DMG are Developer ID signed and independently accepted by Apple notarization. Tickets are attached to both, including the app embedded in the updater ZIP and installer. Signature, Gatekeeper, archive-integrity and final artifact-hash checks passed. The final mounted DMG was inspected in Finder with its Applications shortcut and both Retina background representations.

The frozen runtime is `da40fdd61012f5f9f856b624601be4a02c2b0168`. Later documentation commits do not change the packaged application.

The published release contains ten assets: DMG, updater ZIP, their blockmaps, update feed, build provenance, notarization verification, packaged runtime report, checksums and release notes. Every uploaded asset's SHA-256 and size matched the final local file before and after publication. The packaged update source is fixed to the repository that supplied the installer.

The actual packaged update provider selected the published 0.1.7 release from its fixed repository. The selected ZIP was downloaded and matched its final SHA-256, SHA-512 and size. Its extracted app matched the frozen ASAR, version and source binding, and passed signature, stapled-ticket and Gatekeeper checks.

Native update installation was not rerun for this release: the existing user app was open, and the test refused to touch its shared native updater state. The running app and real user profile were left untouched. The update manager, provider and channel source are unchanged from 0.1.6.
