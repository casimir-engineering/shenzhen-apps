# Shenzhen Friends AppKit views (owner: views). Included by friends/friends.mk; make runs with cwd portable/.
#
# Outputs for other areas:
#   FRIENDS_VIEWS_OBJS   the views; whoever links them (the host adapter, the app) also links $(FRIENDS_CLIENT_OBJS),
#                        $(FRIENDS_CJSON_OBJ), $(FRIENDS_AVATARS_SET_OBJS) and $(FRIENDS_VIEWS_LIBS)
#   FRIENDS_VIEWS_LIBS   the system frameworks the views use
# Name them as $$(FRIENDS_...) in prerequisite lists (friends.mk § second expansion).

FRIENDS_VIEWS_BUILD := $(FRIENDS_BUILD)/views
FRIENDS_VIEWS_SRCS := $(sort $(wildcard friends/mac/*.m))
FRIENDS_VIEWS_HDRS := $(wildcard friends/mac/*.h) friends/client/szfriends_client.h friends/avatars/SZFriendsAvatars.h
FRIENDS_VIEWS_LIB_OBJS := $(patsubst friends/mac/%.m,$(FRIENDS_VIEWS_BUILD)/%.o,$(FRIENDS_VIEWS_SRCS))
FRIENDS_VIEWS_OBJS += $(FRIENDS_VIEWS_LIB_OBJS)
FRIENDS_VIEWS_LIBS := -framework AppKit -framework CoreImage -framework ImageIO -framework UniformTypeIdentifiers

# The app's optimization level, so the views the reader links are the ones the tests exercised.
$(FRIENDS_VIEWS_BUILD)/%.o: friends/mac/%.m $(FRIENDS_VIEWS_HDRS) friends/mac/views.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) -c "$<" -o "$@"

# Compiled inside the phony target (README § Building and testing): make skips a rebuild when source and binary
# share an mtime second. The suite drives the views through the real link and client library against the protocol
# area's in-process fake helper, on loopback in a temporary SZFRIENDS_STATE_DIR, and writes offscreen renders of
# every view in light and dark to $(FRIENDS_VIEWS_RENDERS).
FRIENDS_VIEWS_TEST := $(FRIENDS_VIEWS_BUILD)/SZFriendsViewsTests
FRIENDS_VIEWS_TEST_SRCS = $(sort $(wildcard friends/mac/tests/*.m))
FRIENDS_VIEWS_RENDERS := $(FRIENDS_VIEWS_BUILD)/renders
FRIENDS_TEST_TARGETS += friends-views-check
.PHONY: friends-views-check
friends-views-check: $(FRIENDS_VIEWS_LIB_OBJS) $$(FRIENDS_AVATARS_SET_OBJS) $$(FRIENDS_FAKE_HELPER_LIB) \
		$$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ)
	@mkdir -p "$(FRIENDS_VIEWS_RENDERS)"
	@rm -f "$(FRIENDS_VIEWS_TEST)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) -Ifriends/mac/tests $(FRIENDS_VIEWS_TEST_SRCS) \
		$(FRIENDS_VIEWS_LIB_OBJS) $(FRIENDS_AVATARS_SET_OBJS) $(FRIENDS_FAKE_HELPER_LINK) $(FRIENDS_VIEWS_LIBS) \
		-o "$(FRIENDS_VIEWS_TEST)"
	"$(FRIENDS_VIEWS_TEST)" friends/fixtures friends/avatars/animals/manifest.json "$(FRIENDS_VIEWS_RENDERS)"

# By hand, not in the suite: the dropdown in a real NSPopover, which needs a window on screen for about a second
# (tools/popover-probe.m). friends-views-check checks the same placement with a stand-in for the popover's frame.
FRIENDS_VIEWS_POPOVER_PROBE := $(FRIENDS_VIEWS_BUILD)/popover-probe
.PHONY: friends-views-popover-probe
friends-views-popover-probe: $(FRIENDS_VIEWS_LIB_OBJS) $$(FRIENDS_AVATARS_SET_OBJS) $$(FRIENDS_FAKE_HELPER_LIB) \
		$$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ)
	@mkdir -p "$(FRIENDS_VIEWS_RENDERS)"
	@rm -f "$(FRIENDS_VIEWS_POPOVER_PROBE)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) -Ifriends/mac/tests friends/mac/tools/popover-probe.m \
		$(filter-out %/SZFriendsViewsTests.m,$(filter friends/mac/tests/SZFriendsViewsTest%.m,$(FRIENDS_VIEWS_TEST_SRCS))) \
		$(FRIENDS_VIEWS_LIB_OBJS) $(FRIENDS_AVATARS_SET_OBJS) $(FRIENDS_FAKE_HELPER_LINK) $(FRIENDS_VIEWS_LIBS) \
		-o "$(FRIENDS_VIEWS_POPOVER_PROBE)"
	"$(FRIENDS_VIEWS_POPOVER_PROBE)" friends/fixtures friends/avatars/animals/manifest.json "$(FRIENDS_VIEWS_RENDERS)"
