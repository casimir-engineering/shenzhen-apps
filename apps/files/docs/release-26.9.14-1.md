# Shenzhen Files 26.9.14-1

- Fixes “The update installer exited before it was ready.” The helper now
  handles Foundation's production process-group launch semantics without
  weakening failures from any other `setsid()` condition.
- The amended asset also fixes final verification after a real version change.
  Update identity is read directly from the `Info.plist` currently on disk,
  avoiding `NSBundle`'s stale path cache after the atomic rename.
- Adds a mandatory signed-candidate updater test that exercises the actual
  Foundation `Process`/`NSTask` path, readiness handshake, move-aside swap,
  exact-path relaunch, release identity, executable, and application icon.
- The disposable source is stamped with a deliberately older tag and build;
  same-version swaps are rejected as invalid updater coverage.
- Runs that test both before notarization and against the quarantined app copied
  from the final notarized DMG.
- Makes full updater validation and README/status/release-note updates explicit
  repository release gates.
- Repackages the DMG background as a native multi-representation TIFF with
  exact 600×400 1x and 1200×800 2x artwork, so Finder uses a sharp Retina image
  instead of scaling the low-resolution representation.

## One-time bootstrap note

Published builds through `26.9.12-1` execute their already-installed helper
during replacement. That helper exits before it can install its successor, so
no downloaded payload can repair it. Install this DMG manually once by replacing
Shenzhen Files in Applications. Future automatic updates then run through the
fixed helper shipped here.

## Release validation record

The exact signed and notarized amended `26.9.14-1` payload passed before the
amendment was declared complete:

1. `ninja -C build` completed successfully, and
   `patches/macos-port-full.patch` applied cleanly to a fresh upstream archive;
   every replayed file matched the integrated tree byte for byte.
2. `package/test-updater-helper-e2e.sh "dist/Shenzhen Files.app"` passed on
   the Developer ID signed candidate: `READY_MARKER=observed`, `HELPER_EXIT=0`,
   `EXACT_RELAUNCH=observed`, tag `26.9.14-1`, and build `26091401`.
3. Apple notarization submission `51f1fc79-c55d-428c-9511-f3bb44bb1c16`
   was accepted. Stapling and validation passed, the quarantined app copied
   from the DMG was accepted as Notarized Developer ID, the same production-path
   updater test passed on that copy, and the eight-second launch smoke test
   stayed alive without a new crash report.
4. An installed Developer ID signed `26.8.27-2` fixture downloaded the exact
   notarized candidate from GitHub HTTPS, verified the advertised digest and
   notarization, mounted and extracted the DMG, moved it to persistent staging,
   observed helper readiness, exited, completed the move-aside swap, relaunched
   from `/Applications`, wrote `update_ok=26.9.14-1`, and removed both `.old`
   and staging. The resulting executable and icon hashes matched the DMG.
5. After replacing the public asset, that installed old-to-new test passed a
   second time through the actual GitHub `releases/latest` API and production
   `ShenzhenFiles-mac-arm64.dmg` URL. It finished at tag `26.9.14-1`, build
   `26091401`, with the exact candidate hashes and no old bundle or staging
   directory left behind.
6. The same Foundation-path test rejected the real installed `26.8.27-2`
   helper before readiness and logged `helper detach failed: Operation not
   permitted`, proving the regression test catches the published defect.
7. The mounted final DMG contains a two-representation background TIFF: 600×400
   at 72 dpi and 1200×800 at 144 dpi; Finder's `.DS_Store` selects that TIFF.

Final artifact identities:

- DMG SHA-256: `3fcd47f11498fa38ef77f52102bc8462a8b0c2189086bc567066b5acfe98d29a`
- `Contents/MacOS/nautilus` SHA-256: `2ef5b1d8c568b6c387198ba97146850868fc85a909e4eeb7b2227b39a7556659`
- `Contents/Resources/AppIcon.icns` SHA-256: `6197e99853013428c68195815f5939b22d11bec5e9496e5de86c963cea801739`

**Full Changelog:** https://github.com/casimir-engineering/shenzhen-files/compare/26.9.12-1...26.9.14-1
