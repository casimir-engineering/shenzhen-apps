# Shenzhen Friends identity area: key stores, the identity keys, the Friends ID word list, codec and ID states, and
# the device chain that lets one person's several computers speak for them (ADR 0012).
# Owner: identity. Included by friends/friends.mk; make runs with cwd portable/, so paths are relative to it.

FRIENDS_IDENTITY_DIR := friends/service/identity
FRIENDS_IDENTITY_BUILD := $(FRIENDS_BUILD)/identity
FRIENDS_IDENTITY_SRCS := $(sort $(wildcard $(FRIENDS_IDENTITY_DIR)/*.m))
FRIENDS_IDENTITY_HDRS := $(wildcard $(FRIENDS_IDENTITY_DIR)/*.h)
FRIENDS_IDENTITY_WORDS := $(FRIENDS_IDENTITY_DIR)/wordlist/friends-id-words-v1.txt
FRIENDS_IDENTITY_WORDS_C := $(FRIENDS_IDENTITY_BUILD)/SZFriendsWordListData.c
FRIENDS_IDENTITY_WORDS_O := $(FRIENDS_IDENTITY_BUILD)/SZFriendsWordListData.o
FRIENDS_IDENTITY_OBJS := \
	$(patsubst $(FRIENDS_IDENTITY_DIR)/%.m,$(FRIENDS_IDENTITY_BUILD)/%.o,$(FRIENDS_IDENTITY_SRCS)) \
	$(FRIENDS_IDENTITY_WORDS_O)
# Security for the Keychain store; LocalAuthentication for the LAContext that keeps its reads from prompting.
FRIENDS_IDENTITY_LIBS := -framework Security -framework LocalAuthentication

FRIENDS_SERVICE_OBJS += $(FRIENDS_IDENTITY_OBJS)
FRIENDS_PUBLIC_HEADERS += $(FRIENDS_IDENTITY_DIR)/SZFriendsDeviceChain.h $(FRIENDS_IDENTITY_DIR)/SZFriendsCPace.h \
	$(FRIENDS_IDENTITY_DIR)/SZFriendsJoin.h
FRIENDS_SERVICE_LIBS += $(FRIENDS_IDENTITY_LIBS)

# libsodium's headers only; the archive is linked by whoever links these objects (the helper, the tests).
$(FRIENDS_IDENTITY_BUILD)/%.o: $(FRIENDS_IDENTITY_DIR)/%.m $(FRIENDS_IDENTITY_HDRS) friends/service/identity/identity.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -c "$<" -o "$@"

# The word list is compiled into the helper (wordlist/embed.sh says why); the generated C lives in the build tree.
$(FRIENDS_IDENTITY_WORDS_C): $(FRIENDS_IDENTITY_WORDS) $(FRIENDS_IDENTITY_DIR)/wordlist/embed.sh
	@mkdir -p "$(@D)"
	sh $(FRIENDS_IDENTITY_DIR)/wordlist/embed.sh "$(FRIENDS_IDENTITY_WORDS)" "$@" szfriends_word_list_v1

$(FRIENDS_IDENTITY_WORDS_O): $(FRIENDS_IDENTITY_WORDS_C)
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_C_FLAGS) -c "$<" -o "$@"

# One executable per test file, each printing "<Name> passed". Compiled on every run inside the phony target,
# because make skips a rebuild when source and binary share an mtime second. They link the production objects,
# built with the app's optimisation as the helper uses them. No test touches the real Keychain (the Keychain store
# is driven through a fake of its Security calls) or the network.
FRIENDS_IDENTITY_TESTS := SZFriendsKeyStoreTests SZFriendsIdentityTests SZFriendsWordListTests SZFriendsIDTests \
	SZFriendsDeviceChainTests SZFriendsDeviceChainPropertyTests SZFriendsCPaceTests \
	SZFriendsJoinTests SZFriendsJoinLimitTests

FRIENDS_TEST_TARGETS += friends-identity-check
.PHONY: friends-identity-check
friends-identity-check: $(FRIENDS_IDENTITY_OBJS) $(FRIENDS_SODIUM_LIB)
	@mkdir -p "$(FRIENDS_IDENTITY_BUILD)"
	@for test in $(FRIENDS_IDENTITY_TESTS); do rm -f "$(FRIENDS_IDENTITY_BUILD)/$$test"; done
	@for test in $(FRIENDS_IDENTITY_TESTS); do \
		echo "clang ... $(FRIENDS_IDENTITY_DIR)/tests/$$test.m -o $(FRIENDS_IDENTITY_BUILD)/$$test"; \
		clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) \
			"$(FRIENDS_IDENTITY_DIR)/tests/$$test.m" $(FRIENDS_IDENTITY_OBJS) $(FRIENDS_SODIUM_LIB) \
			-framework Foundation $(FRIENDS_IDENTITY_LIBS) -o "$(FRIENDS_IDENTITY_BUILD)/$$test" || exit 1; \
	done
	"$(FRIENDS_IDENTITY_BUILD)/SZFriendsKeyStoreTests"
	"$(FRIENDS_IDENTITY_BUILD)/SZFriendsIdentityTests"
	"$(FRIENDS_IDENTITY_BUILD)/SZFriendsWordListTests" "$(FRIENDS_IDENTITY_WORDS)"
	"$(FRIENDS_IDENTITY_BUILD)/SZFriendsIDTests"
	"$(FRIENDS_IDENTITY_BUILD)/SZFriendsDeviceChainTests"
	"$(FRIENDS_IDENTITY_BUILD)/SZFriendsDeviceChainPropertyTests"
	"$(FRIENDS_IDENTITY_BUILD)/SZFriendsCPaceTests"
	"$(FRIENDS_IDENTITY_BUILD)/SZFriendsJoinTests"
	"$(FRIENDS_IDENTITY_BUILD)/SZFriendsJoinLimitTests"
