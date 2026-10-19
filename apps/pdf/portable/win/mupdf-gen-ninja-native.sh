#!/usr/bin/env bash
# Generate an MSVC/ninja build for libmupdf on NATIVE x64 WINDOWS, from the
# macOS build's own recipe.
#
#   portable/win/mupdf-gen-ninja-native.sh [outdir]
#
# Run this under Git Bash. It is the x64-Windows-host sibling of
# portable/win/mupdf-gen-ninja.sh: same idea, same translation table, same
# response-file layout, but it runs ON the machine that will compile, so there
# is no Parallels share, no C:\spdf staging mirror, and no ARM64.
#
# READ portable/win/mupdf-gen-ninja.sh FIRST. Its header explains why the build
# description is derived from `make -n` inside mupdf/ rather than from
# mupdf/platform/win32/mupdf.sln (both hosts must compile the SAME MuPDF or the
# byte-identity pixel comparison means nothing), and why the 182 embedded font
# blobs go through bin2coff instead of cl.exe (fatal error C1060). All of that
# applies here unchanged and is not repeated.
#
# WHAT THIS SCRIPT DIVERGES ON, AND WHY  (every item is deliberate)
# -----------------------------------------------------------------
# D1. OS=Darwin is FORCED on the make command line.
#     Windows sets the environment variable OS=Windows_NT, and Makerules:4 uses
#     $OS from the environment when it is set rather than calling `uname`. Left
#     alone, mupdf's own Makefile would therefore configure itself for
#     Windows_NT, which changes the FEATURE SET, not just the flags:
#       - Makefile:179 stops filtering out source/fitz/load-jxr-win.c, so the
#         Windows build would compile a translation unit macOS does not;
#       - Makerules:215-236 skips the Darwin branch, so HAVE_LIBCRYPTO is no
#         longer forced to `no` by ARCHFLAGS and pkg-config probing decides it.
#     Forcing OS=Darwin makes `make -n` print the exact command lines the
#     shipping macOS libmupdf.a was compiled with. Nothing Darwin-specific
#     survives translation: CC/AR/LD/RANLIB are only used to NAME the compiler
#     (see LINE below), HAVE_GLUT and the -framework GLUT libs are link-time and
#     not part of `libs`, and SO/LDREMOVEUNREACH never reach a compile line.
#
# D2. ARCHFLAGS="-arch arm64" is passed even though this host is x64.
#     Same value portable/win/mupdf-gen-ninja.sh passes, kept identical on
#     purpose. `-arch` is discarded by DROP_PREFIX below, so it contributes no
#     flag; what it DOES do is trip Makerules:224-226 and set HAVE_LIBCRYPTO=no,
#     which is what the macOS build does. Changing it would silently change the
#     feature set. The x64-ness of this build comes from `vcvarsall.bat x64`,
#     not from here.
#
# D3. $(OUT) is mkdir'd before the dry run.
#     Makefile:77 uses GNU make's $(file > ...) function when make is new enough,
#     and $(file) writes DURING EXPANSION -- even under -n. macOS ships GNU Make
#     3.81, which has no $(file), so it takes the Makefile:79 branch and the
#     macOS script never noticed. With make 4.4.1 here, `make -n` dies with
#     "open: <OUT>/libmupdf.a.in: No such file or directory" unless the
#     directory exists. Creating it is harmless (the only things written are the
#     two .in archive member lists, which this script then USES as a cross-check
#     -- see AUTHORITATIVE_SPLIT).
#
# D4. The COFF machine word in mupdf-bin2coff.c is patched from 0xAA64 (ARM64)
#     to 0x8664 (AMD64).
#     portable/win/mupdf-bin2coff.c hardcodes IMAGE_FILE_MACHINE_ARM64 because
#     it was written for the ARM64 guest. Rather than fork 200 lines of COFF
#     emission (two copies to keep in sync forever), this script sed-patches
#     that single constant into <outdir>/mupdf-bin2coff-native.c and HARD FAILS
#     if the substitution does not apply exactly once. The 8-byte padding the
#     original adds for AArch64's LDR alignment is kept: on x64 it is
#     unnecessary but harmless, and keeping it means both hosts embed
#     byte-identical objects modulo the machine word.
#
# D5. The blob symbol cross-check has a documented fallback.
#     mupdf-gen-ninja.sh reads mupdf/generated/resources/**.c -- the hexdumps
#     the macOS build produced -- and asserts that the symbol bin2coff will
#     export is byte-for-byte the symbol the POSIX build defines. That tree is
#     gitignored and does not exist on a machine that has never run the POSIX
#     build, which is every Windows box. If it IS present this script performs
#     the identical check. If it is not, --allow-missing-generated derives the
#     symbol with hexdump.sh's own rule AND asserts that scripts/hexdump.sh
#     still encodes that rule (both the `sed 's/[.-]/_/g'` mangle and the
#     `_binary_$NAME` prefix). So the safety net is not skipped, it is moved:
#     instead of comparing against a stale artefact of the rule, it compares
#     against the rule. Without the flag, a missing generated/ is exit 70, same
#     as the macOS script. Note also that a wrong symbol cannot pass silently
#     downstream: source/fitz/noto.c and source/fitz/hyphen.c declare these as
#     `extern`, so a mismatch is an LNK2019 at link time, not a bad binary.
#
# D6. There is no C:\spdf staging mirror. Sources are referenced in place, at
#     this repo's own absolute path. Gotcha 9 (build local, not over the share)
#     is a Parallels problem and does not exist here.
#
# WHAT IT EMITS  (into <outdir>, default C:\spdf-build\mupdf-win-native)
#   build.ninja                 one edge per translation unit + two `lib` edges
#   grp-*.rsp                   one response file per distinct flag set
#   sources.txt                 the exact source list, for auditing vs macOS
#   dryrun.txt                  the raw `make -n` output it was derived from
#   mupdf-bin2coff-native.c     D4's patched copy
#
# Gotchas from portable/win/README.md that this file depends on: 11 (\" must
# stay escaped inside a response file), 12 (ninja puts no shell between itself
# and the command, so no redirections), 15 (escape ':' in ninja paths).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTDIR_WIN_DEFAULT='C:/spdf-build/mupdf-win-native'

ALLOW_MISSING_GENERATED=no
OUTDIR_ARG=''
for arg in "$@"; do
  case "$arg" in
    --allow-missing-generated) ALLOW_MISSING_GENERATED=yes ;;
    -h|--help) sed -n '2,6p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "mupdf-gen-ninja-native: unknown option $arg" >&2; exit 64 ;;
    *)  OUTDIR_ARG="$arg" ;;
  esac
done

OUTDIR="${OUTDIR_ARG:-$(cygpath -u "$OUTDIR_WIN_DEFAULT")}"
MUPDF_DIR="$REPO_ROOT/mupdf"

# Absolute Windows-style paths for everything that goes INTO build.ninja. ninja
# and cl.exe both want C:/... ; only this script speaks /c/... .
MUPDF_SRC_WIN="$(cygpath -m "$MUPDF_DIR")"
OUTDIR_WIN="$(cygpath -m "$OUTDIR" 2>/dev/null || echo "$OUTDIR_WIN_DEFAULT")"

# ninja's lexer has no escape for a space in a path, and cl response files would
# need quoting that then collides with gotcha 11. Refuse rather than emit
# something that breaks 646 edges in a confusing way.
case "$REPO_ROOT$OUTDIR" in
  *" "*) echo "mupdf-gen-ninja-native: a path contains a space, which ninja cannot express:" >&2
         echo "  repo:   $REPO_ROOT" >&2
         echo "  outdir: $OUTDIR" >&2
         exit 65 ;;
esac

if ! command -v make >/dev/null 2>&1; then
  echo "mupdf-gen-ninja-native: no 'make' on PATH." >&2
  echo "  Install GNU make:  winget install --id ezwinports.make --exact" >&2
  echo "  then add %LOCALAPPDATA%\\Microsoft\\WinGet\\Links to PATH." >&2
  exit 71
fi

# See D5.
if [[ ! -d "$MUPDF_DIR/generated/resources/fonts" ]]; then
  if [[ "$ALLOW_MISSING_GENERATED" != yes ]]; then
    echo "mupdf-gen-ninja-native: $MUPDF_DIR/generated/resources/fonts is missing." >&2
    echo "  It is gitignored and produced by the POSIX MuPDF build, so on a" >&2
    echo "  Windows-only machine it will never exist. Either build MuPDF once" >&2
    echo "  with the POSIX recipe, or pass --allow-missing-generated to derive" >&2
    echo "  the blob symbols from scripts/hexdump.sh's rule instead. See D5." >&2
    exit 70
  fi
  echo "mupdf-gen-ninja-native: generated/ absent; deriving blob symbols from" >&2
  echo "  scripts/hexdump.sh's rule (--allow-missing-generated). See D5." >&2
fi

mkdir -p "$OUTDIR"

# D3: $(file > ...) writes at expansion time, even under -n.
DRYRUN_OUT='build/win-native-dryrun'
mkdir -p "$MUPDF_DIR/$DRYRUN_OUT"

# The arguments are portable/Makefile:113's, verbatim, plus D1's OS=Darwin. OUT
# is a throwaway name so an existing build directory cannot make make say
# "nothing to do".
( cd "$MUPDF_DIR" && make -n \
    OS=Darwin \
    build=release \
    OUT="$DRYRUN_OUT" \
    ARCHFLAGS="-arch arm64" \
    USE_SYSTEM_GLUT=yes \
    brotli=no \
    libs ) > "$OUTDIR/dryrun.txt"

# D3's useful side effect: make wrote the authoritative archive member lists.
# They are the Makefile's OWN answer to "which object goes in which library",
# which beats inferring it from the source path.
for lib in libmupdf libmupdf-third; do
  if [[ ! -f "$MUPDF_DIR/$DRYRUN_OUT/$lib.a.in" ]]; then
    echo "mupdf-gen-ninja-native: make did not write $DRYRUN_OUT/$lib.a.in;" >&2
    echo "  this make may predate \$(file ...). Cross-check disabled would be a" >&2
    echo "  silent loss of a safety net, so this is fatal. See D3." >&2
    exit 72
  fi
  tr ' ' '\n' < "$MUPDF_DIR/$DRYRUN_OUT/$lib.a.in" \
    | sed -n "s|^$DRYRUN_OUT/\(.*\)\.o\$|\1|p" | sort > "$OUTDIR/members-$lib.txt"
done

# D4: one constant, one substitution, verified.
sed 's/0xAA64/0x8664/' "$REPO_ROOT/portable/win/mupdf-bin2coff.c" \
  > "$OUTDIR/mupdf-bin2coff-native.c.tmp"
if [[ "$(grep -c '0x8664' "$OUTDIR/mupdf-bin2coff-native.c.tmp")" != "1" ]] \
   || grep -q '0xAA64' "$OUTDIR/mupdf-bin2coff-native.c.tmp"; then
  echo "mupdf-gen-ninja-native: patching the COFF machine word in" >&2
  echo "  portable/win/mupdf-bin2coff.c did not apply exactly once. That file" >&2
  echo "  has changed shape; re-read it and fix D4 rather than guessing." >&2
  exit 73
fi
{
  echo '/* GENERATED by portable/win/mupdf-gen-ninja-native.sh -- do not edit.'
  echo ' * portable/win/mupdf-bin2coff.c with its COFF machine word patched from'
  echo ' * 0xAA64 (IMAGE_FILE_MACHINE_ARM64) to 0x8664 (IMAGE_FILE_MACHINE_AMD64).'
  echo ' * The macro KEEPS its ARM64 name; only the value differs, so a diff'
  echo ' * against the original is one line. See that script, divergence D4.'
  echo ' */'
  cat "$OUTDIR/mupdf-bin2coff-native.c.tmp"
} > "$OUTDIR/mupdf-bin2coff-native.c"
rm -f "$OUTDIR/mupdf-bin2coff-native.c.tmp"

MUPDF_VERSION="$(sed -n 's/^#define FZ_VERSION "\(.*\)"/\1/p' "$MUPDF_DIR/include/mupdf/fitz/version.h")"

OUTDIR="$OUTDIR" OUTDIR_WIN="$OUTDIR_WIN" MUPDF_SRC_WIN="$MUPDF_SRC_WIN" \
MUPDF_DIR="$MUPDF_DIR" MUPDF_VERSION="$MUPDF_VERSION" \
ALLOW_MISSING_GENERATED="$ALLOW_MISSING_GENERATED" python3 - <<'PYEOF'
import collections, os, re, sys

outdir     = os.environ['OUTDIR']
outdir_win = os.environ['OUTDIR_WIN']
guest_src  = os.environ['MUPDF_SRC_WIN']      # absolute, C:/... , no trailing /
mupdf_dir  = os.environ['MUPDF_DIR']
version    = os.environ['MUPDF_VERSION']
allow_missing = os.environ['ALLOW_MISSING_GENERATED'] == 'yes'

def nesc(p):
    """ninja escaping: ':' is a field separator in a path position (gotcha 15)."""
    return p.replace(':', '$:')

# ---------------------------------------------------------------- parse make -n
# Every compile line looks like:
#   echo "  CC out.o" ; mkdir -p dir ; xcrun cc <pre> -o <obj> -c <src> <post>
#
# Makerules:219 sets CC = xcrun cc under OS=Darwin but never sets CXX, so the
# 57 C++ units come out under make's BUILT-IN default: `c++` on macOS's make
# 3.81 (which is why mupdf-gen-ninja.sh spells it that way) and `g++` on the
# GNU make 4.4.1 used here. That difference is not a divergence to worry
# about -- the driver name only decides C vs C++ mode, and both translate to
# the same `cl /TP` group. Anything NOT in this list is still a hard error.
LINE = re.compile(r'; (?:xcrun )?(cc|c\+\+|g\+\+|gcc|clang|clang\+\+)'
                  r' (.*?) -o (\S+) -c (\S+)(.*)$')
CXX_DRIVERS = ('c++', 'g++', 'clang++')

groups = collections.OrderedDict()   # (cxx, flagtuple) -> [src, ...]
order  = []
for line in open(os.path.join(outdir, 'dryrun.txt')):
    if ' -c ' not in line:
        continue
    m = LINE.search(line.rstrip('\n'))
    if not m:
        sys.exit('mupdf-gen-ninja-native: unparsable compile line:\n  ' + line[:200])
    comp, pre, obj, src, post = m.groups()
    flags = tuple(pre.split() + post.split())
    cxx = comp in CXX_DRIVERS or src.endswith(('.cc', '.cpp', '.cxx'))
    key = (cxx, flags)
    if key not in groups:
        groups[key] = []
        order.append(key)
    groups[key].append(src)

total = sum(len(v) for v in groups.values())
if total < 500:
    sys.exit('mupdf-gen-ninja-native: only %d sources found; the dry run looks wrong' % total)

# --------------------------------------------------------------- flag translation
# Anything not handled here is a hard error. A silently dropped flag is how a
# build ends up subtly different from the reference it is supposed to match.
# This table is a copy of mupdf-gen-ninja.sh's; keep them in step.
DROP_EXACT = {
    '-pipe',          # gcc driver plumbing
    '-MMD', '-MP',    # gcc dep generation; ninja uses /showIncludes instead
    '-fno-common',
}
DROP_PREFIX = ('-mmacosx-version-min', '-arch', '-fvisibility')

# MSVC has no <unistd.h>. zlib only uses HAVE_UNISTD_H to decide whether to
# include it for fdopen(); dropping it changes no compressed bytes.
DROP_DEFINES = {'-DHAVE_UNISTD_H'}

# Include directories that exist only for MSVC, keyed by the group's source
# directory. gumbo-parser's sources #include <strings.h> (POSIX strcasecmp);
# gumbo ships a shim for it under visualc/include, and mupdf.sln's
# libthirdparty project puts exactly this directory on the include path for
# exactly this reason.
WIN_EXTRA_INCLUDES = {
    'thirdparty/gumbo-parser/src': ['thirdparty/gumbo-parser/visualc/include'],
}

def translate(flags, cxx):
    out, opt = [], None
    for f in flags:
        if f in DROP_EXACT or f.startswith(DROP_PREFIX):
            continue
        if f in ('-Wall', '-Wsign-compare', '-Wdeclaration-after-statement', '-w'):
            continue                      # warning level is set explicitly below
        if f in ('-fno-exceptions', '-fno-rtti', '-fno-threadsafe-statics'):
            continue                      # translated once, below
        if f == '-ffunction-sections':
            out.append('/Gy');  continue
        if f == '-fdata-sections':
            out.append('/Gw');  continue
        if f == '-O2':
            opt = '/O2';        continue
        if f == '-O0':
            opt = '/Od';        continue
        if f.startswith('-std='):
            continue                      # translated once, below
        if f.startswith('-I'):
            out.append('-I%s/%s' % (guest_src, f[2:]));  continue
        if f.startswith('-D'):
            if f in DROP_DEFINES:
                continue
            # Two defines carry a quoted header name. `make -n` prints them
            # backslash-escaped and they must STAY that way (gotcha 11).
            out.append(f);  continue
        sys.exit('mupdf-gen-ninja-native: untranslated flag %r' % f)
    return out, opt

def group_name(srcs):
    """A short, stable, filesystem-safe name derived from the sources."""
    parts = [os.path.dirname(s).split('/') for s in srcs]
    common = parts[0]
    for p in parts[1:]:
        n = 0
        while n < min(len(common), len(p)) and common[n] == p[n]:
            n += 1
        common = common[:n]
    return '-'.join(common) or 'misc'

# ------------------------------------------------------------- blob symbols (D5)
# hexdump.sh's rule, asserted against hexdump.sh itself when generated/ is gone.
HEXDUMP_SH = os.path.join(mupdf_dir, 'scripts', 'hexdump.sh')
have_generated = os.path.isdir(os.path.join(mupdf_dir, 'generated', 'resources', 'fonts'))
if not have_generated:
    hx = open(HEXDUMP_SH).read()
    for needle in ("sed 's/[.-]/_/g'", '_binary_$NAME[] ='):
        if needle not in hx:
            sys.exit('mupdf-gen-ninja-native: scripts/hexdump.sh no longer contains %r.\n'
                     '  Its symbol-naming rule has changed, so the derivation in blob_of()\n'
                     '  is no longer the rule the POSIX build uses. Re-read it and fix D5.'
                     % needle)

def blob_of(src):
    """generated/resources/X.c -> (resources/X, _binary_<mangled>)."""
    binrel = src[len('generated/'):-len('.c')]
    sym = '_binary_' + re.sub(r'[.-]', '_', os.path.basename(binrel))
    gen_c = os.path.join(mupdf_dir, src)
    if os.path.exists(gen_c):
        # The strong check: compare against the symbol hexdump.sh actually wrote.
        with open(gen_c, 'r', errors='replace') as fh:
            fh.readline()                 # "// automatically generated"
            decl = fh.readline()
        m = re.match(r'const unsigned char (\S+)\[\] =', decl)
        if not m:
            sys.exit('mupdf-gen-ninja-native: %s does not look like a hexdump.sh blob' % src)
        if m.group(1) != sym:
            sys.exit('mupdf-gen-ninja-native: symbol mismatch for %s: hexdump says %s, '
                     'bin2coff would export %s' % (src, m.group(1), sym))
    elif not allow_missing:
        sys.exit('mupdf-gen-ninja-native: %s is missing and --allow-missing-generated '
                 'was not given' % src)
    if not os.path.exists(os.path.join(mupdf_dir, binrel)):
        sys.exit('mupdf-gen-ninja-native: no original binary for %s at %s' % (src, binrel))
    return binrel, sym

# ------------------------------------------------------------------ emit .rsp
seen = collections.Counter()
rsp_of = {}
manifest = []

for key in order:
    cxx, flags = key
    srcs = groups[key]

    if srcs[0].startswith('generated/'):
        # Embedded via bin2coff, not compiled. No response file, no flags: the
        # bytes go into the object verbatim.
        rsp_of[key] = None
        manifest.append((group_name(srcs), len(srcs), 'bin2coff'))
        continue

    args, opt = translate(flags, cxx)

    base = group_name(srcs)
    seen[base] += 1
    if seen[base] > 1:
        base = '%s%d' % (base, seen[base])
    rsp_of[key] = base

    common = [
        '/nologo',
        '/MT',                       # static CRT, matching the app (README
                                     # "The linking interface"). Mixing CRTs
                                     # gives link errors that read like missing
                                     # symbols.
        '/utf-8',
        '/Zc:inline',
        opt or '/O2',
        '/D_CRT_SECURE_NO_WARNINGS',
        '/D_CRT_NONSTDC_NO_DEPRECATE',
        '/D_CRT_NONSTDC_NO_WARNINGS',
    ]
    if cxx:
        common += ['/TP', '/std:c++14', '/GR-', '/EHs-c-', '/Zc:threadSafeInit-', '/W0']
    else:
        common += ['/TC']
        if srcs[0].startswith('source/'):
            # MuPDF's own C. /we4013 turns "undefined; assuming extern returning
            # int" into an error: under MSVC an implicit declaration is merely a
            # warning, which is precisely how a missing POSIX function turns into
            # a runtime crash instead of a link error.
            common += ['/W3', '/we4013']
        else:
            common += ['/W1']

    extra = []
    for srcdir, incs in WIN_EXTRA_INCLUDES.items():
        if any(s.startswith(srcdir + '/') for s in srcs):
            extra += ['-I%s/%s' % (guest_src, inc) for inc in incs]

    with open(os.path.join(outdir, 'grp-%s.rsp' % base), 'w') as fh:
        fh.write('\n'.join(common + args + extra) + '\n')
    manifest.append((base, len(srcs), 'C++' if cxx else 'C'))

# ---------------------------------------------------------------- emit ninja
nl = []
w = nl.append
w('# GENERATED by portable/win/mupdf-gen-ninja-native.sh -- do not edit.')
w('# MuPDF %s for x64 Windows, translated from mupdf/Makefile\'s own macOS' % version)
w('# recipe (make -n OS=Darwin ... libs). See that script for the divergences.')
w('ninja_required_version = 1.5')
w('')
w('# /showIncludes is how ninja learns header dependencies under MSVC. The')
w('# prefix is locale-dependent; this is the en-US one.')
w('msvc_deps_prefix = Note: including file: ')
w('')
w('rule cc')
w('  command = cl @%s/grp-$grp.rsp /showIncludes /c $in /Fo$out' % outdir_win)
w('  description = CC $out')
w('  deps = msvc')
w('')
w('rule ar')
w('  # 600+ object paths blow past cmd.exe\'s 32 KB command line, hence the rspfile.')
w('  command = lib /nologo /out:$out @$out.rsp')
w('  description = LIB $out')
w('  rspfile = $out.rsp')
w('  rspfile_content = $in')
w('')
w('rule host_exe')
w('  command = cl /nologo /O2 /MT /D_CRT_SECURE_NO_WARNINGS $in /Fe:$out /Fo:$out.obj')
w('  description = HOSTCC $out')
w('')
w('rule bin2coff')
w('  # Writes the binary straight into a COFF object exporting $sym and')
w('  # ${sym}_size. .\\ because CreateProcess must not go hunting on PATH, and')
w('  # NO redirection: ninja hands this line to CreateProcess without a shell,')
w('  # so a trailing >nul would arrive as an extra argv entry (gotcha 12).')
w('  command = .\\mupdf-bin2coff-native.exe $in $out $sym')
w('  description = EMBED $out')
w('')
w('build mupdf-bin2coff-native.exe: host_exe %s/mupdf-bin2coff-native.c'
  % nesc(outdir_win))
w('')

objs = {'mupdf': [], 'third': []}
srclist = []
member_of = {}
for key in order:
    grp = rsp_of[key]
    for src in sorted(groups[key]):
        stem = re.sub(r'\.(c|cc|cpp|cxx)$', '', src)
        obj = 'obj/' + stem + '.obj'
        if grp is None:
            binrel, sym = blob_of(src)
            w('build %s: bin2coff %s/%s || mupdf-bin2coff-native.exe'
              % (obj, nesc(guest_src), binrel))
            w('  sym = ' + sym)
            # The Makefile names these members after the BINARY, not the .c:
            # $(FONT_GEN:%.c=$(OUT)/%.o) -> generated/resources/....o
            member_of[src] = stem
        else:
            w('build %s: cc %s/%s' % (obj, nesc(guest_src), src))
            w('  grp = ' + grp)
            member_of[src] = stem
        srclist.append(src)

# ------------------------------------------- authoritative split cross-check (D3)
# Which object belongs to which archive is the Makefile's decision, recorded in
# the .a.in member lists make wrote during the dry run. Inferring it from the
# path ("does it start with thirdparty/") would be a second, drifting opinion.
members = {}
for lib, tag in (('libmupdf', 'mupdf'), ('libmupdf-third', 'third')):
    for line in open(os.path.join(outdir, 'members-%s.txt' % lib)):
        line = line.strip()
        if line:
            members[line] = tag
for src in srclist:
    stem = member_of[src]
    tag = members.get(stem)
    if tag is None:
        sys.exit('mupdf-gen-ninja-native: %s (%s.o) is in no .a.in member list.\n'
                 '  The dry run compiles it but the Makefile archives it nowhere;\n'
                 '  that is a parsing bug here, not a MuPDF bug.' % (src, stem))
    objs[tag].append('obj/' + stem + '.obj')
extra_members = set(members) - {member_of[s] for s in srclist}
if extra_members:
    sys.exit('mupdf-gen-ninja-native: %d objects are archived but never compiled, '
             'e.g. %s' % (len(extra_members), sorted(extra_members)[:3]))

w('')
w('build libmupdf.lib: ar ' + ' '.join(objs['mupdf']))
w('build libmupdf-third.lib: ar ' + ' '.join(objs['third']))
w('')
w('default libmupdf.lib libmupdf-third.lib')

with open(os.path.join(outdir, 'build.ninja'), 'w') as fh:
    fh.write('\n'.join(nl) + '\n')
with open(os.path.join(outdir, 'sources.txt'), 'w') as fh:
    fh.write('\n'.join(sorted(srclist)) + '\n')

print('mupdf-gen-ninja-native: MuPDF %s, %d translation units in %d flag groups'
      % (version, total, len(order)))
print('  blob symbol check   %s'
      % ('against generated/ hexdumps' if have_generated
         else 'against scripts/hexdump.sh\'s rule (generated/ absent)'))
print('  libmupdf.lib       %4d objects' % len(objs['mupdf']))
print('  libmupdf-third.lib %4d objects' % len(objs['third']))
for base, n, lang in manifest:
    print('    %-28s %4d %s' % (base, n, lang))
PYEOF

echo "mupdf-gen-ninja-native: wrote $OUTDIR/build.ninja"
