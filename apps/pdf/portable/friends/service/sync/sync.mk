# Shenzhen Friends sync area: one person's devices keep the same chats, friends and settings (friends-multi-device.md
# § Sync). Owner: sync. Included by friends/friends.mk; make runs with cwd portable/, so paths are relative to it.
#
# The engine reaches SQLite only through the store's headers (SZFriendsStoreSync.h); the suite runs three real stores
# in temporary directories, never the person's state directory, the Keychain or the network.

FRIENDS_SYNC_DIR := friends/service/sync
FRIENDS_SYNC_BUILD := $(FRIENDS_BUILD)/sync
FRIENDS_SYNC_SRCS := $(sort $(wildcard $(FRIENDS_SYNC_DIR)/*.m))
FRIENDS_SYNC_OBJS := $(patsubst $(FRIENDS_SYNC_DIR)/%.m,$(FRIENDS_SYNC_BUILD)/%.o,$(FRIENDS_SYNC_SRCS))
FRIENDS_SYNC_HDRS := $(wildcard $(FRIENDS_SYNC_DIR)/*.h) $(wildcard friends/service/store/*.h) \
	$(wildcard friends/service/identity/*.h) friends/avatars/SZFriendsAvatars.h

FRIENDS_SERVICE_OBJS += $(FRIENDS_SYNC_OBJS)
FRIENDS_PUBLIC_HEADERS += $(FRIENDS_SYNC_DIR)/SZFriendsSync.h $(FRIENDS_SYNC_DIR)/SZFriendsAgain.h

$(FRIENDS_SYNC_BUILD)/%.o: $(FRIENDS_SYNC_DIR)/%.m $(FRIENDS_SYNC_HDRS) friends/service/sync/sync.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -c "$<" -o "$@"

# The suite links the production objects with the store's and identity's (and the store suite's stand-in for
# SZFriendsPicture, so it does not depend on the avatars area's build). Compiled on every run inside the phony target:
# make skips a rebuild when source and binary share an mtime second.
FRIENDS_SYNC_TEST := $(FRIENDS_SYNC_BUILD)/SZFriendsSyncTests
FRIENDS_SYNC_TEST_SRCS := $(sort $(wildcard $(FRIENDS_SYNC_DIR)/tests/*.m)) \
	friends/service/store/tests/SZFriendsStoreFakePicture.m

FRIENDS_TEST_TARGETS += friends-sync-check
.PHONY: friends-sync-check
friends-sync-check: $(FRIENDS_SYNC_OBJS) $$(FRIENDS_STORE_OBJS) $$(FRIENDS_STORE_MENTIONS_OBJ) \
		$$(FRIENDS_IDENTITY_OBJS) $(FRIENDS_SODIUM_LIB)
	@mkdir -p "$(FRIENDS_SYNC_BUILD)"
	@rm -f "$(FRIENDS_SYNC_TEST)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) $(FRIENDS_SYNC_TEST_SRCS) \
		$(FRIENDS_SYNC_OBJS) $(FRIENDS_STORE_OBJS) $(FRIENDS_STORE_MENTIONS_OBJ) $(FRIENDS_IDENTITY_OBJS) \
		$(FRIENDS_SODIUM_LIB) -framework Foundation $(FRIENDS_STORE_LIBS) $(FRIENDS_IDENTITY_LIBS) \
		-o "$(FRIENDS_SYNC_TEST)"
	"$(FRIENDS_SYNC_TEST)"
