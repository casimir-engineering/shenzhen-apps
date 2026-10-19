# Vendored third-party libraries for Shenzhen Friends: libsodium (ext/libsodium) and cJSON (ext/cjson).
#
# Other Friends areas build against these four variables and nothing else:
#   FRIENDS_SODIUM_CFLAGS  include path and defines for #include <sodium.h>
#   FRIENDS_SODIUM_LIB     static libsodium archive to link
#   FRIENDS_CJSON_CFLAGS   include path for #include "cJSON.h"
#   FRIENDS_CJSON_OBJ      cJSON object file to link
# List FRIENDS_SODIUM_LIB / FRIENDS_CJSON_OBJ as prerequisites so make builds them first.
#
# Make runs with cwd portable/, so every path here is relative to portable/.

# Guarded because friends/friends.mk includes every area makefile by wildcard, and it may also include this
# one explicitly before the others: rule prerequisites expand when make reads them, so an area makefile that
# sorts before friends/deps/ (friends/client/ does) would otherwise see these variables empty and lose the
# dependency on the libraries it links.
ifndef FRIENDS_DEPS_MK_INCLUDED
FRIENDS_DEPS_MK_INCLUDED := 1

FRIENDS_DEPS_BUILD := $(BUILD)/friends/deps
FRIENDS_SODIUM_DIR := ../ext/libsodium/src/libsodium
FRIENDS_CJSON_DIR := ../ext/cjson

# libsodium is compiled straight from its sources with clang, like gumbo and md4c in portable/Makefile,
# instead of through the release tarball's configure and libtool. WHY: configure alone took 17 s on an M5 Max
# and would rerun on every clean build, including each release's; compiling the 141 sources directly takes
# about 2 s at -j8 and runs alongside the rest of the build. It also means vendoring only sources and headers,
# not the autotools tree (configure, Makefile.in, build-aux, m4), and nothing is generated in ext/, which
# several agents share. The cost is that we state the configuration ourselves. FRIENDS_SODIUM_CONFIG is the
# subset of the macros libsodium 1.0.22's configure defined for arm64 macOS 12 that its C sources read, plus
# the two feature-test macros system headers read; version.h is the copy upstream ships in builds/msvc/,
# identical to the one configure writes. When vendored, all 141 objects built with these flags were
# byte-identical to objects built with configure's exact compiler, CFLAGS and DEFS line. CONFIGURED=1 tells
# libsodium the configuration is deliberate. On an upgrade, run configure once in a scratch directory and
# repeat that comparison. The set is macOS-only; Linux or Windows need their own.
FRIENDS_SODIUM_CONFIG_arm64 := -DCONFIGURED=1 -D_GNU_SOURCE=1 -D_DARWIN_C_SOURCE=1 \
	-DNATIVE_LITTLE_ENDIAN=1 -DHAVE_TI_MODE=1 -DHAVE_INLINE_ASM=1 -DHAVE_ARMCRYPTO=1 \
	-DHAVE_SYS_MMAN_H=1 -DHAVE_SYS_PARAM_H=1 -DHAVE_SYS_RANDOM_H=1 \
	-DHAVE_ALLOCA_H=1 -DHAVE_ALLOCA=1 -DHAVE_C_VARARRAYS=1 -DHAVE_WEAK_SYMBOLS=1 \
	-DHAVE_ATOMIC_OPS=1 -DHAVE_C11_MEMORY_FENCES=1 -DHAVE_GCC_MEMORY_FENCES=1 \
	-DHAVE_PTHREAD=1 -DTLS=_Thread_local \
	-DHAVE_MMAP=1 -DHAVE_MLOCK=1 -DHAVE_MADVISE=1 -DHAVE_MPROTECT=1 -DHAVE_POSIX_MEMALIGN=1 \
	-DHAVE_GETENTROPY=1 -DHAVE_MEMSET_S=1 -DHAVE_RAISE=1 -DHAVE_SYSCONF=1 -DHAVE_GETPID=1 -DHAVE_NANOSLEEP=1
# Intel Macs (ADR 0015 § 2: the helper is built universal): the same set without HAVE_ARMCRYPTO, plus what
# configure's x86_64 checks add for C: the SSE to AVX-512 and AES-NI intrinsic headers, whose code libsodium compiles
# with per-function target attributes and selects at run time, CPUID for that selection, and RDRAND. Not
# HAVE_AMD64_ASM or HAVE_AVX_ASM: they select the x86_64 assembly (*.S), which is not vendored, so Salsa20 and X25519
# use their C code there. runtime.c alone gets HAVE_AVX_ASM (below) for its inline XGETBV, without which AVX, and
# so AES-256-GCM (the link seal's cipher), would never be detected. Comparing these objects with configure's
# (check-sodium-config.sh with MAC_ARCH=x86_64) needs the verified release tree, which is not kept here;
# friends-universal-check runs libsodium's own checks, the session suites and the vector exporter on this build.
FRIENDS_SODIUM_CONFIG_x86_64 := $(filter-out -DHAVE_ARMCRYPTO=1,$(FRIENDS_SODIUM_CONFIG_arm64)) \
	-DHAVE_MMINTRIN_H=1 -DHAVE_EMMINTRIN_H=1 -DHAVE_PMMINTRIN_H=1 -DHAVE_TMMINTRIN_H=1 -DHAVE_SMMINTRIN_H=1 \
	-DHAVE_AVXINTRIN_H=1 -DHAVE_AVX2INTRIN_H=1 -DHAVE_AVX512FINTRIN_H=1 -DHAVE_WMMINTRIN_H=1 \
	-DHAVE_CPUID=1 -DHAVE_RDRAND=1
FRIENDS_SODIUM_CONFIG = $(FRIENDS_SODIUM_CONFIG_$(MAC_ARCH))
# configure picked TLS=thread_local, a keyword only because it compiles with -std=gnu23; _Thread_local is the
# same storage class in every dialect, so the default -std works. Only the non-default internal RNG uses it.

# SODIUM_STATIC drops libsodium's visibility("default") export attribute; it sits in the consumers' flags so
# their declarations match the library. WHY: with -fvisibility=hidden the functions stay linkable inside the
# helper but are not exported from it, so -dead_strip may remove the ones it never calls. In a probe that
# signs once, 23 libsodium functions stayed exported from the dead-stripped executable without it, none with it.
FRIENDS_SODIUM_CFLAGS := -I$(FRIENDS_SODIUM_DIR)/include -DSODIUM_STATIC=1
FRIENDS_SODIUM_LIB := $(FRIENDS_DEPS_BUILD)/libsodium.a
FRIENDS_CJSON_CFLAGS := -I$(FRIENDS_CJSON_DIR)
FRIENDS_CJSON_OBJ := $(FRIENDS_DEPS_BUILD)/cJSON.o

# The app's target flags (arm64, macOS 12 floor) with its optimization level. NDEBUG is filtered out for
# libsodium only: upstream's own release build keeps its assertions (bounds invariants in the RNG and
# BLAKE2b), and its test suite runs that way. Recursive '=' so a later override of the app's flags applies.
FRIENDS_SODIUM_OPTFLAGS = $(filter-out -DNDEBUG,$(PORTABLE_OPTFLAGS))
# Hardening and aliasing flags from the same configure run, minus -fPIC/-fPIE (implicit on arm64 macOS) and
# -ftls-model (shared libraries only); dropping them changed no object.
FRIENDS_SODIUM_BUILD_FLAGS = $(FRIENDS_SODIUM_OPTFLAGS) $(MAC_TARGET_FLAGS) -pthread -fvisibility=hidden \
	-fno-strict-aliasing -fno-strict-overflow -fstack-protector \
	-Wno-deprecated-declarations -Wno-unknown-pragmas \
	$(FRIENDS_SODIUM_CONFIG) $(FRIENDS_SODIUM_CFLAGS) -I$(FRIENDS_SODIUM_DIR)/include/sodium

# find rather than wildcard: sources sit two to four directories deep. Sorted so the archive is reproducible.
FRIENDS_SODIUM_SRCS := $(shell find $(FRIENDS_SODIUM_DIR) -name '*.c' 2>/dev/null | LC_ALL=C sort)
FRIENDS_SODIUM_HDRS := $(shell find $(FRIENDS_SODIUM_DIR) -name '*.h' 2>/dev/null | LC_ALL=C sort)
FRIENDS_SODIUM_OBJS := $(patsubst $(FRIENDS_SODIUM_DIR)/%.c,$(FRIENDS_DEPS_BUILD)/sodium/%.o,$(FRIENDS_SODIUM_SRCS))

# Every object depends on every header: the vendored tree only changes on an upgrade, and then a full rebuild
# is what we want. Objects mirror the source tree so they cannot overwrite each other.
$(FRIENDS_DEPS_BUILD)/sodium/%.o: $(FRIENDS_SODIUM_DIR)/%.c $(FRIENDS_SODIUM_HDRS) friends/deps/deps.mk
	@mkdir -p "$(@D)"
	clang $(FRIENDS_SODIUM_BUILD_FLAGS) -c "$<" -o "$@"

ifeq ($(MAC_ARCH),x86_64)
$(FRIENDS_DEPS_BUILD)/sodium/sodium/runtime.o: FRIENDS_SODIUM_BUILD_FLAGS += -DHAVE_AVX_ASM=1
endif

# Removed first so a source deleted by an upgrade cannot survive as a stale archive member.
$(FRIENDS_SODIUM_LIB): $(FRIENDS_SODIUM_OBJS)
	@rm -f "$@"
	ar rcs "$@" $(FRIENDS_SODIUM_OBJS)

# Hidden visibility for the same reason as SODIUM_STATIC; cJSON exports nothing unless CJSON_API_VISIBILITY
# is defined. C99 because the Friends client library that links it is C99.
$(FRIENDS_CJSON_OBJ): $(FRIENDS_CJSON_DIR)/cJSON.c $(FRIENDS_CJSON_DIR)/cJSON.h friends/deps/deps.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c99 -fvisibility=hidden -Wall -Wextra \
		$(FRIENDS_CJSON_CFLAGS) -c "$<" -o "$@"

.PHONY: friends-deps friends-deps-check
friends-deps: $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ)

FRIENDS_DEPS_TEST := $(FRIENDS_DEPS_BUILD)/SZFriendsDepsTests
FRIENDS_DEPS_TEST_SRC := friends/deps/tests/SZFriendsDepsTests.c

# The warning flags of FRIENDS_C_FLAGS (friends.mk), spelled out so this file also works on its own: the C99
# client library includes these headers under -pedantic -Werror, so a header that needs a GNU dialect fails here.
$(FRIENDS_DEPS_TEST): $(FRIENDS_DEPS_TEST_SRC) $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ) friends/deps/deps.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c99 -Wall -Wextra -Werror -pedantic \
		$(FRIENDS_SODIUM_CFLAGS) $(FRIENDS_CJSON_CFLAGS) "$(FRIENDS_DEPS_TEST_SRC)" \
		$(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) -o "$@"

FRIENDS_TEST_TARGETS += friends-deps-check
friends-deps-check: $(FRIENDS_DEPS_TEST)
	"$(FRIENDS_DEPS_TEST)"

endif
