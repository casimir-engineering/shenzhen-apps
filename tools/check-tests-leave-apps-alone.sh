#!/usr/bin/env bash
# check-tests-leave-apps-alone.sh: no test drives apps it did not start.
#
#   tools/check-tests-leave-apps-alone.sh [--root DIR]
#
# Tests and release runs share the Mac with the person using it: their installed ShenzhenPDF, Shenzhen Files and
# Shenzhen 3D, their Friends helper, Finder. A test acts only on the copies it made, by exact path or by the PID it
# started. So test sources (a tests/, e2e/ or updater-e2e/ folder, or a file named *test* or *e2e*) never use what
# reaches other people's processes: osascript or `tell application`, killall, pkill, lsappinfo, `open -a`/`-b`, or
# NSRunningApplication lookups by bundle identifier; and their scripts never name /Applications.
#
# A file that must mention one of these, to refuse or forbid it, is listed in ALLOWED below with the reason. An entry
# whose file no longer matches is an error too, so the list only holds what is needed. Exit 0 when clean, 1 with the
# offending lines otherwise. tools/release.sh runs it in preflight; tools/release/test_release.py tests it.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
if (($# == 2)) && [[ "$1" == "--root" ]]; then
  root="$2"
elif (($# != 0)); then
  echo "usage: $0 [--root DIR]" >&2
  exit 2
fi

# path<TAB>why it may match
ALLOWED="$(printf '%s\t%s\n' \
  "apps/3d/electron/test-identity.test.cjs" "asserts the updater tests contain no pkill/killall, and that sweep.py refuses /Applications" \
  "apps/files/package/updater-helper-process-test.swift" "looks up Shenzhen Files only to refuse to run while one is open, and quits only the copy at its exact target path" \
  "tools/updater-e2e/sweep.py" "refuses to sweep under /Applications" \
  "tools/updater-e2e/szut.m" "interposes the bundle-identifier lookup so the app under test cannot reach other copies")"

APP_CONTROL='osascript|tell application|\bkillall\b|\bpkill\b|\blsappinfo\b|\bopen[[:space:]]+-[A-Za-z]*[ab]\b|runningApplicationsWithBundleIdentifier|runningApplications\(withBundleIdentifier'
INSTALLED='(^|[^~A-Za-z0-9_.])/Applications\b'

test_files() {
  git -C "$root" ls-files --cached --others --exclude-standard -z |
    tr '\0' '\n' |
    grep -vE '^apps/pdf/ext/|(^|/)node_modules/|^apps/files/nautilus/|(^|/)vendor/|^tools/check-tests-leave-apps-alone\.sh$' |
    grep -E '(^|/)(tests?|e2e|ui-e2e|updater-e2e)/|[Tt]est|[Ee]2[Ee]' |
    grep -vE '\.(png|jpe?g|gif|pdf|json|bin|md|txt|svg|ttf|otf|ico|icns|gz|zip|stl|step|3mf|glb|obj|wasm|sqlite|plist)$' || true
}

allowed() { printf '%s\n' "$ALLOWED" | cut -f1 | grep -qxF "$1"; }

bad=0
matched=""
while IFS= read -r file; do
  [[ -f "$root/$file" ]] || continue
  hits="$(grep -nE "$APP_CONTROL" "$root/$file" 2>/dev/null || true)"
  if [[ "$file" =~ \.(sh|bash|py|mjs|cjs|js|ts|rb|pl)$ ]]; then
    more="$(grep -nE "$INSTALLED" "$root/$file" 2>/dev/null || true)"
    hits="$(printf '%s\n%s' "$hits" "$more" | sed '/^$/d')"
  fi
  [[ -n "$hits" ]] || continue
  matched+="$file"$'\n'
  allowed "$file" && continue
  bad=1
  while IFS= read -r line; do echo "$file:$line"; done <<<"$hits"
done < <(test_files)

while IFS=$'\t' read -r file why; do
  [[ -n "$file" ]] || continue
  if ! printf '%s' "$matched" | grep -qxF "$file"; then
    echo "$file: listed in ALLOWED ($why) but no longer matches; remove the entry"
    bad=1
  fi
done <<<"$ALLOWED"

if ((bad)); then
  echo "Tests must act only on what they started (exact path or PID): no osascript, killall, pkill, lsappinfo," \
    "open -a/-b, bundle-identifier lookups or /Applications. See $0." >&2
  exit 1
fi
echo "Tests leave other apps alone: $(test_files | wc -l | tr -d ' ') test files checked."
