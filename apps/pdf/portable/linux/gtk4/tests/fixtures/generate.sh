#!/bin/sh
# Regenerates the minisign fixtures for updater_test.c. Run once inside the
# shenzhen-build container (minisign + openssl are installed there):
#
#   docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/work" \
#     -w /work/portable/linux/gtk4/tests/fixtures shenzhen-build sh generate.sh
#
# Committed outputs (the throwaway secret keys are deleted, never committed):
#   blob.bin                    payload the signatures cover
#   testkey.pub                 throwaway minisign public key
#   blob.bin.minisig            valid prehashed ("ED") signature, minisign -S
#   blob.bin.corrupt.minisig    same file with one base64 char flipped inside
#                               the signature bytes (parses, fails verify)
#   legacy.pub                  hand-assembled pubkey for the legacy mode
#   blob.bin.legacy.minisig     hand-assembled legacy ("Ed") signature over the
#                               raw blob, built with openssl (minisign >= 0.7
#                               can no longer produce legacy signatures)
set -eu

printf 'Shenzhen PDF updater test blob \xe2\x80\x94 fixed content, do not edit.\n' > blob.bin

# --- prehashed fixture via minisign ------------------------------------------
minisign -G -f -W -p testkey.pub -s testkey.sec
minisign -S -W -s testkey.sec -m blob.bin -t 'shenzhen updater fixture' \
    -c 'untrusted fixture comment'
rm -f testkey.sec

# Corrupt one base64 character inside the signature bytes (line 2, position
# 40 — safely past the 10-byte alg+keyid prefix so the keyid still matches and
# the failure exercises Ed25519 verification, not the keyid check).
awk 'NR==2 {
       c = substr($0, 40, 1);
       r = (c == "A" ? "B" : "A");
       print substr($0, 1, 39) r substr($0, 41);
       next
     }
     { print }' blob.bin.minisig > blob.bin.corrupt.minisig

# --- legacy ("Ed") fixture via openssl ----------------------------------------
openssl genpkey -algorithm ed25519 -out legacy.sec.pem
openssl pkey -in legacy.sec.pem -pubout -outform DER | tail -c 32 > legacy.pubraw
printf 'LEGACY01' > legacy.keyid   # 8 ASCII bytes, any value works as a keyid

{ printf 'Ed'; cat legacy.keyid legacy.pubraw; } | base64 -w0 > legacy.pub.b64
{
  echo 'untrusted comment: minisign public key (legacy fixture)'
  cat legacy.pub.b64
  echo
} > legacy.pub

openssl pkeyutl -sign -inkey legacy.sec.pem -rawin -in blob.bin -out legacy.sigraw

comment='timestamp:0	file:blob.bin'
{ cat legacy.sigraw; printf '%s' "$comment"; } > legacy.globalmsg
openssl pkeyutl -sign -inkey legacy.sec.pem -rawin -in legacy.globalmsg -out legacy.globalsig

{
  echo 'untrusted comment: legacy signature fixture'
  { printf 'Ed'; cat legacy.keyid legacy.sigraw; } | base64 -w0
  echo
  printf 'trusted comment: %s\n' "$comment"
  base64 -w0 < legacy.globalsig
  echo
} > blob.bin.legacy.minisig

rm -f legacy.sec.pem legacy.pubraw legacy.keyid legacy.pub.b64 \
      legacy.sigraw legacy.globalmsg legacy.globalsig
echo 'fixtures regenerated'
