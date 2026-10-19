#!/usr/bin/env bash
#
# sign-and-notarize.sh — ONE command that takes the already-built binary all
# the way to a notarized, stapled, published release asset:
#
#   1. Probe (10-s timeout) that the Developer ID private key signs WITHOUT
#      a keychain prompt. If it prompts, ABORT with the one-time
#      `security set-key-partition-list` fix the user must run first.
#   2. Assemble dist/Shenzhen Files.app (make-app.sh) and sign every Mach-O
#      with the Developer ID identity, hardened runtime + secure timestamp
#      (bundle-dylibs.sh with MAC_SIGN_IDENTITY; no entitlements — Shenzhen
#      PDF's Developer ID build ships none either).
#   3. Exercise the signed candidate's updater helper through Foundation's
#      production Process/NSTask launch path, including readiness, swap,
#      exact-path relaunch, version, executable, and icon checks.
#   4. Build the styled DMG (make-dmg.sh), codesign the DMG.
#   5. notarytool submit --wait with the stored keychain profile, staple,
#      stapler validate.
#   6. Verify: codesign --deep --strict on the app, spctl on the DMG, and a
#      Gatekeeper simulation — copy the app out of the mounted DMG, attach a
#      quarantine xattr, and require `spctl -a` to accept it.
#   7. gh release upload --clobber, then re-check that the GitHub API's
#      sha256 digest matches the local DMG (the self-updater reads it) and
#      that /releases/latest/download/ resolves.
#   8. Install the signed app to /Applications (replaces the previous copy).
#
# Prereqs (one-time, already true on this machine unless noted):
#   * Developer ID Application cert in the login keychain.
#   * Key ACL must allow codesign without a prompt. If step 1 aborts, run:
#       security set-key-partition-list -S apple-tool:,apple:,codesign: \
#         -s -k "<your login keychain password>" ~/Library/Keychains/login.keychain-db
#     (your login keychain password = your macOS user password, typed once
#     in YOUR terminal; it whitelists Apple's signing tools on the key).
#   * notarytool keychain profile (default: shenzhenpdf-notary, shared with
#     Shenzhen PDF — same Apple ID / team).
#   * gh authenticated for casimir-engineering.
#
# Usage:  ./package/sign-and-notarize.sh [--skip-install] [--prepare-only]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

IDENTITY="${MAC_SIGN_IDENTITY:-Developer ID Application: INTUITION Robotique & Technologies (66LJ4BV7Q3)}"
PROFILE="${NOTARY_PROFILE:-shenzhenpdf-notary}"
REPO="casimir-engineering/shenzhen-files"
ASSET="ShenzhenFiles-mac-arm64.dmg"
APP="$repo_root/dist/Shenzhen Files.app"
DMG="$repo_root/dist/$ASSET"

log()  { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SKIP_INSTALL=0
PREPARE_ONLY=0

for option in "$@"; do
  case "$option" in
    --skip-install)
      SKIP_INSTALL=1
      ;;
    --prepare-only)
      PREPARE_ONLY=1
      SKIP_INSTALL=1
      ;;
    *)
      fail "Unknown option: $option"
      ;;
  esac
done

# ---------------------------------------------------------------------------
# 0. Environment checks (all read-only / prompt-free)
# ---------------------------------------------------------------------------
security find-identity -v -p codesigning | grep -qF "$IDENTITY" \
  || fail "Signing identity not in keychain: $IDENTITY"
log "Identity present: $IDENTITY"

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated."
log "gh authenticated."

[[ -z "$(git status --porcelain=v1)" ]] \
  || fail "Release worktree is not clean. Commit the code, generated assets, and documentation before releasing."
log "Release worktree is clean."

# ---------------------------------------------------------------------------
# 1. Prompt-free probe: one codesign against a throwaway binary, 10-s cap.
#    A broken key ACL turns EVERY codesign into a GUI password prompt; this
#    bundle has ~80 Mach-Os, so we refuse to start until one probe is silent.
# ---------------------------------------------------------------------------
log "Probing that the Developer ID key signs without a keychain prompt…"
probe_bin="$(mktemp /tmp/szf-signprobe.XXXXXX)"
printf 'int main(void){return 0;}\n' > "$probe_bin.c"
cc -o "$probe_bin" "$probe_bin.c"
probe_result="$(python3 - "$probe_bin" "$IDENTITY" <<'PYEOF'
import subprocess, sys
try:
    p = subprocess.run(
        ["codesign", "--force", "--timestamp", "--options", "runtime",
         "--sign", sys.argv[2], sys.argv[1]],
        capture_output=True, text=True, timeout=10)
    print("OK" if p.returncode == 0 else f"FAIL {p.stderr.strip()}")
except subprocess.TimeoutExpired:
    subprocess.run(["pkill", "-x", "codesign"], capture_output=True)
    print("PROMPT")
PYEOF
)"
rm -f "$probe_bin" "$probe_bin.c"
case "$probe_result" in
  OK) log "Key signs silently — proceeding." ;;
  PROMPT)
    cat >&2 <<'EOF'
ERROR: codesign blocked on a keychain prompt (killed after 10 s).
The Developer ID private key's ACL does not whitelist Apple's signing tools,
so every codesign call raises a GUI password prompt (and plain "Allow" /
typing the password only authorizes ONE use). Fix it ONCE by running, in
your own terminal:

  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "<your login keychain password>" ~/Library/Keychains/login.keychain-db

(<your login keychain password> is your macOS login password. The command
rewrites the key's partition list so codesign/notarytool never prompt again.)
Then re-run this script.
EOF
    exit 1 ;;
  *) fail "codesign probe failed: $probe_result" ;;
esac

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "Notary profile '$PROFILE' did not work (xcrun notarytool history failed)."
log "Notary profile '$PROFILE' works."

# ---------------------------------------------------------------------------
# 2. Assemble + sign the bundle (hardened runtime + timestamp, every Mach-O)
# ---------------------------------------------------------------------------
log "Assembling the bundle…"
./package/make-app.sh
log "Signing the bundle with Developer ID (hardened runtime)…"
MAC_SIGN_IDENTITY="$IDENTITY" ./package/bundle-dylibs.sh
codesign --verify --deep --strict "$APP"
log "Deep verification passed."

log "Testing the signed updater helper through Foundation's production launch path…"
./package/test-updater-helper-e2e.sh "$APP"
log "Signed candidate updater-helper test passed."

# Read the explicit GitHub/self-update identity. CFBundleVersion is a separate,
# globally increasing number used by macOS for bundle/cache ordering.
TAG="$(/usr/libexec/PlistBuddy -c 'Print :SZFReleaseTag' "$APP/Contents/Info.plist")"
readme_release_marker="Latest <b>$TAG</b>"
grep -qF "$readme_release_marker" "$repo_root/README.md" \
  || fail "README.md is stale: update its '$readme_release_marker' marker and document this release before publishing."
log "README release marker matches $TAG."
if [[ $PREPARE_ONLY -eq 0 ]]; then
  gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 \
    || fail "Release $TAG does not exist on $REPO — create it first (or fix the version)."
  log "Bundle is $TAG; matching release exists."
else
  log "Bundle is $TAG; prepare-only mode does not require a GitHub release yet."
fi

# ---------------------------------------------------------------------------
# 4. DMG: build, sign
# ---------------------------------------------------------------------------
log "Building the DMG…"
./package/make-dmg.sh "$APP" "$DMG"
log "Signing the DMG…"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# ---------------------------------------------------------------------------
# 5. Notarize + staple (submits to Apple and waits; typically a few minutes)
# ---------------------------------------------------------------------------
log "Submitting to Apple notary service (waits for the verdict)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
log "Stapling the ticket…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ---------------------------------------------------------------------------
# 6. Gatekeeper verification, including a quarantined-copy simulation
# ---------------------------------------------------------------------------
log "Verifying the DMG with spctl…"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | grep -q "accepted" \
  || fail "spctl rejected the DMG."

log "Simulating a browser download (quarantined app copy)…"
mount_out="$(hdiutil attach -nobrowse -readonly -noautoopen "$DMG")"
mount_point="$(echo "$mount_out" | grep -o '/Volumes/.*' | head -1)"
qtest_dir="$(mktemp -d /tmp/szf-gatekeeper.XXXXXX)"
cleanup_q() {
  hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  rm -rf "$qtest_dir"
}
trap cleanup_q EXIT
ditto "$mount_point/Shenzhen Files.app" "$qtest_dir/Shenzhen Files.app"
hdiutil detach "$mount_point" >/dev/null
mount_point=""
# Quarantine flag as a browser download would set it. 0081 = downloaded,
# user-approval required. (NOT 0087: bit 0x0004 means "created by an App
# Sandbox", which Gatekeeper hard-rejects regardless of notarization.)
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" \
  "$qtest_dir/Shenzhen Files.app"
verdict="$(spctl -a -vv "$qtest_dir/Shenzhen Files.app" 2>&1 || true)"
echo "$verdict"
echo "$verdict" | grep -q "accepted" \
  || fail "Gatekeeper simulation FAILED: quarantined copy was rejected."
echo "$verdict" | grep -q "Notarized Developer ID" \
  || fail "Gatekeeper simulation FAILED: source is not 'Notarized Developer ID'."
log "Quarantined copy accepted as Notarized Developer ID."

# Repeat the updater gate against the exact app copied from the notarized DMG.
# The earlier run is a fast pre-notarization failure check; this one proves the
# payload users actually download and extract.
log "Testing the updater helper from the notarized DMG payload…"
./package/test-updater-helper-e2e.sh "$qtest_dir/Shenzhen Files.app"
log "Notarized-payload updater-helper test passed."

# Launch smoke test: an accepted signature is NOT proof the app RUNS (the
# hardened runtime can still SIGABRT on a dlopen Library Validation rejection,
# which is exactly how the 26.7.19-1 tag-manager crash slipped through). Launch
# the quarantined copy's executable directly so LaunchServices cannot hand the
# request to an already-running installed copy with the same bundle id. The
# launcher execs the real binary in-place, so its PID remains authoritative.
log "Launch smoke test on the quarantined copy…"
crash_dir="$HOME/Library/Logs/DiagnosticReports"
before_crashes="$(find "$crash_dir" -maxdepth 1 -type f -name 'nautilus-*.ips' -print 2>/dev/null |
                  wc -l | tr -d ' ' || true)"
# Isolate from the dev D-Bus so this cannot join or touch the user's running
# instance. Keep stdout/stderr for a useful failure report.
smoke_log="$qtest_dir/launch-smoke.log"
DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/szf-smoke-nobus.sock" \
  "$qtest_dir/Shenzhen Files.app/Contents/MacOS/nautilus-launcher" \
  >"$smoke_log" 2>&1 &
smoke_pid=$!
sleep 8
smoke_alive=0
kill -0 "$smoke_pid" 2>/dev/null && smoke_alive=1
after_crashes="$(find "$crash_dir" -maxdepth 1 -type f -name 'nautilus-*.ips' -print 2>/dev/null |
                 wc -l | tr -d ' ' || true)"
# Tear down only the exact process started above; never touch an installed copy.
kill "$smoke_pid" 2>/dev/null || true
wait "$smoke_pid" 2>/dev/null || true
sleep 1
if [[ "$after_crashes" -gt "$before_crashes" ]]; then
  fail "Launch smoke test FAILED: a new crash report appeared (the quarantined app crashed on launch)."
fi
if [[ $smoke_alive -ne 1 ]]; then
  sed -n '1,120p' "$smoke_log" >&2
  fail "Launch smoke test FAILED: the quarantined app was not running after 8 s."
fi
log "Quarantined copy launched and stayed alive (no new crash) — killed."

if [[ $PREPARE_ONLY -eq 1 ]]; then
  local_sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  log "Prepare-only complete: notarized DMG is ready at $DMG"
  log "SHA-256: $local_sha"
  log "No GitHub asset was uploaded and /Applications was not modified."
  exit 0
fi

# ---------------------------------------------------------------------------
# 7. Publish: clobber the release asset, re-verify the updater metadata
# ---------------------------------------------------------------------------
log "Uploading the notarized DMG to release $TAG (replaces the old asset)…"
gh release upload "$TAG" "$DMG" --clobber -R "$REPO"

log "Re-checking the GitHub API digest against the local DMG…"
local_sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
for _attempt in 1 2 3 4 5; do
  api_sha="$(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((a.get('digest') or '' for a in d['assets'] if a['name']=='$ASSET'), ''))" \
    | sed 's/^sha256://')"
  [[ "$api_sha" == "$local_sha" ]] && break
  sleep 5
done
[[ "$api_sha" == "$local_sha" ]] \
  || fail "GitHub digest ($api_sha) does not match the local DMG ($local_sha)."
log "Digest matches: $local_sha"

curl -sI "https://github.com/$REPO/releases/latest/download/$ASSET" \
  | grep -qi "location: .*$TAG/$ASSET" \
  || fail "/releases/latest/download/ does not resolve to $TAG."
log "Download URL resolves to $TAG."

# ---------------------------------------------------------------------------
# 8. Install locally (optional)
# ---------------------------------------------------------------------------
if [[ $SKIP_INSTALL -eq 0 ]]; then
  log "Installing to /Applications…"
  rm -rf "/Applications/Shenzhen Files.app"
  ditto "$APP" "/Applications/Shenzhen Files.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "/Applications/Shenzhen Files.app"
  log "Installed. NOTE: the signing identity changed (ad-hoc → Developer ID),"
  log "so macOS treats it as a new app for TCC — re-grant Full Disk Access"
  log "(and Accessibility, if you use the save-panel handoff)."
fi

log "Done: https://github.com/$REPO/releases/tag/$TAG"
