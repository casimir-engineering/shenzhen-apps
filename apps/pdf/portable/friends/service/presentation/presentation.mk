# Shenzhen Friends presentation layer: strings catalog and snapshot builder (owner: protocol area).
# Make runs with cwd portable/. The objects join FRIENDS_SERVICE_OBJS, which the helper links.

FRIENDS_PRESENTATION_SRCS := $(sort $(wildcard friends/service/presentation/*.m))
FRIENDS_PRESENTATION_OBJS := $(patsubst friends/service/presentation/%.m,$(FRIENDS_BUILD)/presentation/%.o,\
	$(FRIENDS_PRESENTATION_SRCS))
FRIENDS_SERVICE_OBJS += $(FRIENDS_PRESENTATION_OBJS)
# The mention form (Foundation only) is the helper's too: its router writes mentions, its nearby service checks them.
FRIENDS_PUBLIC_HEADERS += friends/service/presentation/SZFriendsMentions.h
# Headers the presentation reads: its own, and the shared value types of the areas whose facts it formats.
FRIENDS_PRESENTATION_HDRS := \
	friends/service/presentation/SZFriendsPresentation.h \
	friends/service/presentation/SZFriendsPresentationPrivate.h \
	friends/service/presentation/SZFriendsPresentationJoin.h \
	friends/service/presentation/SZFriendsPresentationDevices.h \
	friends/service/presentation/SZFriendsPresentationNotifications.h \
	friends/service/presentation/SZFriendsMentions.h \
	friends/avatars/SZFriendsAvatars.h \
	friends/service/discovery/SZFriendsDiscovery.h \
	friends/service/identity/SZFriendsIdentity.h \
	friends/service/store/SZFriendsOutbox.h \
	friends/service/store/SZFriendsTransfers.h

$(FRIENDS_BUILD)/presentation/%.o: friends/service/presentation/%.m $(FRIENDS_PRESENTATION_HDRS) \
		friends/service/presentation/presentation.mk
	@mkdir -p "$(@D)"
	clang $(FRIENDS_OBJC_FLAGS) $(PORTABLE_OPTFLAGS) -c "$<" -o "$@"

# The test links the avatars area's real animal set, which reads the repository's manifest (the test points
# SZFRIENDS_AVATARS_MANIFEST at it), so avatar colors in every snapshot are the manifest's, as PROTOCOL.md requires.
# It also links PROTOCOL.md's schema validator, so every snapshot it builds, not only the fixtures, is checked against
# the document. Compiled inside the phony target: make skips a rebuild when source and binary share an mtime second.
FRIENDS_PRESENTATION_TEST := $(FRIENDS_BUILD)/presentation/SZFriendsPresentationTests
FRIENDS_PRESENTATION_TEST_SRCS = $(sort $(wildcard friends/service/presentation/tests/*.m)) \
	friends/tests/SZFriendsProtocolSchema.m
FRIENDS_TEST_TARGETS += friends-presentation-check
.PHONY: friends-presentation-check
friends-presentation-check: $(FRIENDS_PRESENTATION_OBJS) $$(FRIENDS_AVATARS_SET_OBJS)
	@mkdir -p "$(FRIENDS_BUILD)/presentation"
	@rm -f "$(FRIENDS_PRESENTATION_TEST)"
	clang $(FRIENDS_OBJC_FLAGS) $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_PRESENTATION_TEST_SRCS) \
		$(FRIENDS_PRESENTATION_OBJS) $(FRIENDS_AVATARS_SET_OBJS) -framework Foundation \
		-o "$(FRIENDS_PRESENTATION_TEST)"
	"$(FRIENDS_PRESENTATION_TEST)" friends/PROTOCOL.md friends/fixtures
