# Mac 0.1.3 delivery

The Apple Silicon DMG packages source commit `75450a132e0d185a4f676673f560e1d817e4695c`, including lazy startup, portable commented projects, shaded and hidden-line modes, lighting controls and progressive GPU ray tracing. It requires macOS 13 or later.

Open `Shenzhen-3D-0.1.3-Apple-Silicon.dmg`, drag the app into Applications, then launch it from Applications. The installer has native draggable icons and a real `/Applications` shortcut. Its embedded TIFF contains both 760×500 at 72 dpi and 1520×1000 at 144 dpi representations. The normal first-open Finder window was visually checked on this Mac.

The app and disk image are Developer ID signed; the app passes strict deep signature verification with hardened runtime and a secure timestamp. **This build is not notarized:** no notarization credentials were configured. Downloaded copies can therefore encounter Gatekeeper restrictions.

## Verification on 16 October 2026

- Production build and three local asset protocol tests passed.
- All 83 files inside the app's bundled frontend match the clean source build manifest.
- Disk image checksum verification passed; the mounted Applications shortcut resolves correctly.
- All 20 checks against the packaged 0.1.3 executable passed: native STEP import, worker/WASM loading, PNG/CSV export, portable project save/reopen, CAD face annotation rebinding, exact saved measurements, lazy startup and WebGPU ray-tracing convergence/export.
- The welcome screen creates no renderer canvas. This packaged cold launch reached Open in 1.95 seconds, including process startup; its document loaded in 48 ms. These are a single release check, not a repeated startup benchmark.
- Metal-backed animation scheduling measured 119.996 fps on the Apple M5 Max. This is a scheduling check, not proof that every huge model renders at 120 fps. See PERFORMANCE.md and STARTUP.md for repeatable workload results.

The release folder contains the DMG, `.app`, SHA256SUMS.txt, build-info.json, app-verification.json, runtime-report.json and installer-preview.png. The DMG SHA-256 is `159dc90522e016c50ae27888ff7125a22e67e178db888e9f8005cd484ca278ea` (140,344,629 bytes).

This release refreshes the Apple Silicon Chromium app. Earlier platform packages remain separate; it does not establish new physical-device testing for Windows, Linux, Android or iOS.
