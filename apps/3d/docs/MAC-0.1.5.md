# Mac 0.1.5 delivery

The Apple Silicon package is built from clean source `612e5bce12972b70f6e9cfcc3f73b5cb1b5de95c` and requires macOS 13 or later.

## Changes

- Removed promotional headings, taglines, reassurance badges and redundant instructions throughout the welcome screen, panels, Help, Settings and Updates.
- The empty workspace contains file actions, a drop target and recent files. Model tools appear after a document opens.
- Controls and statuses use descriptive labels: Sample model, Settings, Dark, Light, No notes and Clear measurement.
- The Retina installer retains native draggable icons and the Applications shortcut, with one instruction: Drag into Applications.

Measurement, rendering, annotation and updater behavior remain unchanged. The copy rule is recorded in `.interface-design/system.md`.

## Validation

Source validation passed 135 frontend unit tests, 30 Electron unit tests and 28 desktop/mobile browser workflows, with two expected viewport-specific skips. Native Electron Updates UI and mobile touch scrolling passed separately. Desktop and mobile welcome/Settings layouts and desktop Help were visually inspected. Browser regression includes the sample STEP, CAD measurements, portable projects, offline reopening, import failures/retry and recent files.

The signed production app passed all 20 packaged checks, including native STEP import, worker/WASM loading, portable project reopening, CAD annotations, saved measurements, PNG/CSV exports and WebGPU tracing/export. It contains 84 verified frontend files and 16 updater dependencies. The welcome screen created no renderer canvas; this single packaged run reached Open in 2.63 seconds including process startup, with DOM content loaded in 81.4 ms. No new huge-model performance claim is made for this copy-only release.

The signed DMG checksum and deep app signature passed. The actual first-open Finder layout was visually checked, including the Applications shortcut and 760×500 / 1520×1000 background representations.

Apple notarization is blocked by four aborted multipart uploads with connection resets across both upload endpoints, including a retry after a five-minute cooldown. This is an upload failure, not an Apple notarization rejection. The signed build is **not notarized**. Both 0.1.5 GitHub releases remain unpublished drafts; 0.1.4 remains unchanged. The 10-minute recovery automation stays active.

Local signed checkpoint: `artifacts/releases-0.1.5-signed-checkpoint/Shenzhen 3D.app`. Installer: `~/Downloads/Shenzhen-3D-0.1.5-Apple-Silicon-Signed.dmg`. DMG SHA-256: `46000a58407482d2f2c3e271d417aff841cb1372f7e58bb208a919cd4bd6c09c`. Final notarized artifacts and the real released 0.1.4-to-0.1.5 updater test remain pending.

This delivery refreshes the Apple Silicon Electron package. Shared browser UI uses the same source changes; mobile viewport tests do not establish new physical-device testing or refreshed Windows, Linux, Android or iOS packages.
