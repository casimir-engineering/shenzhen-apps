#!/bin/bash
# keychain-signature-probe.sh [<signing identity>]: what the file-based keychain lets one Friends helper do with an
# identity item another helper made, for helpers signed differently. Evidence for SZFriendsKeychainKeyStore.m.
#
# Builds the probe twice (two builds: different code, so different cdhashes), signs copies ad hoc and, with an
# identity, as Developer ID with the helper's identifier com.intuition.shenzhenfriends (one build also as another
# identifier), then for each maker and each other copy: make the item, read it, delete it with SecItemDelete, and
# with SecKeychainItemDelete through its reference. Everything runs on a keychain file in a fresh temporary directory
# that is not on the search list and is deleted at the end; interaction is off, so nothing can prompt. Expected
# with a Developer ID identity (2026-10, macOS 26):
#   read:        allowed for the maker and any Developer ID copy with the same identifier and team, whatever its
#                build; refused (-25293) across ad hoc / Developer ID and across identifiers
#   item-delete: refused (-25244, errSecInvalidOwnerEdit) whenever the deleter is another build or another signing
#   ref-delete:  allowed in every case
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
identity="${1:-}"
work="$(mktemp -d "${TMPDIR:-/tmp}/szfriends-keychain-probe.XXXXXX")"
build() { clang -fobjc-arc -arch "$(uname -m)" "$@" "$here/keychain-signature-probe.m" -framework Foundation \
  -framework Security -o "$work/base$#"; }
build -DSZF_PROBE_BUILD=1
build -DSZF_PROBE_BUILD=2 -O1
copies=(adhoc)
cp "$work/base1" "$work/adhoc"
codesign -f -s - -i com.intuition.shenzhenfriends "$work/adhoc" 2>/dev/null
if [[ -n "$identity" ]]; then
  sign() { perl -e 'alarm 30; exec @ARGV' codesign -f -s "$identity" -i "$2" --options runtime --timestamp=none \
    "$work/$1" 2>/dev/null || { echo "codesign failed or waited on a prompt: $1" >&2; exit 1; }; }
  cp "$work/base1" "$work/devid"; sign devid com.intuition.shenzhenfriends
  cp "$work/base2" "$work/devid-rebuilt"; sign devid-rebuilt com.intuition.shenzhenfriends
  cp "$work/base1" "$work/devid-other-id"; sign devid-other-id com.intuition.other
  copies+=(devid devid-rebuilt devid-other-id)
fi
run() { perl -e 'alarm 15; exec @ARGV' "$work/$1" "$2" "$work/probe.keychain-db" | awk '{ print $2 }'; }
printf '%-15s %-15s %6s %12s %11s\n' maker other read item-delete ref-delete
for maker in "${copies[@]}"; do
  for other in "${copies[@]}"; do
    for op in read item-delete ref-delete; do
      run adhoc create >/dev/null
      run "$maker" add >/dev/null
      eval "r_${op//-/_}=\$(run \"\$other\" $op || true)"
      run adhoc destroy >/dev/null
    done
    printf '%-15s %-15s %6s %12s %11s\n' "$maker" "$other" "$r_read" "$r_item_delete" "$r_ref_delete"
  done
done
rm -f "$work"/base1 "$work"/base2 "$work"/adhoc "$work"/devid "$work"/devid-rebuilt "$work"/devid-other-id
rmdir "$work" 2>/dev/null || true
