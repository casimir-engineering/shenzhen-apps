# The online transport stack for Shenzhen Friends (ADR 0009): libdatachannel 0.24.6 with libjuice (ICE), usrsctp
# (SCTP), plog (logging, header-only) and Mbed TLS 3.6.7 (DTLS), vendored under ext/ and built as static archives.
# Each ext/<name>/VENDORED.md records the source, version, SHA-256 and what was left out.
#
# Other Friends areas build against these variables and nothing else:
#   FRIENDS_DATACHANNEL_CFLAGS   include path and defines for #include <rtc/rtc.h> (C API, data channels only)
#   FRIENDS_DATACHANNEL_LIBS     the six static archives to link, in dependency order
#   FRIENDS_DATACHANNEL_LDFLAGS  system libraries the archives need (libc++: libdatachannel is C++17)
#   FRIENDS_MBEDTLS_CFLAGS       include path and configuration for Mbed TLS headers; only code that calls Mbed TLS
#                                directly needs it (the link test reads its version), never code that only uses rtc.h
# List $(FRIENDS_DATACHANNEL_LIBS) as prerequisites so make builds them first. Nothing links them into the helper
# yet: the helper transport (friends/service/online/transport/) does that.
#
# Make runs with cwd portable/, so every path here is relative to portable/.

# Guarded like deps.mk: friends/friends.mk includes every area makefile by wildcard, and an area that links the
# stack may include this file explicitly before its own rules so their prerequisites see these variables.
ifndef FRIENDS_DATACHANNEL_MK_INCLUDED
FRIENDS_DATACHANNEL_MK_INCLUDED := 1

# The same directory deps.mk writes libsodium to, spelled out so this file does not depend on include order.
FRIENDS_DC_BUILD := $(BUILD)/friends/deps
FRIENDS_DC_DIR := ../ext/libdatachannel
FRIENDS_JUICE_DIR := ../ext/libjuice
FRIENDS_SCTP_DIR := ../ext/usrsctp/usrsctplib
FRIENDS_PLOG_DIR := ../ext/plog
FRIENDS_MBEDTLS_DIR := ../ext/mbedtls

# WHY direct compilation, not CMake: the lead's decision for M2 (no CMake build dependency), and the same reasons
# as libsodium in deps.mk. The macro sets below are what upstream's CMake build defines on macOS for the
# configuration the stack spike measured: libdatachannel with -DUSE_MBEDTLS=ON -DNO_WEBSOCKET=ON -DNO_MEDIA=ON,
# its bundled libjuice and usrsctp, and Mbed TLS's default configuration plus MBEDTLS_SSL_DTLS_SRTP. When vendored,
# every object built with these flags was byte-identical to the object CMake 4.4.4 built from the same source with
# the same optimisation and visibility flags (the method is in ext/libdatachannel/VENDORED.md). On an upgrade,
# configure upstream once in a scratch directory with CMAKE_EXPORT_COMPILE_COMMANDS and repeat that comparison.

# Shared by every library: the app's target (arm64, macOS 12 floor) and hidden visibility. WHY hidden: as with
# SODIUM_STATIC in deps.mk, the functions stay linkable inside the helper but are not exported from it, so
# -dead_strip removes what the helper never calls (libjuice's STUN server, Mbed TLS's unused ciphers) and -Wl,-x
# strips their names. -fPIC, which CMake adds, is implicit on arm64 macOS and changed no object.
# Recursive '=' so a later override of the app's flags (release mode) applies.
FRIENDS_DC_TARGET_FLAGS = $(MAC_TARGET_FLAGS) -fvisibility=hidden

# --- Mbed TLS 3.6.7 ------------------------------------------------------------------------------------------------
# Default configuration (DTLS 1.2, ECDSA P-256 certificates, AES-GCM) plus one option: libdatachannel's Mbed TLS
# DTLS code offers the DTLS-SRTP extension even without media, and does not compile without MBEDTLS_SSL_DTLS_SRTP.
# Set on the command line rather than by editing mbedtls_config.h, so the vendored tree stays unmodified; it must
# reach every file that includes an Mbed TLS header (it changes struct mbedtls_ssl_context), which is why it is
# also part of the libdatachannel flags below. The two bundled third-party parts (Everest, p256-m) are off in the
# default configuration, so 3rdparty/ is not vendored.
FRIENDS_MBEDTLS_CONFIG := -DMBEDTLS_SSL_DTLS_SRTP
FRIENDS_MBEDTLS_CFLAGS := -I$(FRIENDS_MBEDTLS_DIR)/include $(FRIENDS_MBEDTLS_CONFIG)
# Upstream's Release flags are plain -O2: Mbed TLS keeps NDEBUG undefined, as libsodium does (deps.mk).
FRIENDS_MBEDTLS_BUILD_FLAGS = $(filter-out -DNDEBUG,$(PORTABLE_OPTFLAGS)) $(FRIENDS_DC_TARGET_FLAGS) -std=c99 \
	$(FRIENDS_MBEDTLS_CFLAGS) -I$(FRIENDS_MBEDTLS_DIR)/library

# Upstream's three libraries, with library/CMakeLists.txt's source lists. ecp_curves_new.c is a comment-only
# placeholder that CMake does not build either.
FRIENDS_MBEDX509_NAMES := pkcs7 x509 x509_create x509_crl x509_crt x509_csr x509write x509write_crt x509write_csr
FRIENDS_MBEDTLS_NAMES := debug mps_reader mps_trace net_sockets ssl_cache ssl_ciphersuites ssl_client ssl_cookie \
	ssl_debug_helpers_generated ssl_msg ssl_ticket ssl_tls ssl_tls12_client ssl_tls12_server ssl_tls13_keys \
	ssl_tls13_server ssl_tls13_client ssl_tls13_generic
FRIENDS_MBEDTLS_ALL_NAMES := $(sort $(patsubst $(FRIENDS_MBEDTLS_DIR)/library/%.c,%,\
	$(wildcard $(FRIENDS_MBEDTLS_DIR)/library/*.c)))
FRIENDS_MBEDCRYPTO_NAMES := $(filter-out $(FRIENDS_MBEDX509_NAMES) $(FRIENDS_MBEDTLS_NAMES) ecp_curves_new,\
	$(FRIENDS_MBEDTLS_ALL_NAMES))
FRIENDS_MBEDTLS_HDRS := $(sort $(wildcard $(FRIENDS_MBEDTLS_DIR)/include/*/*.h $(FRIENDS_MBEDTLS_DIR)/library/*.h))
friends_mbed_objs = $(patsubst %,$(FRIENDS_DC_BUILD)/mbedtls/%.o,$(sort $(1)))

$(FRIENDS_DC_BUILD)/mbedtls/%.o: $(FRIENDS_MBEDTLS_DIR)/library/%.c $(FRIENDS_MBEDTLS_HDRS) \
		friends/deps/datachannel.mk
	@mkdir -p "$(@D)"
	clang $(FRIENDS_MBEDTLS_BUILD_FLAGS) -c "$<" -o "$@"

# --- usrsctp (libdatachannel's fork) -------------------------------------------------------------------------------
# Userspace SCTP over libdatachannel's own transport (AF_CONN) only: libdatachannel turns off usrsctp's IPv4 and
# IPv6 sockets (sctp_inet, sctp_inet6), so INET and INET6 stay undefined. SCTP_DEBUG is usrsctp's own default; it
# compiles the debug printing that stays off unless a caller enables it at run time. The HAVE_* macros are the
# results of usrsctp's CMake checks on macOS.
FRIENDS_SCTP_CONFIG := -D__Userspace__ -DSCTP_SIMPLE_ALLOCATOR -DSCTP_PROCESS_LEVEL_LOCKS -DSCTP_DEBUG \
	-D__APPLE_USE_RFC_2292 -DHAVE_SYS_QUEUE_H -DHAVE_NETINET_IP_ICMP_H -DHAVE_NET_ROUTE_H -DHAVE_STDATOMIC_H \
	-DHAVE_SA_LEN -DHAVE_SIN_LEN -DHAVE_SIN6_LEN -DHAVE_SCONN_LEN
FRIENDS_SCTP_BUILD_FLAGS = $(PORTABLE_OPTFLAGS) $(FRIENDS_DC_TARGET_FLAGS) -std=c99 \
	-Wno-address-of-packed-member -Wno-deprecated-declarations $(FRIENDS_SCTP_CONFIG) -I$(FRIENDS_SCTP_DIR)
FRIENDS_SCTP_SRCS := $(sort $(wildcard $(FRIENDS_SCTP_DIR)/*.c $(FRIENDS_SCTP_DIR)/netinet/*.c \
	$(FRIENDS_SCTP_DIR)/netinet6/*.c))
FRIENDS_SCTP_HDRS := $(sort $(wildcard $(FRIENDS_SCTP_DIR)/*.h $(FRIENDS_SCTP_DIR)/netinet/*.h \
	$(FRIENDS_SCTP_DIR)/netinet6/*.h))
# Objects mirror the source tree; every basename is unique, so archive members cannot collide.
FRIENDS_SCTP_OBJS := $(patsubst $(FRIENDS_SCTP_DIR)/%.c,$(FRIENDS_DC_BUILD)/usrsctp/%.o,$(FRIENDS_SCTP_SRCS))

$(FRIENDS_DC_BUILD)/usrsctp/%.o: $(FRIENDS_SCTP_DIR)/%.c $(FRIENDS_SCTP_HDRS) friends/deps/datachannel.mk
	@mkdir -p "$(@D)"
	clang $(FRIENDS_SCTP_BUILD_FLAGS) -c "$<" -o "$@"

# --- libjuice 1.7.4 ------------------------------------------------------------------------------------------------
# RELEASE=1 is what upstream's Release configuration adds (it compiles out verbose logging); USE_NETTLE=0 selects
# libjuice's built-in hash functions. Its STUN/TURN server stays compiled (NO_SERVER is off upstream and in the
# spike); a program that never calls juice_server_create loses it to -dead_strip.
FRIENDS_DC_JUICE_CFLAGS := -I$(FRIENDS_JUICE_DIR)/include -DJUICE_STATIC
FRIENDS_JUICE_BUILD_FLAGS = $(PORTABLE_OPTFLAGS) $(FRIENDS_DC_TARGET_FLAGS) -std=gnu11 \
	$(FRIENDS_DC_JUICE_CFLAGS) -DJUICE_EXPORTS -DRELEASE=1 -DUSE_NETTLE=0 \
	-I$(FRIENDS_JUICE_DIR)/include/juice -I$(FRIENDS_JUICE_DIR)/src
FRIENDS_JUICE_SRCS := $(sort $(wildcard $(FRIENDS_JUICE_DIR)/src/*.c))
FRIENDS_JUICE_HDRS := $(sort $(wildcard $(FRIENDS_JUICE_DIR)/src/*.h $(FRIENDS_JUICE_DIR)/include/juice/*.h))
FRIENDS_JUICE_OBJS := $(patsubst $(FRIENDS_JUICE_DIR)/src/%.c,$(FRIENDS_DC_BUILD)/juice/%.o,$(FRIENDS_JUICE_SRCS))

$(FRIENDS_DC_BUILD)/juice/%.o: $(FRIENDS_JUICE_DIR)/src/%.c $(FRIENDS_JUICE_HDRS) friends/deps/datachannel.mk
	@mkdir -p "$(@D)"
	clang $(FRIENDS_JUICE_BUILD_FLAGS) -c "$<" -o "$@"

# --- libdatachannel 0.24.6 -----------------------------------------------------------------------------------------
# Data channels only: no media (so no libsrtp) and no WebSocket. The public defines are part of
# FRIENDS_DATACHANNEL_CFLAGS because rtc.h declares the media API unless RTC_ENABLE_MEDIA is 0.
FRIENDS_DATACHANNEL_CFLAGS := -I$(FRIENDS_DC_DIR)/include -DRTC_STATIC -DRTC_ENABLE_MEDIA=0 -DRTC_ENABLE_WEBSOCKET=0
FRIENDS_DC_BUILD_FLAGS = $(PORTABLE_OPTFLAGS) $(FRIENDS_DC_TARGET_FLAGS) -std=gnu++17 \
	$(FRIENDS_DATACHANNEL_CFLAGS) -DRTC_EXPORTS -DUSE_MBEDTLS=1 -DUSE_NICE=0 -DRTC_SYSTEM_JUICE=0 \
	-I$(FRIENDS_DC_DIR)/include/rtc -I$(FRIENDS_DC_DIR)/src -I$(FRIENDS_SCTP_DIR) -I$(FRIENDS_PLOG_DIR)/include \
	$(FRIENDS_DC_JUICE_CFLAGS) -isystem $(FRIENDS_MBEDTLS_DIR)/include $(FRIENDS_MBEDTLS_CONFIG)
# Upstream's source list is every .cpp under src/ and src/impl/; the WebSocket and media files compile to nearly
# empty objects under the defines above, as they do in CMake's build.
FRIENDS_DC_API_SRCS := $(sort $(wildcard $(FRIENDS_DC_DIR)/src/*.cpp))
FRIENDS_DC_IMPL_SRCS := $(sort $(wildcard $(FRIENDS_DC_DIR)/src/impl/*.cpp))
FRIENDS_DC_HDRS := $(sort $(wildcard $(FRIENDS_DC_DIR)/include/rtc/*.h $(FRIENDS_DC_DIR)/include/rtc/*.hpp \
	$(FRIENDS_DC_DIR)/src/*.hpp $(FRIENDS_DC_DIR)/src/impl/*.hpp)) \
	$(shell find $(FRIENDS_PLOG_DIR)/include -name '*.h' 2>/dev/null | LC_ALL=C sort) \
	$(FRIENDS_JUICE_DIR)/include/juice/juice.h $(FRIENDS_SCTP_DIR)/usrsctp.h $(FRIENDS_MBEDTLS_HDRS)
# src/ and src/impl/ share seven basenames (channel.cpp, peerconnection.cpp, ...), and an archive member is named
# by its basename alone, so the impl objects carry an impl- prefix.
FRIENDS_DC_OBJS := $(patsubst $(FRIENDS_DC_DIR)/src/%.cpp,$(FRIENDS_DC_BUILD)/datachannel/%.o,$(FRIENDS_DC_API_SRCS)) \
	$(patsubst $(FRIENDS_DC_DIR)/src/impl/%.cpp,$(FRIENDS_DC_BUILD)/datachannel/impl-%.o,$(FRIENDS_DC_IMPL_SRCS))

$(FRIENDS_DC_BUILD)/datachannel/impl-%.o: $(FRIENDS_DC_DIR)/src/impl/%.cpp $(FRIENDS_DC_HDRS) \
		friends/deps/datachannel.mk
	@mkdir -p "$(@D)"
	clang++ $(FRIENDS_DC_BUILD_FLAGS) -c "$<" -o "$@"

$(FRIENDS_DC_BUILD)/datachannel/%.o: $(FRIENDS_DC_DIR)/src/%.cpp $(FRIENDS_DC_HDRS) friends/deps/datachannel.mk
	@mkdir -p "$(@D)"
	clang++ $(FRIENDS_DC_BUILD_FLAGS) -c "$<" -o "$@"

# --- Archives ------------------------------------------------------------------------------------------------------
# libtool -static -D writes zero dates, uids, gids and modes into the archive and its symbol table, so two builds
# of the same sources give byte-identical archives (friends-datachannel-check proves it); `ar rcs` stamps the
# time. Removed first so a source deleted by an upgrade cannot survive as a stale member.
FRIENDS_MBEDCRYPTO_LIB := $(FRIENDS_DC_BUILD)/libmbedcrypto.a
FRIENDS_MBEDX509_LIB := $(FRIENDS_DC_BUILD)/libmbedx509.a
FRIENDS_MBEDTLS_LIB := $(FRIENDS_DC_BUILD)/libmbedtls.a
FRIENDS_SCTP_LIB := $(FRIENDS_DC_BUILD)/libusrsctp.a
FRIENDS_JUICE_LIB := $(FRIENDS_DC_BUILD)/libjuice.a
FRIENDS_DC_LIB := $(FRIENDS_DC_BUILD)/libdatachannel.a
FRIENDS_DATACHANNEL_LIBS := $(FRIENDS_DC_LIB) $(FRIENDS_JUICE_LIB) $(FRIENDS_SCTP_LIB) \
	$(FRIENDS_MBEDTLS_LIB) $(FRIENDS_MBEDX509_LIB) $(FRIENDS_MBEDCRYPTO_LIB)
FRIENDS_DATACHANNEL_LDFLAGS := -lc++

$(FRIENDS_MBEDCRYPTO_LIB): $(call friends_mbed_objs,$(FRIENDS_MBEDCRYPTO_NAMES))
$(FRIENDS_MBEDX509_LIB): $(call friends_mbed_objs,$(FRIENDS_MBEDX509_NAMES))
$(FRIENDS_MBEDTLS_LIB): $(call friends_mbed_objs,$(FRIENDS_MBEDTLS_NAMES))
$(FRIENDS_SCTP_LIB): $(FRIENDS_SCTP_OBJS)
$(FRIENDS_JUICE_LIB): $(FRIENDS_JUICE_OBJS)
$(FRIENDS_DC_LIB): $(FRIENDS_DC_OBJS)
$(FRIENDS_DATACHANNEL_LIBS):
	@rm -f "$@"
	libtool -static -D -no_warning_for_no_symbols -o "$@" $^

.PHONY: friends-datachannel
friends-datachannel: $(FRIENDS_DATACHANNEL_LIBS)

# --- Checks --------------------------------------------------------------------------------------------------------
# The link test is a C99 program using only rtc.h (and Mbed TLS's version call), linked the way the app links:
# -dead_strip and -Wl,-x. Under the warning flags of FRIENDS_C_FLAGS (friends.mk), spelled out so this file also
# works on its own, so a public header that needs a GNU dialect fails here. check-datachannel.sh runs it (two peers
# exchange a message over 127.0.0.1), inspects it and the archives, and rebuilds every archive from scratch in a
# second build directory to compare the two byte for byte.
FRIENDS_DC_TEST := $(FRIENDS_DC_BUILD)/SZFriendsDataChannelLinkTest
FRIENDS_DC_TEST_SRC := friends/deps/tests/SZFriendsDataChannelLinkTest.c
FRIENDS_DC_TEST_SCRIPT := friends/deps/tests/check-datachannel.sh

$(FRIENDS_DC_TEST): $(FRIENDS_DC_TEST_SRC) $(FRIENDS_DATACHANNEL_LIBS) friends/deps/datachannel.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c99 -Wall -Wextra -Werror -pedantic \
		$(FRIENDS_DATACHANNEL_CFLAGS) $(FRIENDS_MBEDTLS_CFLAGS) "$(FRIENDS_DC_TEST_SRC)" \
		$(FRIENDS_DATACHANNEL_LIBS) $(FRIENDS_DATACHANNEL_LDFLAGS) -Wl,-dead_strip -Wl,-x -o "$@"

# The rebuild gets the variables that shape the objects, and no MAKEFLAGS: it runs at its own job count.
ifeq ($(UNAME_S),Darwin)
FRIENDS_TEST_TARGETS += friends-datachannel-check
endif
.PHONY: friends-datachannel-check
friends-datachannel-check: $(FRIENDS_DC_TEST) $(FRIENDS_DC_TEST_SCRIPT)
	env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL "$(FRIENDS_DC_TEST_SCRIPT)" "$(FRIENDS_DC_TEST)" "$(FRIENDS_DC_BUILD)" \
		"$(MAKE)" "MAC_ARCH=$(MAC_ARCH)" "MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET)" \
		"PORTABLE_OPTFLAGS=$(PORTABLE_OPTFLAGS)"

endif
