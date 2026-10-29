# Shenzhen Friends fast transfers (ADR 0018): block geometry, the BLAKE3 tree, block sets and ranges, sidecars, and
# the receiver's and sender's block logic, shared by the store and the helper. Included by friends/friends.mk; make
# runs with cwd portable/.

FRIENDS_TRANSFER_DIR := friends/service/transfer
FRIENDS_TRANSFER_BUILD := $(FRIENDS_BUILD)/transfer
FRIENDS_TRANSFER_SRCS := $(sort $(wildcard $(FRIENDS_TRANSFER_DIR)/*.m))
FRIENDS_TRANSFER_OBJS := $(patsubst $(FRIENDS_TRANSFER_DIR)/%.m,$(FRIENDS_TRANSFER_BUILD)/%.o,$(FRIENDS_TRANSFER_SRCS))
FRIENDS_TRANSFER_HDRS := $(wildcard $(FRIENDS_TRANSFER_DIR)/*.h) $(wildcard friends/service/session/*.h)

FRIENDS_SERVICE_OBJS += $(FRIENDS_TRANSFER_OBJS)
# The archive is linked like a system library by everything that links the service objects; listing it as each
# object's prerequisite is what builds it first.
FRIENDS_SERVICE_LIBS += $(FRIENDS_BLAKE3_LIB)

$(FRIENDS_TRANSFER_BUILD)/%.o: $(FRIENDS_TRANSFER_DIR)/%.m $(FRIENDS_TRANSFER_HDRS) $(FRIENDS_BLAKE3_LIB) \
		friends/service/transfer/transfer.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) $(FRIENDS_BLAKE3_CFLAGS) -c "$<" -o "$@"

# The scheduler's scenario table through the simulator (tests/), the lane group's rules, and the Wi-Fi Direct boost
# against the shared vectors and a mocked Wi-Fi (ADR 0019). Compiled on every run.
FRIENDS_TRANSFER_TEST := $(FRIENDS_TRANSFER_BUILD)/SZFriendsTransferTests
FRIENDS_TEST_TARGETS += friends-transfer-check
.PHONY: friends-transfer-check
friends-transfer-check: $(FRIENDS_SODIUM_LIB) $(FRIENDS_BLAKE3_LIB)
	@mkdir -p "$(FRIENDS_TRANSFER_BUILD)"
	@rm -f "$(FRIENDS_TRANSFER_TEST)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) $(FRIENDS_BLAKE3_CFLAGS) \
		-I$(FRIENDS_TRANSFER_DIR)/tests $(wildcard $(FRIENDS_TRANSFER_DIR)/tests/*.m) \
		$(FRIENDS_TRANSFER_DIR)/SZFriendsScheduler.m "$(FRIENDS_TRANSFER_DIR)/SZFriendsScheduler+Decisions.m" \
		$(FRIENDS_TRANSFER_DIR)/SZFriendsLaneGroup.m \
		$(FRIENDS_TRANSFER_DIR)/SZFriendsPull.m $(FRIENDS_TRANSFER_DIR)/SZFriendsBlockFlow.m \
		$(FRIENDS_TRANSFER_DIR)/SZFriendsTransferBlocks.m $(FRIENDS_TRANSFER_DIR)/SZFriendsBlockSidecars.m \
		friends/service/session/SZFriendsSessionLimits.m \
		$(FRIENDS_TRANSFER_DIR)/SZFriendsDirectWiFiBoost.m $(FRIENDS_TRANSFER_DIR)/SZFriendsDirectWiFiCoordinator.m \
		$(FRIENDS_TRANSFER_DIR)/SZFriendsDirectWiFiRejoin.m \
		friends/service/session/SZFriendsFrame.m friends/service/session/SZFriendsFrameSchema.m \
		$(FRIENDS_SODIUM_LIB) $(FRIENDS_BLAKE3_LIB) -framework Foundation -o "$(FRIENDS_TRANSFER_TEST)"
	"$(FRIENDS_TRANSFER_TEST)" friends/fixtures/scheduler/scenarios.json
