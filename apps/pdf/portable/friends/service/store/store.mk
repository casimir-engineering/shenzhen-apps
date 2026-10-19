# Shenzhen Friends store area: friends.sqlite (people, history, search), the outbox and transfers.
# Owner: store. Included by friends/friends.mk; make runs with cwd portable/, so paths are relative to it.

FRIENDS_STORE_DIR := friends/service/store
FRIENDS_STORE_BUILD := $(FRIENDS_BUILD)/store
FRIENDS_STORE_SRCS := $(sort $(wildcard $(FRIENDS_STORE_DIR)/*.m))
FRIENDS_STORE_OBJS := $(patsubst $(FRIENDS_STORE_DIR)/%.m,$(FRIENDS_STORE_BUILD)/%.o,$(FRIENDS_STORE_SRCS))
# The identity header: a static-key change is accepted only with a certificate the identity area verifies. The
# mention form: search indexes each mention as the label a reader sees, never its ID or key (ADR 0007).
FRIENDS_STORE_HDRS := $(wildcard $(FRIENDS_STORE_DIR)/*.h) friends/avatars/SZFriendsAvatars.h \
	friends/service/identity/SZFriendsIdentity.h friends/service/presentation/SZFriendsMentions.h
FRIENDS_STORE_MENTIONS_OBJ := $(FRIENDS_BUILD)/presentation/SZFriendsMentions.o
# System libraries only: SQLite costs no binary size (ADR 0003); UniformTypeIdentifiers names offered file types.
FRIENDS_STORE_LIBS := -lsqlite3 -framework UniformTypeIdentifiers

FRIENDS_SERVICE_OBJS += $(FRIENDS_STORE_OBJS)
FRIENDS_PUBLIC_HEADERS += $(FRIENDS_STORE_DIR)/SZFriendsStoreDevices.h $(FRIENDS_STORE_DIR)/SZFriendsStoreSync.h
FRIENDS_SERVICE_LIBS += $(FRIENDS_STORE_LIBS)

# libsodium's headers for BLAKE2b; the archive is linked by whoever links these objects (the helper, the tests).
$(FRIENDS_STORE_BUILD)/%.o: $(FRIENDS_STORE_DIR)/%.m $(FRIENDS_STORE_HDRS) friends/service/store/store.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -c "$<" -o "$@"

# The suite links the production objects (built with the app's optimisation, as the helper will use them), the
# identity area's objects (certificate checks, and real certificates for the tests), the mention form's object and a
# test-only stand-in for SZFriendsPicture, so it does not depend on the avatars area's build. It is compiled on every
# run inside the phony target: make skips a rebuild when source and binary share an mtime second.
FRIENDS_STORE_TEST := $(FRIENDS_STORE_BUILD)/SZFriendsStoreTests
FRIENDS_STORE_TEST_SRCS := $(sort $(wildcard $(FRIENDS_STORE_DIR)/tests/*.m))

FRIENDS_STORE_TEST_LINK = clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) \
	$(FRIENDS_STORE_TEST_SRCS) $(FRIENDS_STORE_OBJS) $(FRIENDS_STORE_MENTIONS_OBJ) $(FRIENDS_IDENTITY_OBJS) \
	$(FRIENDS_SODIUM_LIB) -framework Foundation $(FRIENDS_STORE_LIBS) $(FRIENDS_IDENTITY_LIBS) \
	-o "$(FRIENDS_STORE_TEST)"

FRIENDS_TEST_TARGETS += friends-store-check
.PHONY: friends-store-check friends-store-v1-fixture
friends-store-check: $(FRIENDS_STORE_OBJS) $(FRIENDS_STORE_MENTIONS_OBJ) $$(FRIENDS_IDENTITY_OBJS) $(FRIENDS_SODIUM_LIB)
	@mkdir -p "$(FRIENDS_STORE_BUILD)"
	@rm -f "$(FRIENDS_STORE_TEST)"
	$(FRIENDS_STORE_TEST_LINK)
	"$(FRIENDS_STORE_TEST)" "$(FRIENDS_STORE_DIR)/tests/fixtures"

# Regenerated the committed v1 fixture while v1 was the newest schema. Schema v2 exists now, so store-v1.sql is the
# record of what v1 helpers wrote and never changes again: the generator refuses and says so.
friends-store-v1-fixture: $(FRIENDS_STORE_OBJS) $(FRIENDS_STORE_MENTIONS_OBJ) $$(FRIENDS_IDENTITY_OBJS) \
		$(FRIENDS_SODIUM_LIB)
	@mkdir -p "$(FRIENDS_STORE_BUILD)"
	@rm -f "$(FRIENDS_STORE_TEST)"
	$(FRIENDS_STORE_TEST_LINK)
	"$(FRIENDS_STORE_TEST)" --write-v1-fixture "$(FRIENDS_STORE_DIR)/tests/fixtures/store-v1.sql"
