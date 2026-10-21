# System notifications between real helpers (SZFriendsE2ENotifyTests.m; ADR 0017): friends-e2e-notify-check.
# Included by friends/friends.mk after e2e.mk, whose variables it uses; make runs with cwd portable/. Every helper runs
# in a test home and posts to its JSON-lines sink, never to the notification centre. The helper is the devices
# suite's (the online e2e helper main); every scenario is nearby, on loopback.
FRIENDS_E2E_NOTIFY_HELPER := $(FRIENDS_E2E_BUILD)/szfriends-e2e-notify-helper
FRIENDS_E2E_NOTIFY_TEST := $(FRIENDS_E2E_BUILD)/SZFriendsE2ENotifyTests
FRIENDS_E2E_NOTIFY_SRCS := $(addprefix $(FRIENDS_E2E_DIR)/, SZFriendsE2ENotifyTests.m SZFriendsE2EDevicesSupport.m \
	SZFriendsE2EOnlineHost.m SZFriendsE2EHarness.m)

FRIENDS_TEST_TARGETS += friends-e2e-notify-check
.PHONY: friends-e2e-notify-check
friends-e2e-notify-check: $$(FRIENDS_HELPER_OBJS) $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ) $$(FRIENDS_SERVICE_OBJS) \
		$$(FRIENDS_CLIENT_OBJS)
	@mkdir -p "$(FRIENDS_E2E_BUILD)"
	@rm -f "$(FRIENDS_E2E_NOTIFY_HELPER)" "$(FRIENDS_E2E_NOTIFY_TEST)"
	clang $(FRIENDS_E2E_FLAGS) $(FRIENDS_E2E_DIR)/SZFriendsE2EOnlineHelperMain.m $(FRIENDS_HELPER_OBJS) \
		$(FRIENDS_SERVICE_OBJS) $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) \
		$(FRIENDS_SERVICE_LIBS) $(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_E2E_NOTIFY_HELPER)"
	clang $(FRIENDS_E2E_FLAGS) $(FRIENDS_E2E_NOTIFY_SRCS) $(FRIENDS_HELPER_OBJS) $(FRIENDS_SERVICE_OBJS) \
		$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		$(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_E2E_NOTIFY_TEST)"
	"$(FRIENDS_E2E_NOTIFY_TEST)" "$(FRIENDS_E2E_NOTIFY_HELPER)" "$(CURDIR)/friends/avatars/animals/manifest.json" \
		$(FRIENDS_E2E_NOTIFY_ONLY)
