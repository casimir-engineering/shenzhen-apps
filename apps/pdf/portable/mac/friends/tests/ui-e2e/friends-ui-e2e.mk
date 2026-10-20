# friends-ui-e2e: ShenzhenPDF's Friends dropdown driven end to end against real helpers (SPDFMacFriendsUIE2E.h).
# Included by portable/Makefile after the host adapter's makefile; make runs with cwd portable/.
#
#   make friends-ui-e2e                                     every flow, light and dark, normal and narrow
#   make friends-ui-e2e FRIENDS_UI_E2E_VARIANTS=dark-narrow FRIENDS_UI_E2E_FLOWS=solo     one look, one group
#
# It needs a logged-in macOS session: the reader's window and the dropdown's popover appear on screen while it runs
# (a few minutes), without taking focus from other apps. Screenshots of every step, and flows.tsv with each flow's
# result in each look, go to $(FRIENDS_UI_E2E_SHOTS).

FRIENDS_UI_E2E_DIR := mac/friends/tests/ui-e2e
FRIENDS_UI_E2E_BUILD := $(BUILD)/friends-ui-e2e
FRIENDS_UI_E2E_HELPER := $(FRIENDS_UI_E2E_BUILD)/szfriends-e2e-helper
FRIENDS_UI_E2E_HARNESS_O := $(FRIENDS_UI_E2E_BUILD)/SZFriendsE2EHarness.o
FRIENDS_UI_E2E_TEST := $(FRIENDS_UI_E2E_BUILD)/SPDFMacFriendsUIE2ETests
FRIENDS_UI_E2E_SHOTS := $(FRIENDS_UI_E2E_BUILD)/screenshots
FRIENDS_UI_E2E_SRCS := $(addprefix $(FRIENDS_UI_E2E_DIR)/,SPDFMacFriendsUIE2ETests.mm SPDFMacFriendsUIDriver.mm \
	SPDFMacFriendsUIFlows.mm SPDFMacFriendsUIPairFlows.mm)
# The reader's side of Friends as the app links it: the host adapter, its title-bar placement and appearance.
FRIENDS_UI_E2E_HOST_SRCS := $(sort $(HOST_ADAPTER_REVISION_SRCS) $(addprefix $(HOST_ADAPTER_DIR)/,\
	SPDFMacFriendsAttachItems.mm SPDFMacFriendsHost.mm SPDFMacFriendsShareMenu.mm SPDFMacFriendsLaunch.mm \
	SPDFMacFriendsSettings.mm SPDFMacFriendsTitleBar.mm SPDFMacFriendsAppearance.mm)) \
	mac/SPDFMacCollectionStyle.mm mac/SPDFMacWindowChrome.mm
FRIENDS_UI_E2E_VARIANTS ?=
FRIENDS_UI_E2E_FLOWS ?=

.PHONY: friends-ui-e2e
# Every binary is compiled inside the recipe after an rm, as friends-e2e-check does, so a stale one never passes.
friends-ui-e2e: $$(FRIENDS_HELPER_OBJS) $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ) $$(FRIENDS_SERVICE_OBJS) \
		$$(FRIENDS_CLIENT_OBJS) $$(FRIENDS_VIEWS_LIB_OBJS) $$(FRIENDS_AVATARS_SET_OBJS)
	@mkdir -p "$(FRIENDS_UI_E2E_BUILD)"
	@rm -f "$(FRIENDS_UI_E2E_HELPER)" "$(FRIENDS_UI_E2E_HARNESS_O)" "$(FRIENDS_UI_E2E_TEST)"
	clang $(FRIENDS_E2E_FLAGS) $(FRIENDS_E2E_HELPER_SRCS) $(FRIENDS_HELPER_OBJS) $(FRIENDS_SERVICE_OBJS) \
		$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		$(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_UI_E2E_HELPER)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) -I$(FRIENDS_E2E_DIR) -c $(FRIENDS_E2E_DIR)/SZFriendsE2EHarness.m \
		-o "$(FRIENDS_UI_E2E_HARNESS_O)"
	clang++ $(HOST_ADAPTER_FLAGS) -I$(FRIENDS_E2E_DIR) -I$(FRIENDS_UI_E2E_DIR) $(FRIENDS_UI_E2E_SRCS) \
		$(FRIENDS_UI_E2E_HOST_SRCS) "$(FRIENDS_UI_E2E_HARNESS_O)" $(FRIENDS_VIEWS_LIB_OBJS) $(FRIENDS_AVATARS_SET_OBJS) \
		$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_VIEWS_LIBS) -framework Cocoa -lpthread \
		-o "$(FRIENDS_UI_E2E_TEST)"
	FRIENDS_UI_E2E_VARIANTS="$(FRIENDS_UI_E2E_VARIANTS)" FRIENDS_UI_E2E_FLOWS="$(FRIENDS_UI_E2E_FLOWS)" \
		"$(FRIENDS_UI_E2E_TEST)" "$(FRIENDS_UI_E2E_HELPER)" "$(CURDIR)/friends/avatars/animals/manifest.json" \
		"$(FRIENDS_UI_E2E_SHOTS)"
