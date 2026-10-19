# Shenzhen Files repository rules

## Updater is critical code

The updater is a release-critical subsystem. These rules apply to
`nautilus-macos-updater.m`, the `--post-update` dispatch in `nautilus-main.c`,
the launcher, bundle/version metadata, signing and notarization, DMG assembly,
and the release scripts.

No updater-affecting change may be tagged, uploaded, or published until all of
the following gates pass with the exact signed and notarized release payload:

1. Perform a real update from the previously published app to the candidate.
   Exercise download, digest/signature/notarization verification, DMG mount and
   extraction, persistent staging, helper readiness, parent exit, atomic swap,
   exact-path relaunch, version handshake, and old-bundle cleanup.
2. Exercise the candidate's own updater against a disposable installed copy so
   the helper shipped in this release is proven able to install the next one.
   Run `package/test-updater-helper-e2e.sh` against the final signed candidate;
   this automated gate is mandatory, but it does not replace gate 1. The
   disposable source and staged destination must have different release tags
   and bundle versions. A same-version replacement is not an updater test.
3. Spawn the helper through the same Foundation `NSTask` path used in
   production and observe its readiness marker. Invoking `--post-update`
   directly from a shell is useful supplemental coverage but does **not** count
   as the helper-launch test.
4. Verify that the final executable, `SZFReleaseTag`, `CFBundleVersion`, and
   `AppIcon.icns` match the staged payload after relaunch.
5. Record the exact commands and results in the release notes. “Static
   verification,” a build-only check, or a direct-helper-only test must never
   be reported as end-to-end updater validation.
6. Validate network delivery twice for updater changes: before replacing the
   production asset, exercise the full installed path with the exact notarized
   candidate served by GitHub HTTPS from a disposable validation feed; after
   replacing the asset, repeat from an older installed build through the actual
   `releases/latest` API and production asset URL. Remove every disposable
   validation asset afterward. A production-path failure requires immediate
   rollback of the public asset and blocks completion of the release.

Any failure in the candidate blocks the release. Do not bypass, weaken, or
relabel these gates. The sole exception is a bootstrap release needed because
the already-published helper itself is proven unable to install any successor;
new payload code cannot repair code that exits before replacement. Before such
a bootstrap release, reproduce and record the old helper failure, pass a manual
replacement test using the final notarized DMG, pass every candidate-side gate,
state prominently that affected versions require one manual replacement, and
obtain the user's explicit authorization to publish despite the broken
old-version automatic path. Never claim that automatic updating works from an
affected version.

Every release must update the root README, `docs/STATUS.md`, and its release
notes in the same clean tagged commit state as the code. Public releases must
be normal releases, not drafts or prereleases, unless the user explicitly asks
otherwise.
