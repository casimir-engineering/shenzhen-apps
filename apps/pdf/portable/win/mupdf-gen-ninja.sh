#!/usr/bin/env bash
# Generate an MSVC/ninja build for libmupdf from the MACOS build's own recipe.
#
#   portable/win/mupdf-gen-ninja.sh [outdir]
#
# WHY IT IS GENERATED RATHER THAN WRITTEN BY HAND
# -----------------------------------------------
# The whole point of the Windows port's correctness story is comparing a page
# rendered on Windows against the same page rendered on macOS. That comparison
# is only meaningful if both sides are the SAME MuPDF: same version, same source
# list, same feature defines. mupdf/platform/win32/mupdf.sln does carry ARM64
# configurations, but its feature set is its own (barcode, tesseract, brotli,
# a different font selection) and it would drift from the Mac build silently.
#
# So instead of trusting a second, parallel build description, this script asks
# the ONE build description the Mac actually uses -- mupdf/Makefile -- what it
# compiles, via `make -n`, and mechanically translates that into cl.exe flags.
# Change portable/Makefile's MuPDF arguments and this follows automatically.
#
# WHAT IT EMITS  (into <outdir>, default portable/win/build/mupdf-ninja)
#   build.ninja     one edge per translation unit + two `lib` edges
#   grp-*.rsp       one response file per distinct flag set (14 of them)
#   sources.txt     the exact source list, for auditing against the Mac build
#
# THE FONT BLOBS ARE THE ONE DELIBERATE DIVERGENCE
# ------------------------------------------------
# On POSIX the 182 embedded fonts and the hyphenation dictionary reach the
# linker as generated/resources/**.c -- one giant chain of "\xNN" string
# literals per file, produced by mupdf/scripts/hexdump.sh. MSVC cannot digest
# those: it needs multiple GB of heap per megabyte of literal and exits with
# "fatal error C1060: compiler is out of heap space". Measured in this VM (16 GB,
# 8 cores): files over ~1.5 MB of C fail under -j8, over ~4 MB fail even at -j1,
# and generated/resources/fonts/han/SourceHanSerif-Regular.ttc.c is 103 MB.
#
# So for those 182 inputs this script emits portable/win/mupdf-bin2coff.c, which
# writes the ORIGINAL binary straight into a COFF object exporting
# `_binary_<name>` and `_binary_<name>_size`. That is the same approach
# mupdf.sln's libresources project takes for the same files, via mupdf's own
# scripts/bin2coff.c -- which is NOT used here because its ARM64 output does not
# link (LNK2048: it leaves the size word unaligned; see mupdf-bin2coff.c). The
# embedded bytes are identical either way; only the route into the object file
# differs. Every symbol name is cross-checked against the .c hexdump.sh would
# have produced, so a rename in either tool fails the generator, not the link.
#
# Response files rather than inline flags for two reasons: they keep build.ninja
# small, and they keep the two quote-carrying defines
# (-DFT_CONFIG_MODULES_H=\"slimftmodules.h\", -DJBIG_EXTERNAL_MEMENTO_H=...) in
# one place. Note that they must stay BACKSLASH-ESCAPED even inside the response
# file: cl parses a response file with the same CRT argv rules as a command line,
# so a bare " is a grouping quote it strips, and freetype then fails with
# `#include: expected "FILENAME"`.
#
# Measured, because it is not what the docs suggest: ninja here does NOT put a
# shell between itself and the command. A `>nul` on a command line arrives as an
# extra argv entry rather than a redirection.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTDIR="${1:-$REPO_ROOT/portable/win/build/mupdf-ninja}"

# Where the guest will find things. These MUST agree with mupdf-build.cmd.
GUEST_SRC='C:/spdf/mupdf'
GUEST_RSP='C:/spdf/mupdf-win'
GUEST_REPO='C:/spdf'

MUPDF_DIR="$REPO_ROOT/mupdf"

# The generated/ tree (182 hexdumped font + hyphenation .c files, ~190 MB) is
# .gitignore'd -- it is produced by the mupdf Makefile on first build. The
# Windows build does not compile it (see "the font blobs" above) but this script
# still reads it, to confirm that the symbol bin2coff will export is byte-for-byte
# the symbol the POSIX build defines. Its absence also means the Mac has never
# built this MuPDF, which is the thing the pixel comparison is against.
if [[ ! -d "$MUPDF_DIR/generated/resources/fonts" ]]; then
  echo "mupdf-gen-ninja: $MUPDF_DIR/generated/resources/fonts is missing." >&2
  echo "  It is gitignored and produced by the macOS MuPDF build. Run:" >&2
  echo "    make -C portable core-render-theme-tests" >&2
  echo "  (or any target that builds MuPDF) on the Mac first." >&2
  exit 70
fi

mkdir -p "$OUTDIR"

# Same arguments portable/Makefile:113 passes, so `make -n` prints the exact
# command line the shipping macOS libmupdf.a was compiled with. OUT is a throwaway
# name so an existing build directory cannot make make say "nothing to do".
( cd "$MUPDF_DIR" && make -n \
    build=release \
    OUT=build/win-manifest-dryrun \
    ARCHFLAGS="-arch arm64" \
    USE_SYSTEM_GLUT=yes \
    brotli=no \
    libs ) > "$OUTDIR/dryrun.txt"

MUPDF_VERSION="$(sed -n 's/^#define FZ_VERSION "\(.*\)"/\1/p' "$MUPDF_DIR/include/mupdf/fitz/version.h")"

OUTDIR="$OUTDIR" GUEST_SRC="$GUEST_SRC" GUEST_RSP="$GUEST_RSP" \
MUPDF_DIR="$MUPDF_DIR" MUPDF_VERSION="$MUPDF_VERSION" GUEST_REPO="$GUEST_REPO" python3 - <<'PYEOF'
import collections, os, re, sys

outdir = os.environ['OUTDIR']
guest_src = os.environ['GUEST_SRC']
guest_rsp = os.environ['GUEST_RSP']
guest_repo = os.environ['GUEST_REPO']
mupdf_dir = os.environ['MUPDF_DIR']
version = os.environ['MUPDF_VERSION']

# ---------------------------------------------------------------- parse make -n
# Every compile line looks like:
#   echo "  CC out.o" ; mkdir -p dir ; xcrun cc <pre> -o <obj> -c <src> <post>
LINE = re.compile(r'; (xcrun cc|c\+\+|cc) (.*?) -o (\S+) -c (\S+)(.*)$')

groups = collections.OrderedDict()   # (compiler, flagtuple) -> [src, ...]
order  = []
for line in open(os.path.join(outdir, 'dryrun.txt')):
    if ' -c ' not in line:
        continue
    m = LINE.search(line.rstrip('\n'))
    if not m:
        sys.exit('mupdf-gen-ninja: unparsable compile line:\n  ' + line[:200])
    comp, pre, obj, src, post = m.groups()
    flags = tuple(pre.split() + post.split())
    cxx = comp.endswith('c++') or src.endswith(('.cc', '.cpp', '.cxx'))
    key = (cxx, flags)
    if key not in groups:
        groups[key] = []
        order.append(key)
    groups[key].append(src)

total = sum(len(v) for v in groups.values())
if total < 500:
    sys.exit('mupdf-gen-ninja: only %d sources found; the dry run looks wrong' % total)

# --------------------------------------------------------------- flag translation
# Anything not handled here is a hard error. A silently dropped flag is how a
# build ends up subtly different from the reference it is supposed to match.
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
            # Two defines carry a quoted header name (-DFT_CONFIG_OPTIONS_H=
            # "slimftoptions.h", -DJBIG_EXTERNAL_MEMENTO_H="mupdf/memento.h").
            # `make -n` prints them backslash-escaped and they must STAY that
            # way: cl parses a response file with the same CRT rules as a
            # command line, so a bare " is a grouping quote it strips, leaving
            # `#include slimftoptions.h` and error C2006. \" is a literal quote.
            out.append(f);  continue
        sys.exit('mupdf-gen-ninja: untranslated flag %r' % f)
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

# ------------------------------------------------------------------ emit .rsp
seen = collections.Counter()
rsp_of = {}
manifest = []

def blob_of(src):
    """generated/resources/X.c -> (resources/X, _binary_<mangled>), verified."""
    binrel = src[len('generated/'):-len('.c')]
    sym = '_binary_' + re.sub(r'[.-]', '_', os.path.basename(binrel))
    with open(os.path.join(mupdf_dir, src), 'r', errors='replace') as fh:
        fh.readline()                     # "// automatically generated"
        decl = fh.readline()
    m = re.match(r'const unsigned char (\S+)\[\] =', decl)
    if not m:
        sys.exit('mupdf-gen-ninja: %s does not look like a hexdump.sh blob' % src)
    if m.group(1) != sym:
        sys.exit('mupdf-gen-ninja: symbol mismatch for %s: hexdump says %s, '
                 'bin2coff would export %s' % (src, m.group(1), sym))
    if not os.path.exists(os.path.join(mupdf_dir, binrel)):
        sys.exit('mupdf-gen-ninja: no original binary for %s at %s' % (src, binrel))
    return binrel, sym

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
        '/MT',                       # static CRT: matches cl.exe's default, so the
                                     # app objects built by guest-build.cmd agree
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
w('# GENERATED by portable/win/mupdf-gen-ninja.sh -- do not edit.')
w('# MuPDF %s, translated from mupdf/Makefile\'s own macOS recipe.' % version)
w('ninja_required_version = 1.5')
w('')
w('# /showIncludes is how ninja learns header dependencies under MSVC. The prefix')
w('# is locale-dependent; this is the en-US one, which is what the guest runs.')
w('msvc_deps_prefix = Note: including file: ')
w('')
w('rule cc')
w('  command = cl @%s/grp-$grp.rsp /showIncludes /c $in /Fo$out' % guest_rsp)
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
w('  # so a trailing >nul would arrive as an extra argv entry, not a redirect.')
w('  command = .\\mupdf-bin2coff.exe $in $out $sym')
w('  description = EMBED $out')
w('')
w('build mupdf-bin2coff.exe: host_exe %s/portable/win/mupdf-bin2coff.c'
  % guest_repo.replace(':', '$:'))
w('')

objs = {'mupdf': [], 'third': []}
srclist = []
for key in order:
    grp = rsp_of[key]
    for src in sorted(groups[key]):
        obj = 'obj/' + re.sub(r'\.(c|cc|cpp|cxx)$', '.obj', src)
        if grp is None:
            binrel, sym = blob_of(src)
            w('build %s: bin2coff %s/%s || mupdf-bin2coff.exe'
              % (obj, guest_src.replace(':', '$:'), binrel))
            w('  sym = ' + sym)
        else:
            w('build %s: cc %s/%s' % (obj, guest_src.replace(':', '$:'), src))
            w('  grp = ' + grp)
        objs['third' if src.startswith('thirdparty/') else 'mupdf'].append(obj)
        srclist.append(src)
w('')
w('build libmupdf.lib: ar ' + ' '.join(objs['mupdf']))
w('build libmupdf-third.lib: ar ' + ' '.join(objs['third']))
w('')
w('default libmupdf.lib libmupdf-third.lib')

with open(os.path.join(outdir, 'build.ninja'), 'w') as fh:
    fh.write('\n'.join(nl) + '\n')
with open(os.path.join(outdir, 'sources.txt'), 'w') as fh:
    fh.write('\n'.join(sorted(srclist)) + '\n')

print('mupdf-gen-ninja: MuPDF %s, %d translation units in %d flag groups'
      % (version, total, len(order)))
print('  libmupdf.lib       %4d objects' % len(objs['mupdf']))
print('  libmupdf-third.lib %4d objects' % len(objs['third']))
for base, n, lang in manifest:
    print('    %-28s %4d %s' % (base, n, lang))
PYEOF

echo "mupdf-gen-ninja: wrote $OUTDIR/build.ninja"
