# Collection bundle optimization — 24 September 2026

The nested Collection app previously copied the complete reader executable, including MuPDF, reader views, updater and agent server. Collection uses PDFKit for PDFs and the existing Markdown renderer, so that duplicate was unnecessary.

`mac/companion/main.mm` now enters only the private pipe-driven Collection lifecycle. `mac/companion/sources.mk` lists the exact shared source components. The in-memory credential implementation was extracted unchanged from `SPDFMacPassword.mm`; the reader retains its Keychain backend and sends credentials to Collection only on demand. No new launch work, daemon, runtime dependency, storage format or setting was added. Compiler optimization remains `-O2`, with existing dead stripping; size was reduced by removing unused components rather than weakening speed optimization.

An unreferenced duplicate `ShenzhenPDF.icns` was also removed. Both bundles retain the `AppIcon.icns` referenced by their property lists; the reader retains its asset catalogue.

## Verified local artifact sizes

Regular-file byte totals, including ad-hoc signatures, before and after this pass:

| Component | Before (bytes) | After (bytes) |
|---|---:|---:|
| Complete app bundle | 90,852,344 | 48,154,193 |
| Reader executable | 42,759,680 | 42,776,272 |
| Collection helper executable | 42,759,696 | 1,441,744 |

Complete bundle: **86.64 → 45.92 MiB, 47.00% smaller**. Main executable size changes slightly because this pass also fixes short History layout and deferred loading. The helper is approximately 96.6% smaller. These are installed bundle sizes, not compressed download sizes; no whole-app startup timing claim is made.

## Regression checks

The new `mac-collection-companion-link-tests` target links the exact helper source set with `-O2` and the production dead-stripping flags. It confirms that reader, parent-host and persistent Keychain classes are absent while the renderer and companion runtime remain present. Generated fixtures verify real Markdown thumbnails and password-protected PDF thumbnails, including an actual credential request/reply over private anonymous pipes. Archived PDF bytes remain encrypted, and runtime construction touches no Collection storage. Hidden native Documents and Settings panes also construct successfully.

Password-store, password source contracts, fake-Keychain credential tests and real password-open integration pass after extraction. The full native candidate builds successfully. Both nested and outer signatures pass strict verification; both executables are arm64, target macOS 12.0, and depend only on system libraries/frameworks. Bundle identifiers and versions match their expected parent/helper relationship.

The exact candidate was staged into `dist/ShenzhenPDF.app`. Both installed executable SHA-256 hashes match the verified candidate. The preceding bundle is preserved under `portable/build/dist-before-optimization-idfwwg37`. No graphical application was launched, quit or screenshotted.

## Reproduce the focused checks

```sh
make -C portable mac-collection-companion-link-tests
make -C portable mac-password-tests mac-collection-credentials-tests mac-collection-password-open-tests
make -C portable DIST=build/optimization-final mac-app
codesign --verify --deep --strict portable/build/optimization-final/ShenzhenPDF.app
```

The separate build directory avoids replacing a running app during compilation. Public Developer ID signing/notarization remains the existing release pipeline's responsibility; this pass updates the local development bundle only.
