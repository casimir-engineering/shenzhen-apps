# Mac notarization and updater tests

These developer tools use existing Keychain and GitHub CLI credentials. They never accept a token or password argument. The `.mjs` files are not included in the packaged main-process runtime.

## Notarize a frozen package

First create a clean signed package with `npm run package:electron:mac -- --release-owner=<github-owner>`. Keep that timestamped output immutable. Create a separate output folder whose name includes `-notarized-`, under `artifacts/electron/`.

```sh
signed_output="$PWD/artifacts/electron/<signed-build>"
notarized_output="$PWD/artifacts/electron/<version>-notarized-<timestamp>"
notary_profile="<existing-keychain-profile>"
mkdir "$notarized_output"

xcrun notarytool submit "$signed_output/Shenzhen-3D-<version>-Apple-Silicon.zip" \
  --keychain-profile "$notary_profile" --output-format json --no-wait \
  --no-s3-acceleration
```

Save the returned submission ID. Use `notarytool info <id>` with the same profile to check status at reasonable intervals. After a transport failure, reconcile submission history/status before retrying: a registered ID can exist even when multipart upload failed. Keep raw transport diagnostics and unrelated team history out of release assets.

Once the ZIP submission is **Accepted**:

```sh
node electron/notarize-finalize.mjs \
  --original="$signed_output" --output="$notarized_output" \
  --profile="$notary_profile" --phase=package \
  --zip-submission="<accepted-zip-id>"
```

The helper verifies Apple's archive SHA-256, copies the signed app, staples and validates its ticket, checks its signature/Gatekeeper result, and runs electron-builder with `--prepackaged` and `--publish never`. The app is not re-signed. The existing Retina DMG artwork/configuration is retained. `mac.notarize: false` remains appropriate here because submissions are performed explicitly.

The new ZIP can be independently checked and frozen before DMG processing:

```sh
node electron/notarize-finalize.mjs \
  --original="$signed_output" --output="$notarized_output" \
  --profile="$notary_profile" --phase=verify-zip
```

Submit the newly created DMG using `notarytool submit` and the same nonblocking options. After its submission is **Accepted**:

```sh
node electron/notarize-finalize.mjs \
  --original="$signed_output" --output="$notarized_output" \
  --profile="$notary_profile" --phase=finalize \
  --dmg-submission="<accepted-dmg-id>"
```

Finalization staples the DMG, verifies signatures, tickets, Gatekeeper and disk-image integrity, regenerates external blockmaps and `latest-mac.yml` from final bytes, and records final artifact hashes in `build-info.json`. It extracts the ZIP and mounts the DMG read-only to validate both embedded apps. Original frontend/runtime/source provenance is retained; original signed artifact hashes are checked again. Completed output is immutable.

Apple's notarization log identifies the submitted archive **before** stapling/repacking. Distribution hashes identify the final ZIP and stapled DMG. Those digests are intentionally recorded separately. Apple documents stapling the app and recreating its ZIP because ZIP archives cannot themselves receive a stapled ticket. See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Release throughput

Freeze the tested runtime once. Reuse its signed app for notarization and installer assembly; documentation or upload-tool changes do not require rebuilding that runtime. Record the runtime commit separately from later release-tool commits.

On a constrained uplink, serialize large Apple and GitHub uploads. Concurrent 140 MB transfers exhausted the 900-second Apple request deadline during 0.1.6 delivery. Small metadata uploads and local verification can proceed while one large transfer runs. The GitHub uploader allows 900 seconds per transfer and checks remote state before a retry, avoiding duplicate completed uploads.

Keep accepted submissions and verified archives as checkpoints. Resume from the next unfinished phase after a disconnect. Never regenerate a frozen updater ZIP after its hash has entered the release feed. Prepare release notes, source-isolation reports and installer screenshots while uploads run, then publish after final artifact verification.

For the frozen 0.1.6 ZIP, `scripts/prepare-release-zip-delta.mjs` accepts `--repo`, `--base`, `--target` and an existing isolated `--output` directory under `artifacts`. It checks final notarized provenance, creates a zstd patch against the released 0.1.4 ZIP, and verifies byte-for-byte reconstruction. The measured patch is 11.56 MB versus a 140.24 MB ZIP (92% less upload). DMG patches were nearly as large as the original and are not used.

When this repository's Actions are available, upload the generated patch to the held draft with the guarded upload tool, then pass `delta-inputs.json.workflowInputs` to the `assemble-release-zip-delta.yml` workflow. The workflow downloads its base and patch from this repository only, validates the frozen tag and notarized metadata, reconstructs and verifies the exact ZIP, uploads without replacing an existing different file, and removes only its verified patch. It does not publish the release. Thirteen tests cover the guards, reconstruction, cleanup, completed reruns and held-draft discovery. Direct upload remains the fallback when Actions cannot run. Actions could not start during this delivery because of the account spending restriction, so the final assets were delivered using the direct uploader.

## Isolated native update installation

For an upgrade from a released app that already includes the updater, copy that signed app into a new fixture directory. Keep the original untouched:

```sh
fixture_run="$PWD/artifacts/updater-e2e/<new-fixture-run>"
mkdir -p "$fixture_run/fixture/mac-arm64"
ditto "$PWD/artifacts/releases-0.1.4/Shenzhen 3D.app" \
  "$fixture_run/fixture/mac-arm64/Shenzhen 3D.app"
```

The install report reads the fixture's signed build provenance. A released-app copy is identified separately from a synthetic version override.

`electron/prepare-update-fixture.mjs` reproduces the verified 0.1.4 test fixture: it copies frozen 0.1.4 staging, overrides only the copied package/lock/provenance to 0.1.3, and produces a signed `--dir --publish never` app with the same bundle ID. It does not change source versions or the released app.

```sh
node electron/prepare-update-fixture.mjs \
  --staging="$signed_output/staging" \
  --reference-app="$notarized_output/mac-arm64/Shenzhen 3D.app" \
  --run-dir="$PWD/artifacts/updater-e2e/<new-fixture-run>"
```

After the target ZIP and final feed are published, run:

```sh
node electron/update-install-smoke.mjs \
  --fixture="$PWD/artifacts/updater-e2e/<fixture-run>/fixture/mac-arm64/Shenzhen 3D.app" \
  --reference-app="$notarized_output/mac-arm64/Shenzhen 3D.app" \
  --zip="$notarized_output/Shenzhen-3D-<version>-Apple-Silicon.zip" \
  --output="$PWD/artifacts/updater-e2e/<new-install-run>" \
  --owner="<github-owner>"
```

Set `--owner` to this repository’s owner and pass its frozen reference app and ZIP. Use a fresh isolated fixture/profile for each test. For 0.1.6, the reference app's signed `build-info.json.releaseOwner` must match. The installed app's updater state must still report the chosen owner after replacement and relaunch.

The script requires a real fixture path under `artifacts/updater-e2e/` with the expected bundle layout and a new output directory. It refuses an app in Applications, a released original, path escapes, other running Shenzhen 3D apps, and preexisting native updater cache/ShipIt state. It redirects the JavaScript cache into the test output and creates only temporary, owned native cache links. An explicit temporary profile prevents profile migration.

Checks cover packaged version/profile, existing CLI authorization encrypted in a mode-0600 settings file, the configured private feed, downloaded ZIP SHA-512, native Squirrel replacement, frozen target ASAR/signature/ticket/Gatekeeper, and new-version launch with the same temporary profile and expected update owner. Successful cleanup disconnects access, removes the isolated credential file and removes only test-owned native state. `result.json` records checks and cleanup status without credentials. If installation is still in progress after a failure, native state is retained for investigation rather than interrupted.

The test intercepts the app's confirmation response and disables `autoRunAppAfterInstall` only in the test process. Squirrel still downloads, verifies and replaces the signed bundle. The new version is launched manually with the explicit temporary profile, since Squirrel's [launch request](https://github.com/Squirrel/Squirrel.Mac/blob/main/Squirrel/SQRLShipItRequest.h) does not carry the original CLI arguments. This verifies replacement and launch; it does not verify automatic relaunch argument preservation or native dialog rendering.

## Recorded 0.1.4 result

On 16 October 2026, the private feed offered 0.1.4 to the signed synthetic 0.1.3 fixture. The release ZIP downloaded with the expected SHA-512; native Squirrel replaced the fixture, and the resulting signed/notarized 0.1.4 app launched with the same isolated profile. Its ASAR matched the frozen target. Credential/cache/job/preference cleanup was verified.

The fixture contains final updater code with an older package version. This is not evidence that the original 0.1.3 release, which lacked the updater, can self-update. The report is attached as `updater-install-report.json` to this repository’s `preview-0.1.4` release. Apple's accepted ZIP/DMG submissions and final artifact fingerprints are recorded separately in the release provenance.

## Recorded 0.1.6 result

On 16 October 2026, a copy of the actual signed, released 0.1.4 app upgraded through the published private feed to the final 0.1.6 distribution. Downloaded SHA-512, native Squirrel replacement, frozen target ASAR, signature, stapled ticket, Gatekeeper and isolated relaunch passed. The update source remained bound to the distribution’s repository. The owner-specific `updater-install-report.json` is attached to `preview-0.1.6`; the original 0.1.4 release and real Applications/profile directories were preserved.
