# Shenzhen Friends sessions: the Noise state machine (C over libsodium), the frame codec, the secure channel,
# comparison codes and file-chunk flow (ADR 0001), and the online signalling payloads (ADR 0010). Included by
# friends/friends.mk; make runs with cwd portable/.

FRIENDS_SESSION_DIR := friends/service/session
FRIENDS_SESSION_BUILD := $(FRIENDS_BUILD)/session

# C where ADR 0001 calls for it (the Noise state machine), C99 like the client library; Objective-C for the rest.
FRIENDS_SESSION_C_SRCS := $(FRIENDS_SESSION_DIR)/szfriends_noise_symmetric.c \
	$(FRIENDS_SESSION_DIR)/szfriends_noise_handshake.c
FRIENDS_SESSION_M_SRCS := $(addprefix $(FRIENDS_SESSION_DIR)/,SZFriendsSessionLimits.m SZFriendsFrameSchema.m \
	SZFriendsFrame.m SZFriendsHandshakePayload.m SZFriendsSecureChannel.m SZFriendsSecureChannel+Handshake.m \
	SZFriendsSecureChannel+Transport.m SZFriendsSecureChannel+Code.m SZFriendsChunkFlow.m SZFriendsRequestByID.m \
	SZFriendsReplayCache.m SZFriendsSignaling.m SZFriendsSignalingNoise.m SZFriendsSignalingRecord.m \
	SZFriendsSignalingLink.m)
FRIENDS_SESSION_HDRS := $(wildcard $(FRIENDS_SESSION_DIR)/*.h) friends/service/identity/SZFriendsIdentity.h \
	friends/service/discovery/SZFriendsDiscovery.h friends/service/online/SZFriendsOnlineTransport.h
FRIENDS_SESSION_OBJS := $(patsubst $(FRIENDS_SESSION_DIR)/%.c,$(FRIENDS_SESSION_BUILD)/%.o,$(FRIENDS_SESSION_C_SRCS)) \
	$(patsubst $(FRIENDS_SESSION_DIR)/%.m,$(FRIENDS_SESSION_BUILD)/%.o,$(FRIENDS_SESSION_M_SRCS))

# Production objects for the helper. They call SZFriendsIdentityKeyFromCertificate and SZFriendsIdentity from the
# identity area, which the helper links; libsodium comes from FRIENDS_SODIUM_LIB.
FRIENDS_SERVICE_OBJS += $(FRIENDS_SESSION_OBJS)
# The online signalling payloads (IK and NN over the host, sealed rendezvous records, link openings): the session
# area's second public interface.
FRIENDS_PUBLIC_HEADERS += $(FRIENDS_SESSION_DIR)/SZFriendsSignaling.h

$(FRIENDS_SESSION_BUILD)/%.o: $(FRIENDS_SESSION_DIR)/%.c $(FRIENDS_SESSION_HDRS) $(FRIENDS_SESSION_DIR)/session.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_C_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -c "$<" -o "$@"

$(FRIENDS_SESSION_BUILD)/%.o: $(FRIENDS_SESSION_DIR)/%.m $(FRIENDS_SESSION_HDRS) $(FRIENDS_SESSION_DIR)/session.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -c "$<" -o "$@"

# The suite compiles every source again inside its phony target rather than reusing the objects: make skips a
# rebuild when source and binary share an mtime second (README § Building and testing), and the test build adds
# AddressSanitizer and UndefinedBehaviorSanitizer, which a hand-written Noise implementation should always run
# under. Tests link a fake SZFriendsIdentity (tests/SZFriendsFakeIdentity.m) instead of the identity area.
FRIENDS_SESSION_TEST := $(FRIENDS_SESSION_BUILD)/SZFriendsSessionTests
# The signalling suite is a second binary from tests/signaling/, with the channel suite's support files (fake identity,
# memory streams) but not its tests, so neither suite's main sees the other's cases.
FRIENDS_SIGNALING_TEST := $(FRIENDS_SESSION_BUILD)/SZFriendsSignalingTests
FRIENDS_SIGNALING_TEST_SRCS = $(sort $(wildcard $(FRIENDS_SESSION_DIR)/tests/signaling/*.m)) \
	$(addprefix $(FRIENDS_SESSION_DIR)/tests/,SZFriendsSessionTestSupport.m SZFriendsFakeIdentity.m SZFMemoryStream.m)
FRIENDS_SESSION_TEST_OBJS := $(FRIENDS_SESSION_BUILD)/test-objs
FRIENDS_SESSION_TEST_SRCS = $(sort $(wildcard $(FRIENDS_SESSION_DIR)/tests/*.m))
FRIENDS_SESSION_SANITIZE := -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer

FRIENDS_TEST_TARGETS += friends-session-check
.PHONY: friends-session-check
friends-session-check: $(FRIENDS_SODIUM_LIB)
	@mkdir -p "$(FRIENDS_SESSION_TEST_OBJS)"
	@rm -f "$(FRIENDS_SESSION_TEST)" "$(FRIENDS_SIGNALING_TEST)" "$(FRIENDS_SESSION_TEST_OBJS)"/*.o
	for source in $(FRIENDS_SESSION_C_SRCS); do \
		clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_C_FLAGS) $(FRIENDS_SODIUM_CFLAGS) $(FRIENDS_SESSION_SANITIZE) \
			-c "$$source" -o "$(FRIENDS_SESSION_TEST_OBJS)/$$(basename "$$source" .c).o" || exit 1; \
	done
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) $(FRIENDS_SESSION_SANITIZE) \
		-I$(FRIENDS_SESSION_DIR)/tests $(FRIENDS_SESSION_M_SRCS) $(FRIENDS_SESSION_TEST_SRCS) \
		"$(FRIENDS_SESSION_TEST_OBJS)"/*.o $(FRIENDS_SODIUM_LIB) -framework Foundation -o "$(FRIENDS_SESSION_TEST)"
	"$(FRIENDS_SESSION_TEST)" $(FRIENDS_SESSION_DIR)/tests/vectors
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) $(FRIENDS_SESSION_SANITIZE) \
		-I$(FRIENDS_SESSION_DIR)/tests $(FRIENDS_SESSION_M_SRCS) $(FRIENDS_SIGNALING_TEST_SRCS) \
		"$(FRIENDS_SESSION_TEST_OBJS)"/*.o $(FRIENDS_SODIUM_LIB) -framework Foundation -o "$(FRIENDS_SIGNALING_TEST)"
	"$(FRIENDS_SIGNALING_TEST)"
