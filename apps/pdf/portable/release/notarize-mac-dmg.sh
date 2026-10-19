#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <dmg> <notary-profile> <result-json>" >&2
  exit 2
fi

dmg="$1"
profile="$2"
result_json="$3"

mkdir -p "$(dirname "$result_json")"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json >"$result_json"
status="$(plutil -extract status raw -o - "$result_json")"
submission_id="$(plutil -extract id raw -o - "$result_json")"
[[ "$status" == "Accepted" ]] || {
  echo "Notarization did not succeed (status: $status, submission: $submission_id)." >&2
  cat "$result_json" >&2
  exit 1
}
echo "Notarization accepted: $submission_id"
