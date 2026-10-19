# Shenzhen Friends NAT techniques (ADR 0011; owner: NAT techniques): PCP and NAT-PMP, UPnP IGD through miniupnpc
# 2.3.3 (ext/miniupnpc/), the two-port STUN classifier, port prediction, hard-NAT probing and TCP simultaneous open.
# Included by friends/friends.mk through its own line, as transport/online.mk is (the area-makefile wildcard stops
# three directories down); guarded, so a second include is harmless. Make runs with cwd portable/.
#
# The objects join FRIENDS_SERVICE_OBJS and libminiupnpc.a joins FRIENDS_SERVICE_LIBS, as the transport's do, so the
# helper and every program linking the service areas carry the techniques (the transport's side-path factory hands
# out SZFriendsNATTCPSidePath). FRIENDS_NAT_CFLAGS is only for code that includes miniupnpc itself.

ifndef FRIENDS_NAT_MK_INCLUDED
FRIENDS_NAT_MK_INCLUDED := 1

FRIENDS_NAT_DIR := friends/service/online/nat
FRIENDS_NAT_BUILD := $(FRIENDS_BUILD)/online/nat
FRIENDS_UPNP_DIR := ../ext/miniupnpc

# --- miniupnpc 2.3.3 -----------------------------------------------------------------------------------------------
# The library sources of upstream's Makefile (LIBOBJS) with its macros for a BSD-like system. The test, example and
# Python-module sources under src/ are never built. miniupnpcstrings.h, which upstream's Makefile generates, is
# written into the build tree from the vendored .h.in, so ext/ stays unmodified; its OS string is "Darwin" with no
# version, so the User-Agent miniupnpc sends to the router says no more than that.
FRIENDS_UPNP_NAMES := addr_is_reserved connecthostport igd_desc_parse minisoap minissdpc miniupnpc miniwget minixml \
	portlistingparse receivedata upnpcommands upnpdev upnperrors upnpreplyparse
FRIENDS_UPNP_HDRS := $(sort $(wildcard $(FRIENDS_UPNP_DIR)/include/*.h $(FRIENDS_UPNP_DIR)/src/*.h))
FRIENDS_UPNP_GENERATED := $(FRIENDS_NAT_BUILD)/miniupnpc-include
FRIENDS_UPNP_STRINGS := $(FRIENDS_UPNP_GENERATED)/miniupnpcstrings.h
FRIENDS_UPNP_CONFIG := -DMINIUPNPC_SET_SOCKET_TIMEOUT -DMINIUPNPC_GET_SRC_ADDR -D_BSD_SOURCE -D_DEFAULT_SOURCE \
	-D_XOPEN_SOURCE=600 -D_DARWIN_C_SOURCE
FRIENDS_NAT_CFLAGS := -I$(FRIENDS_UPNP_DIR)/include -I$(FRIENDS_UPNP_DIR)/src
FRIENDS_UPNP_BUILD_FLAGS = $(MAC_TARGET_FLAGS) -fvisibility=hidden -fno-common -Wall -W -Wstrict-prototypes \
	$(FRIENDS_UPNP_CONFIG) $(FRIENDS_NAT_CFLAGS) -I$(FRIENDS_UPNP_GENERATED)
FRIENDS_UPNP_SRCS := $(patsubst %,$(FRIENDS_UPNP_DIR)/src/%.c,$(FRIENDS_UPNP_NAMES))
FRIENDS_UPNP_OBJS := $(patsubst %,$(FRIENDS_NAT_BUILD)/miniupnpc/%.o,$(FRIENDS_UPNP_NAMES))
FRIENDS_UPNP_LIB := $(FRIENDS_NAT_BUILD)/libminiupnpc.a

$(FRIENDS_UPNP_STRINGS): $(FRIENDS_UPNP_DIR)/miniupnpcstrings.h.in $(FRIENDS_UPNP_DIR)/VERSION $(FRIENDS_NAT_DIR)/nat.mk
	@mkdir -p "$(@D)"
	sed -e 's|"OS/version"|"Darwin"|' -e "s|\"version\"|\"$$(cat $(FRIENDS_UPNP_DIR)/VERSION)\"|" "$<" > "$@.tmp"
	mv "$@.tmp" "$@"

$(FRIENDS_NAT_BUILD)/miniupnpc/%.o: $(FRIENDS_UPNP_DIR)/src/%.c $(FRIENDS_UPNP_HDRS) $(FRIENDS_UPNP_STRINGS) \
		$(FRIENDS_NAT_DIR)/nat.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_UPNP_BUILD_FLAGS) -c "$<" -o "$@"

# libtool -static -D, as datachannel.mk: no dates or modes in the archive, so two builds are byte-identical.
$(FRIENDS_UPNP_LIB): $(FRIENDS_UPNP_OBJS)
	@rm -f "$@"
	libtool -static -D -no_warning_for_no_symbols -o "$@" $^

# --- The techniques ------------------------------------------------------------------------------------------------
FRIENDS_NAT_SRCS := $(sort $(wildcard $(FRIENDS_NAT_DIR)/*.m))
FRIENDS_NAT_HDRS := $(sort $(wildcard $(FRIENDS_NAT_DIR)/*.h)) friends/service/online/SZFriendsOnlineTransport.h \
	friends/service/online/transport/SZFriendsOnlineDataChannelTransport.h friends/service/session/SZFriendsSession.h \
	friends/service/discovery/SZFriendsDiscovery.h
FRIENDS_NAT_OBJS := $(patsubst $(FRIENDS_NAT_DIR)/%.m,$(FRIENDS_NAT_BUILD)/%.o,$(FRIENDS_NAT_SRCS))
FRIENDS_NAT_LIBS := $(FRIENDS_UPNP_LIB)
FRIENDS_SERVICE_OBJS += $(FRIENDS_NAT_OBJS)
FRIENDS_SERVICE_LIBS += $(FRIENDS_NAT_LIBS)
FRIENDS_PUBLIC_HEADERS += $(addprefix $(FRIENDS_NAT_DIR)/,SZFriendsNAT.h SZFriendsNATStun.h SZFriendsNATPCP.h \
	SZFriendsNATRoute.h SZFriendsNATPortMapping.h SZFriendsNATUPnP.h SZFriendsNATClassifier.h \
	SZFriendsNATPrediction.h SZFriendsNATProber.h SZFriendsNATSocketStream.h SZFriendsNATTCPPath.h \
	SZFriendsNATTCPSidePath.h)

# Order-only on the archive, as the transport does: whoever builds the service objects then has it to link.
$(FRIENDS_NAT_BUILD)/%.o: $(FRIENDS_NAT_DIR)/%.m $(FRIENDS_NAT_HDRS) $(FRIENDS_UPNP_STRINGS) $(FRIENDS_NAT_DIR)/nat.mk \
		| $(FRIENDS_UPNP_LIB)
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_NAT_CFLAGS) -c "$<" -o "$@"

.PHONY: friends-nat friends-nat-gateway-probe
friends-nat: $(FRIENDS_NAT_OBJS) $(FRIENDS_NAT_LIBS)

# By hand only, never in a suite: what this LAN's gateway answers to read-only NAT-PMP, PCP and unicast SSDP
# requests (tools/SZFriendsNATGatewayProbe.m). It maps nothing. GATEWAY is the IPv4 gateway (ipconfig getoption en0
# router), GATEWAY6 optionally the IPv6 router with its interface (fe80::1%en0).
FRIENDS_NAT_PROBE := $(FRIENDS_NAT_BUILD)/SZFriendsNATGatewayProbe
friends-nat-gateway-probe:
	@test -n "$(GATEWAY)" || { echo "usage: make friends-nat-gateway-probe GATEWAY=<ip> [GATEWAY6=<ip%if>]" >&2; exit 2; }
	@mkdir -p "$(FRIENDS_NAT_BUILD)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_NAT_DIR)/tools/SZFriendsNATGatewayProbe.m \
		$(addprefix $(FRIENDS_NAT_DIR)/,SZFriendsNATExchange.m SZFriendsNATPCP.m SZFriendsNATRoute.m \
		SZFriendsNATEndpoint.m) -framework Foundation -o "$(FRIENDS_NAT_PROBE)"
	"$(FRIENDS_NAT_PROBE)" "$(GATEWAY)" "$(GATEWAY6)"

include $(FRIENDS_NAT_DIR)/fuzz/fuzz.mk

# --- Suite ---------------------------------------------------------------------------------------------------------
# One test binary, compiled inside the phony target on every run (make skips a rebuild when source and binary share
# an mtime second), with the techniques and miniupnpc's sources under AddressSanitizer and UndefinedBehaviorSanitizer:
# both parse bytes from the network. Every test talks to loopback only: scripted gateways, STUN servers, an IGD and
# a peer inside the test, the host's own STUN responder (when Node.js is on PATH), and the read-only routing table.
# It also links libjuice (the probe handover), and the session and identity objects with libsodium (Noise over the
# TCP path). Then the fuzz corpus replays through every fuzz target under the sanitizers.
FRIENDS_NAT_SANITIZE := -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer
FRIENDS_NAT_TEST := $(FRIENDS_NAT_BUILD)/SZFriendsNATTests
FRIENDS_NAT_TEST_OBJS := $(FRIENDS_NAT_BUILD)/test-objs
FRIENDS_NAT_TEST_SRCS = $(sort $(wildcard $(FRIENDS_NAT_DIR)/tests/*.m))
FRIENDS_NAT_TEST_LIBS = -framework Foundation -framework Security -framework LocalAuthentication

FRIENDS_TEST_TARGETS += friends-nat-check
.PHONY: friends-nat-check
friends-nat-check: $(FRIENDS_UPNP_STRINGS) $$(FRIENDS_SESSION_OBJS) $$(FRIENDS_IDENTITY_OBJS) $(FRIENDS_SODIUM_LIB) \
		$$(FRIENDS_JUICE_LIB)
	@mkdir -p "$(FRIENDS_NAT_TEST_OBJS)"
	@rm -f "$(FRIENDS_NAT_TEST)" "$(FRIENDS_NAT_TEST_OBJS)"/*.o
	for name in $(FRIENDS_UPNP_NAMES); do \
		clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_UPNP_BUILD_FLAGS) $(FRIENDS_NAT_SANITIZE) \
			-c "$(FRIENDS_UPNP_DIR)/src/$$name.c" -o "$(FRIENDS_NAT_TEST_OBJS)/upnp-$$name.o" || exit 1; \
	done
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_NAT_CFLAGS) $(FRIENDS_SODIUM_CFLAGS) \
		$(FRIENDS_DC_JUICE_CFLAGS) $(FRIENDS_NAT_SANITIZE) -I$(FRIENDS_NAT_DIR)/tests $(FRIENDS_NAT_SRCS) \
		$(FRIENDS_NAT_TEST_SRCS) "$(FRIENDS_NAT_TEST_OBJS)"/upnp-*.o $(FRIENDS_SESSION_OBJS) $(FRIENDS_IDENTITY_OBJS) \
		$(FRIENDS_SODIUM_LIB) $(FRIENDS_JUICE_LIB) $(FRIENDS_NAT_TEST_LIBS) -o "$(FRIENDS_NAT_TEST)"
	"$(FRIENDS_NAT_TEST)" server/friends
	$(FRIENDS_NAT_FUZZ_REPLAY)

endif
