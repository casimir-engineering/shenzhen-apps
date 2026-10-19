# Module-wide Friends suites: containment and the client protocol contract (owner: protocol contracts).
# Included by friends/friends.mk; make runs with cwd portable/.

# Public headers, one or more per area, each compiled on its own by friends-containment-check. Areas that add a
# public header append it here or in their own makefile with `FRIENDS_PUBLIC_HEADERS += friends/...`.
FRIENDS_PUBLIC_HEADERS += \
	friends/client/szfriends_client.h \
	friends/avatars/SZFriendsAvatars.h \
	friends/service/presentation/SZFriendsPresentation.h \
	friends/service/helper/SZFriendsHelper.h \
	friends/service/store/SZFriendsStore.h \
	friends/service/store/SZFriendsOutbox.h \
	friends/service/store/SZFriendsTransfers.h \
	friends/service/identity/SZFriendsIdentity.h \
	friends/service/session/SZFriendsSession.h \
	friends/service/discovery/SZFriendsDiscovery.h \
	friends/service/host/SZFriendsHostConnection.h \
	friends/mac/SZFriendsHost.h \
	friends/mac/SZFriendsHelperLink.h \
	friends/mac/SZFriendsDropdownController.h \
	friends/mac/SZFriendsSettingsSection.h

FRIENDS_TEST_TARGETS += friends-containment-check friends-protocol-check
.PHONY: friends-containment-check friends-protocol-check

# Self-test first, so a checker that stopped catching violations fails before it is trusted with the tree.
# FRIENDS_PUBLIC_HEADERS expands when the recipe runs, after every area makefile has appended to it.
# Run through bash explicitly so a checkout that lost the executable bit still runs the check.
friends-containment-check:
	bash friends/tests/containment-check.sh --self-test
	bash friends/tests/containment-check.sh friends
	CC=clang FRIENDS_HEADER_FLAGS="$(MAC_TARGET_FLAGS)" bash friends/tests/containment-check.sh --headers friends \
		$(FRIENDS_PUBLIC_HEADERS)

# Compiled on every run rather than through a file rule: make skips a rebuild when source and binary share an
# mtime second (portable/docs/agent-handoff.md), and the compile takes about a second. -Ifriends because the
# test compares the client header's version and limits with PROTOCOL.md and the welcome fixture.
FRIENDS_PROTOCOL_TEST := $(FRIENDS_BUILD)/SZFriendsProtocolTests
friends-protocol-check:
	@mkdir -p "$(FRIENDS_BUILD)"
	@rm -f "$(FRIENDS_PROTOCOL_TEST)"
	clang $(MAC_TARGET_FLAGS) -fobjc-arc -Wall -Wextra -Werror $(FRIENDS_INCLUDES) \
		friends/tests/SZFriendsProtocolTests.m friends/tests/SZFriendsProtocolSchema.m \
		-framework Foundation -o "$(FRIENDS_PROTOCOL_TEST)"
	"$(FRIENDS_PROTOCOL_TEST)" friends/PROTOCOL.md friends/fixtures
