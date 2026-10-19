# Shenzhen Friends build entry point, included by portable/Makefile.
#
# Make runs with cwd portable/, so every path here and in area makefiles is relative to portable/.
# portable/Makefile carries exactly two Friends lines: `include friends/friends.mk` and
# `friends-tests: friends-suite`. WHY only two: the release script discovers suites by scanning
# portable/Makefile for `*-tests:` targets, and every other Friends rule lives under portable/friends/
# so the module stays one directory that Shenzhen Files can build from as well.
#
# Each area owns one makefile (friends/<area>/<area>.mk, friends/service/<area>/<area>.mk, or under
# friends/service/online/<area>/; the exact paths are listed in friends/README.md) that appends its suite with
# `FRIENDS_TEST_TARGETS += friends-<area>-check`, defines that target, and writes build outputs under
# $(FRIENDS_BUILD). Area makefiles create their own output directories with `@mkdir -p "$(@D)"` instead
# of sharing a directory rule, so two areas never define the same recipe.

FRIENDS_DIR := friends
FRIENDS_BUILD := $(BUILD)/friends

# Shared compiler flags, so every area builds for the app's target (arm64, macOS 12 floor) the same way.
# Recursive '=' so a later override of the app's flags (release mode) reaches Friends too.
# Headers include one another by path relative to portable/friends ("service/store/SZFriendsStore.h").
FRIENDS_INCLUDES := -Ifriends
FRIENDS_OBJC_FLAGS = $(MAC_TARGET_FLAGS) -fobjc-arc -Wall -Wextra -Werror $(FRIENDS_INCLUDES)
FRIENDS_C_FLAGS = $(MAC_TARGET_FLAGS) -std=c99 -Wall -Wextra -Werror -pedantic $(FRIENDS_INCLUDES)

FRIENDS_TEST_TARGETS :=

# Public headers compiled on their own by friends-containment-check. Areas append new public headers.
FRIENDS_PUBLIC_HEADERS :=

# What each area contributes to the binaries other areas link (production objects only, never tests):
#   FRIENDS_SERVICE_OBJS / FRIENDS_SERVICE_LIBS  service areas -> the helper executable (-lsqlite3, -framework ...)
#   FRIENDS_CLIENT_OBJS                          client library -> the views, the fake helper and the apps
#   FRIENDS_VIEWS_OBJS                           mac/ views -> the host adapter and the app
# WHY second expansion: prerequisites expand when make reads a rule, and friends/service/helper/ sorts before
# friends/service/store/, so a link rule naming these lists directly would see them empty. Write them as
# $$(FRIENDS_SERVICE_OBJS) in prerequisite lists; recipes expand late anyway. Declared here, after every rule in
# portable/Makefile, so it affects Friends rules only.
FRIENDS_SERVICE_OBJS :=
FRIENDS_SERVICE_LIBS :=
FRIENDS_CLIENT_OBJS :=
FRIENDS_VIEWS_OBJS :=
.SECONDEXPANSION:

# deps first: rule prerequisites expand when make reads a rule, and friends/client/ sorts before
# friends/deps/, so an area linking cJSON or libsodium would otherwise see those variables empty.
# deps.mk guards itself, so the wildcard below including it again is harmless.
-include friends/deps/deps.mk
-include $(sort $(filter-out friends/friends.mk,$(wildcard friends/*.mk friends/*/*.mk friends/*/*/*.mk)))
# One level deeper than the wildcard, the online areas (friends/service/online/<area>/), each by its own line: the
# transport first (it brings in the stack's deps/datachannel.mk), then the NAT techniques with miniupnpc, the route
# order, and the driver that joins them in the helper. online.mk and nat.mk guard themselves; '-include' because the
# driver's makefile may not exist yet.
-include friends/service/online/transport/online.mk
-include friends/service/online/nat/nat.mk
-include friends/service/online/order/order.mk
-include friends/service/online/driver/driver.mk

# The host area's second public interface (rendezvous, connection setup and relay credentials, protocol 2), which the
# online driver includes. friends/tests/tests.mk lists the first, SZFriendsHostConnection.h; host.mk lists neither.
FRIENDS_PUBLIC_HEADERS += friends/service/host/SZFriendsHostRendezvous.h

# miniupnpc's local patch to getHTTPResponse (ext/miniupnpc/VENDORED.md § Local changes) and its regression test,
# ext/miniupnpc/szfriends/szfriends_test_miniwget.c. The rule lives here because ext/ has no makefiles; it takes
# nat.mk's miniupnpc variables, hence after the include above. Sanitizers on: the patch fixes a heap over-read, and
# the test must crash on a copy without it.
FRIENDS_MINIUPNPC_TEST := $(FRIENDS_BUILD)/miniupnpc/szfriends_test_miniwget
FRIENDS_TEST_TARGETS += friends-miniupnpc-check
.PHONY: friends-miniupnpc-check
friends-miniupnpc-check: $(FRIENDS_UPNP_STRINGS)
	@mkdir -p "$(dir $(FRIENDS_MINIUPNPC_TEST))"
	@rm -f "$(FRIENDS_MINIUPNPC_TEST)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_UPNP_BUILD_FLAGS) $(FRIENDS_NAT_SANITIZE) \
		$(FRIENDS_UPNP_DIR)/szfriends/szfriends_test_miniwget.c \
		$(patsubst %,$(FRIENDS_UPNP_DIR)/src/%.c,miniwget receivedata connecthostport addr_is_reserved) \
		-o "$(FRIENDS_MINIUPNPC_TEST)"
	"$(FRIENDS_MINIUPNPC_TEST)"

.PHONY: friends-suite friends-tests
# The naming check runs in the recipe, not as $(error) at parse time, so a misnamed suite fails friends-tests
# without breaking every other make goal in portable/ (mac-app, the reader's suites).
FRIENDS_MISNAMED_SUITES = $(filter-out friends-%-check,$(FRIENDS_TEST_TARGETS))
friends-suite: $(FRIENDS_TEST_TARGETS)
	@test -z "$(FRIENDS_MISNAMED_SUITES)" || \
		{ echo "Friends suites must be named friends-<area>-check: $(FRIENDS_MISNAMED_SUITES)" >&2; exit 1; }
