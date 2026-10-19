#!/usr/bin/env bash
# Prove the built MuPDF libraries (and optionally an executable) are NATIVE
# ARM64 and not x64 running under emulation.
#
#   portable/win/mupdf-arch-check.sh [target.exe]
#
# Windows on ARM64 executes x64 happily, so "it built and it ran" is not
# evidence of a native build. Only the COFF machine field is. AA64 is ARM64;
# 8664 is x64; 014C is x86. This asserts that EVERY object in both archives is
# AA64 -- one x64 object would still link on some paths and would make the whole
# claim false.
#
# Exits non-zero on the first non-AA64 member, or if the guest half fails.
set -uo pipefail

VM_NAME="${SPDF_VM_NAME:-Windows 11}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="${SPDF_WIN_STAGE:-$HOME/Documents/spdf-win}"
GUEST_SHARE="\\\\Mac\\Home\\Documents\\$(basename "$STAGE")"
OUT="$REPO_ROOT/portable/win/build"
EXTRA="${1:-}"

mkdir -p "$OUT"

prlctl exec "$VM_NAME" cmd.exe /c \
  "$GUEST_SHARE\\portable\\win\\mupdf-arch-check.cmd $EXTRA" > "$OUT/arch.raw" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
  cat "$OUT/arch.raw"
  echo "arch-check: guest half exited $rc" >&2
  exit $rc
fi

tr -d '\r' < "$OUT/arch.raw" > "$OUT/arch.txt"

python3 - "$OUT/arch.txt" <<'PY'
import re, sys
section, counts, bad = None, {}, []
for line in open(sys.argv[1]):
    line = line.rstrip()
    if line.startswith('== '):
        section = line[3:]
        counts.setdefault(section, {})
        continue
    m = re.search(r'([0-9A-F]{4}) machine \(([^)]+)\)', line)
    if not m:
        continue
    code, name = m.group(1), m.group(2)
    counts[section][code + ' ' + name] = counts[section].get(code + ' ' + name, 0) + 1
    if code != 'AA64':
        bad.append((section, code, name))

if not counts:
    sys.exit('arch-check: dumpbin reported no machine fields at all')

status = 0
for section, kinds in counts.items():
    if not kinds:
        print('   %-22s NO OBJECTS' % section)
        status = 1
        continue
    for kind, n in sorted(kinds.items()):
        print('   %-22s %5d objects  %s' % (section, n, kind))
if bad:
    print('arch-check: %d non-ARM64 members: %s' % (len(bad), bad[:5]), file=sys.stderr)
    status = 1
sys.exit(status)
PY
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "ARCH CHECK FAILED" >&2
  exit $rc
fi
echo "ARCH CHECK OK: every member is AA64 (native ARM64)"
