# Shenzhen Friends links (owner: helper links area): friend links' invites, and download links made, served and
# received by the helper (SZFriendsLinks.h), in friends/service/links/. Included by friends/friends.mk's area
# wildcard; make runs with cwd portable/, so every path is relative to it. Suite: friends-links-check.

FRIENDS_LINKS_DIR := friends/service/links
FRIENDS_LINKS_BUILD := $(FRIENDS_BUILD)/links
FRIENDS_LINKS_SRCS := $(sort $(wildcard $(FRIENDS_LINKS_DIR)/*.m))
# Everything a link's setup reaches: the online areas', the host's, the store's, the session's and the identity's.
FRIENDS_LINKS_HDRS = $(sort $(wildcard $(FRIENDS_LINKS_DIR)/*.h friends/service/online/*.h \
	friends/service/online/*/*.h friends/service/host/*.h friends/service/store/*.h friends/service/session/*.h \
	friends/service/identity/*.h friends/service/thumbnails/*.h friends/service/discovery/SZFriendsDiscovery.h))
FRIENDS_LINKS_OBJS := $(patsubst $(FRIENDS_LINKS_DIR)/%.m,$(FRIENDS_LINKS_BUILD)/%.o,$(FRIENDS_LINKS_SRCS))

FRIENDS_SERVICE_OBJS += $(FRIENDS_LINKS_OBJS)
FRIENDS_PUBLIC_HEADERS += $(FRIENDS_LINKS_DIR)/SZFriendsLinks.h $(FRIENDS_LINKS_DIR)/SZFriendsLinkWire.h \
	friends/service/store/SZFriendsStoreLinks.h

$(FRIENDS_LINKS_BUILD)/%.o: $(FRIENDS_LINKS_DIR)/%.m $$(FRIENDS_LINKS_HDRS) $(FRIENDS_LINKS_DIR)/links.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -c "$<" -o "$@"

# Two programs, compiled inside the phony target after an rm, so a stale binary never passes:
#   SZFriendsLinksTests      payloads, keys, records, metadata, the file a link holds, the store's tables, and whole
#                            openings over loopback with the real transport, in memory (no host);
#   SZFriendsLinksE2ETests   two real helpers and a browser stand-in through the local Node host and coturn: a guest
#                            downloads directly and through the relay, an app opener receives, revoked, expired and
#                            changed links refused. It needs Node.js and FRIENDS_TEST_COTURN; without either it skips
#                            and says so. Its helper is the production helper's objects with its own main, which sets
#                            the test hooks from files in the state directory.
# The vectors test runs the link pages' own crypto (server/friends/src/pages/script/) under Node, when Node is there.
FRIENDS_LINKS_TEST := $(FRIENDS_LINKS_BUILD)/SZFriendsLinksTests
FRIENDS_LINKS_TEST_SRCS = $(sort $(wildcard $(FRIENDS_LINKS_DIR)/tests/*.m))
FRIENDS_LINKS_E2E := $(FRIENDS_LINKS_BUILD)/SZFriendsLinksE2ETests
FRIENDS_LINKS_E2E_HELPER := $(FRIENDS_LINKS_BUILD)/szfriends-links-e2e-helper
FRIENDS_LINKS_E2E_SRCS = $(sort $(wildcard $(FRIENDS_LINKS_DIR)/tests/e2e/SZFriendsLinksE2E*.m)) \
	friends/tests/e2e/SZFriendsE2EOnlineHost.m friends/tests/e2e/SZFriendsE2EHarness.m
FRIENDS_LINKS_TEST_FLAGS = $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) \
	-I$(FRIENDS_LINKS_DIR)/tests -Ifriends/tests/e2e
FRIENDS_LINKS_FRAMEWORKS := -framework Foundation -framework Security -framework LocalAuthentication -framework IOKit

ifeq ($(UNAME_S),Darwin)
FRIENDS_TEST_TARGETS += friends-links-check
endif
# The links e2e helper by itself: the production helper objects with the test hooks of its main (loopback links), for
# suites outside this area that need a whole Objective-C helper whose links work on one computer
# (core-rs/crates/szfriends-interop/tests/objc_links.rs).
.PHONY: friends-links-e2e-helper
friends-links-e2e-helper: $$(FRIENDS_SERVICE_OBJS) $$(FRIENDS_HELPER_OBJS) $$(FRIENDS_CLIENT_OBJS) \
		$(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ)
	@mkdir -p "$(FRIENDS_LINKS_BUILD)"
	clang $(FRIENDS_LINKS_TEST_FLAGS) $(FRIENDS_LINKS_DIR)/tests/e2e/main/SZFriendsLinksE2EHelperMain.m \
		$(FRIENDS_HELPER_OBJS) $(FRIENDS_SERVICE_OBJS) $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) \
		$(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) $(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip \
		-o "$(FRIENDS_LINKS_E2E_HELPER)"

.PHONY: friends-links-check
friends-links-check: $$(FRIENDS_SERVICE_OBJS) $$(FRIENDS_HELPER_OBJS) $$(FRIENDS_CLIENT_OBJS) $(FRIENDS_SODIUM_LIB) \
		$(FRIENDS_CJSON_OBJ) $$(FRIENDS_E2E_HOST_DEPS)
	@mkdir -p "$(FRIENDS_LINKS_BUILD)"
	@rm -f "$(FRIENDS_LINKS_TEST)" "$(FRIENDS_LINKS_E2E)" "$(FRIENDS_LINKS_E2E_HELPER)"
	clang $(FRIENDS_LINKS_TEST_FLAGS) $(FRIENDS_LINKS_TEST_SRCS) $(FRIENDS_SERVICE_OBJS) $(FRIENDS_CJSON_OBJ) \
		$(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) $(FRIENDS_LINKS_FRAMEWORKS) -Wl,-dead_strip \
		-o "$(FRIENDS_LINKS_TEST)"
	SZFRIENDS_LINKS_PAGES_DIR="$(CURDIR)/$(FRIENDS_HOST_SERVER_DIR)/src/pages/script" "$(FRIENDS_LINKS_TEST)"
	clang $(FRIENDS_LINKS_TEST_FLAGS) $(FRIENDS_LINKS_DIR)/tests/e2e/main/SZFriendsLinksE2EHelperMain.m \
		$(FRIENDS_HELPER_OBJS) $(FRIENDS_SERVICE_OBJS) $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) \
		$(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) $(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip \
		-o "$(FRIENDS_LINKS_E2E_HELPER)"
	clang $(FRIENDS_LINKS_TEST_FLAGS) $(FRIENDS_LINKS_E2E_SRCS) $(FRIENDS_HELPER_OBJS) $(FRIENDS_SERVICE_OBJS) \
		$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		$(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_LINKS_E2E)"
	SZFRIENDS_E2E_HOST_SERVER_DIR="$(CURDIR)/$(FRIENDS_HOST_SERVER_DIR)" \
		"$(FRIENDS_LINKS_E2E)" "$(FRIENDS_LINKS_E2E_HELPER)" "$(CURDIR)/friends/avatars/animals/manifest.json"
