#!/usr/bin/env bash
# Release jobs only: puts the Developer ID certificate in a temporary keychain and stores a notarytool profile, from
# the job's secrets. Prints MAC_SIGN_IDENTITY and NOTARY_PROFILE lines for $GITHUB_ENV.
#
#   MAC_CERTIFICATE_P12 (base64) MAC_CERTIFICATE_PASSWORD NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID \
#     tools/ci/mac-signing.sh >> "$GITHUB_ENV"
set -euo pipefail

: "${RUNNER_TEMP:?runs in a GitHub Actions job only}"
for name in MAC_CERTIFICATE_P12 MAC_CERTIFICATE_PASSWORD NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID; do
  [ -n "${!name:-}" ] || { echo "error: the secret $name is not set" >&2; exit 1; }
done

keychain="$RUNNER_TEMP/release.keychain-db"
password=$(openssl rand -base64 24)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
printf '%s' "$MAC_CERTIFICATE_P12" | base64 --decode > "$RUNNER_TEMP/certificate.p12"
security import "$RUNNER_TEMP/certificate.p12" -k "$keychain" -P "$MAC_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
rm -f "$RUNNER_TEMP/certificate.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

identity=$(security find-identity -v -p codesigning "$keychain" | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' |
  head -n 1)
[ -n "$identity" ] || { echo "error: no Developer ID Application identity in the certificate" >&2; exit 1; }

printf '%s' "$NOTARY_KEY_P8" > "$RUNNER_TEMP/notary.p8"
xcrun notarytool store-credentials shenzhenpdf-notary --key "$RUNNER_TEMP/notary.p8" --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" --keychain "$keychain" >/dev/null
rm -f "$RUNNER_TEMP/notary.p8"

echo "MAC_SIGN_IDENTITY=$identity"
echo "NOTARY_PROFILE=shenzhenpdf-notary"
