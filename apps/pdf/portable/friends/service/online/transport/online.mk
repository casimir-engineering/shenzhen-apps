# Shenzhen Friends online transport (owner: online transport area): SZFriendsOnlineTransport over libdatachannel
# (ADR 0009), in friends/service/online/transport/, and the suite for it and for the frozen header's contract.
# Included by friends/friends.mk through its own line (the area-makefile wildcard reaches three levels down); make
# runs with cwd portable/, so every path is relative to it.
#
# The objects join FRIENDS_SERVICE_OBJS, and what linking them takes joins FRIENDS_SERVICE_LIBS, so the helper and
# every program that links the service areas carry the stack. Suite: friends-online-check.

# Guarded: the stack's variables must be set before the rules below read them.
include friends/deps/datachannel.mk

FRIENDS_ONLINE_DIR := friends/service/online
FRIENDS_ONLINE_TRANSPORT_DIR := $(FRIENDS_ONLINE_DIR)/transport
FRIENDS_ONLINE_BUILD := $(FRIENDS_BUILD)/online
FRIENDS_ONLINE_TRANSPORT_SRCS := $(sort $(wildcard $(FRIENDS_ONLINE_TRANSPORT_DIR)/*.m))
FRIENDS_ONLINE_TRANSPORT_HDRS := $(sort $(wildcard $(FRIENDS_ONLINE_TRANSPORT_DIR)/*.h)) \
	$(FRIENDS_ONLINE_DIR)/SZFriendsOnlineTransport.h friends/service/session/SZFriendsSession.h \
	friends/service/discovery/SZFriendsDiscovery.h
FRIENDS_ONLINE_TRANSPORT_OBJS := $(patsubst $(FRIENDS_ONLINE_TRANSPORT_DIR)/%.m,$(FRIENDS_ONLINE_BUILD)/transport/%.o,\
	$(FRIENDS_ONLINE_TRANSPORT_SRCS))
FRIENDS_ONLINE_CFLAGS = $(FRIENDS_OBJC_FLAGS) $(FRIENDS_DATACHANNEL_CFLAGS)
# What a program linking the transport adds: the stack's six archives, libc++ (libdatachannel is C++17), and
# usrsctp's own timingsafe_bcmp kept out of the export table (macOS declares that name with default visibility, so
# -fvisibility=hidden leaves it exported; friends/deps/datachannel.mk).
FRIENDS_ONLINE_LINK := $(FRIENDS_DATACHANNEL_LIBS) $(FRIENDS_DATACHANNEL_LDFLAGS) \
	-Wl,-unexported_symbol,_timingsafe_bcmp

FRIENDS_SERVICE_OBJS += $(FRIENDS_ONLINE_TRANSPORT_OBJS)
FRIENDS_SERVICE_LIBS += $(FRIENDS_ONLINE_LINK)
FRIENDS_PUBLIC_HEADERS += $(FRIENDS_ONLINE_DIR)/SZFriendsOnlineTransport.h \
	$(FRIENDS_ONLINE_TRANSPORT_DIR)/SZFriendsOnlineDataChannelTransport.h

# Order-only on the archives: whoever builds the service objects (the helper, the e2e runner) then has them to link.
$(FRIENDS_ONLINE_BUILD)/transport/%.o: $(FRIENDS_ONLINE_TRANSPORT_DIR)/%.m $(FRIENDS_ONLINE_TRANSPORT_HDRS) \
		$(FRIENDS_ONLINE_TRANSPORT_DIR)/online.mk | $(FRIENDS_DATACHANNEL_LIBS)
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_ONLINE_CFLAGS) -c "$<" -o "$@"

# The suite compiles the transport again inside its phony target, with AddressSanitizer and UndefinedBehavior-
# Sanitizer over the parsers that read a remote party's descriptions and candidates, and links the session and
# identity areas' objects for ADR 0001's real secure channel over the data channel. The relay scenario needs a
# coturn built from pinned source (server/friends/README.md § Testing), named by FRIENDS_TEST_COTURN; without it
# that scenario skips and says so. Everything stays on loopback.
FRIENDS_ONLINE_TEST_DIR := $(FRIENDS_ONLINE_TRANSPORT_DIR)/tests
FRIENDS_ONLINE_TEST_SRCS = $(sort $(wildcard $(FRIENDS_ONLINE_TEST_DIR)/*.m))
FRIENDS_ONLINE_TEST := $(FRIENDS_ONLINE_BUILD)/SZFriendsOnlineTransportTests
FRIENDS_ONLINE_CONTRACT_TEST := $(FRIENDS_ONLINE_BUILD)/SZFriendsOnlineTransportContractTests
FRIENDS_ONLINE_SANITIZE := -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer

ifeq ($(UNAME_S),Darwin)
FRIENDS_TEST_TARGETS += friends-online-check
endif
.PHONY: friends-online-check
friends-online-check: $(FRIENDS_DATACHANNEL_LIBS) $(FRIENDS_SODIUM_LIB) $$(FRIENDS_SESSION_OBJS) \
		$$(FRIENDS_IDENTITY_OBJS)
	@mkdir -p "$(FRIENDS_ONLINE_BUILD)"
	@rm -f "$(FRIENDS_ONLINE_TEST)" "$(FRIENDS_ONLINE_CONTRACT_TEST)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) \
		$(FRIENDS_ONLINE_DIR)/tests/SZFriendsOnlineTransportContractTests.m -framework Foundation \
		-o "$(FRIENDS_ONLINE_CONTRACT_TEST)"
	"$(FRIENDS_ONLINE_CONTRACT_TEST)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_ONLINE_CFLAGS) $(FRIENDS_SODIUM_CFLAGS) $(FRIENDS_ONLINE_SANITIZE) \
		-I$(FRIENDS_ONLINE_TEST_DIR) $(FRIENDS_ONLINE_TRANSPORT_SRCS) $(FRIENDS_ONLINE_TEST_SRCS) \
		$(FRIENDS_SESSION_OBJS) $(FRIENDS_IDENTITY_OBJS) $(FRIENDS_SODIUM_LIB) $(FRIENDS_ONLINE_LINK) \
		-framework Foundation -framework Security -framework LocalAuthentication -o "$(FRIENDS_ONLINE_TEST)"
	"$(FRIENDS_ONLINE_TEST)"
