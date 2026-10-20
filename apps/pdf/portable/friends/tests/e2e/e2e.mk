# Shenzhen Friends two-helper harness (owner: helper orchestration): friends-e2e-check. Included by
# friends/friends.mk; make runs with cwd portable/.
#
# Two real helpers on separate SZFRIENDS_STATE_DIR directories find each other over loopback Bonjour (a random
# test-only service type per scenario, lo0 only) and the scripted slow Bluetooth adapter, and are driven only
# through the C client library. The helper the harness runs is the production helper's objects with
# tests/e2e/SZFriendsE2EHelperMain.m as main, which sets the test hooks (SZFriendsHelperTesting.h) from its
# environment; the shipped main.m never does. No Keychain, no non-loopback interface, no Bluetooth manager, and no
# host check-in except the host scenario's, with the local Node host service on 127.0.0.1 and a list signed by a
# throwaway key. Some scenarios add a peer under the test's control (SZFriendsE2ERogue.h), which links the service
# areas' objects into the runner. Every scenario finishes within 60 s and leaves no process behind.

FRIENDS_E2E_DIR := friends/tests/e2e
FRIENDS_E2E_BUILD := $(FRIENDS_BUILD)/e2e
FRIENDS_E2E_HELPER := $(FRIENDS_E2E_BUILD)/szfriends-e2e-helper
FRIENDS_E2E_TEST := $(FRIENDS_E2E_BUILD)/SZFriendsE2ETests
FRIENDS_E2E_HELPER_SRCS := $(addprefix $(FRIENDS_E2E_DIR)/, SZFriendsE2EHelperMain.m SZFriendsE2EBluetooth.m \
	SZFriendsE2ESocketStream.m SZFriendsE2EScriptedNearby.m)
FRIENDS_E2E_TEST_SRCS := $(addprefix $(FRIENDS_E2E_DIR)/, SZFriendsE2ETests.m SZFriendsE2EHarness.m \
	SZFriendsE2EScenarios.m SZFriendsE2EScenarios2.m SZFriendsE2EScenarios3.m SZFriendsE2ERogue.m \
	SZFriendsE2ERogueScenarios.m SZFriendsE2EHostScenario.m SZFriendsE2EAttestScenarios.m \
	SZFriendsE2EAssistantScenarios.m SZFriendsE2EThumbnailScenarios.m SZFriendsE2EMentionScenarios.m \
	SZFriendsE2EApps.m SZFriendsE2ETwoAppScenarios.m SZFriendsE2EHistoryScenarios.m)
# The two-app scenarios run each app as a process of its own: ShenzhenPDF's part through the C client library, and
# Shenzhen Files' part through the GTK views' link, display-free (it never opens a display), so this suite needs GTK
# through pkg-config as friends-gtk-check does. Built for the running macOS, as the GTK suite's binaries are.
FRIENDS_E2E_CLIENT_APP := $(FRIENDS_E2E_BUILD)/szfriends-e2e-client-app
FRIENDS_E2E_GTK_APP := $(FRIENDS_E2E_BUILD)/szfriends-e2e-gtk-app
# The host scenario runs the local Node host service, whose node_modules friends-host-server-check installs; with no
# node on PATH the scenario says so and skips, so the install is only asked for where node exists. Recursive, so the
# shell runs only when this suite is built.
FRIENDS_E2E_NODE = $(shell command -v node 2>/dev/null)
FRIENDS_E2E_HOST_DEPS = $(if $(FRIENDS_E2E_NODE),$(FRIENDS_HOST_SERVER_DIR)/node_modules/.package-lock.json)
FRIENDS_E2E_FLAGS = $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -I$(FRIENDS_E2E_DIR)
# Online Friends (SZFriendsE2EOnline.h): its own helper main (the online driver's loopback test hooks) and runner,
# which links the helper's objects to seed two stores as friends. The relay scenario needs FRIENDS_TEST_COTURN and
# skips, saying so, without it.
FRIENDS_E2E_ONLINE_HELPER := $(FRIENDS_E2E_BUILD)/szfriends-e2e-online-helper
FRIENDS_E2E_ONLINE_TEST := $(FRIENDS_E2E_BUILD)/SZFriendsE2EOnlineTests
FRIENDS_E2E_ONLINE_TEST_SRCS := $(addprefix $(FRIENDS_E2E_DIR)/, SZFriendsE2EOnlineTests.m SZFriendsE2EOnlineHost.m \
	SZFriendsE2EOnlineAddScenarios.m SZFriendsE2EHarness.m)

FRIENDS_TEST_TARGETS += friends-e2e-check
.PHONY: friends-e2e-check
# Every binary is compiled inside the recipe, after an rm, so a stale binary never passes for a new one (make
# skips a rebuild when source and binary share an mtime second).
friends-e2e-check: $$(FRIENDS_HELPER_OBJS) $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ) $$(FRIENDS_SERVICE_OBJS) \
		$$(FRIENDS_CLIENT_OBJS) $$(FRIENDS_E2E_HOST_DEPS) $$(FRIENDS_GTK_LIB)
	$(FRIENDS_GTK_REQUIRE)
	@mkdir -p "$(FRIENDS_E2E_BUILD)"
	@rm -f "$(FRIENDS_E2E_HELPER)" "$(FRIENDS_E2E_TEST)" "$(FRIENDS_E2E_CLIENT_APP)" "$(FRIENDS_E2E_GTK_APP)" \
		"$(FRIENDS_E2E_ONLINE_HELPER)" "$(FRIENDS_E2E_ONLINE_TEST)"
	clang $(FRIENDS_E2E_FLAGS) $(FRIENDS_E2E_HELPER_SRCS) $(FRIENDS_HELPER_OBJS) $(FRIENDS_SERVICE_OBJS) \
		$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		$(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_E2E_HELPER)"
	clang $(FRIENDS_E2E_FLAGS) $(FRIENDS_E2E_TEST_SRCS) $(FRIENDS_SERVICE_OBJS) $(FRIENDS_CLIENT_OBJS) \
		$(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) -framework Foundation -Wl,-dead_strip \
		-o "$(FRIENDS_E2E_TEST)"
	clang $(FRIENDS_C_FLAGS) $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_CJSON_CFLAGS) \
		$(FRIENDS_E2E_DIR)/szfriends_e2e_client_app.c $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) \
		-o "$(FRIENDS_E2E_CLIENT_APP)"
	clang $(FRIENDS_GTK_TEST_TARGET) -std=c11 -Wall -Wextra -Werror $(FRIENDS_INCLUDES) $(PORTABLE_TEST_OPTFLAGS) \
		$(FRIENDS_GTK_PKG_CFLAGS) $(FRIENDS_E2E_DIR)/szfriends_e2e_gtk_app.c $(FRIENDS_GTK_LIB) \
		$(FRIENDS_GTK_PKG_LIBS) -o "$(FRIENDS_E2E_GTK_APP)"
	SZFRIENDS_E2E_HOST_SERVER_DIR="$(CURDIR)/$(FRIENDS_HOST_SERVER_DIR)" \
		SZFRIENDS_E2E_CLIENT_APP="$(FRIENDS_E2E_CLIENT_APP)" SZFRIENDS_E2E_GTK_APP="$(FRIENDS_E2E_GTK_APP)" \
		"$(FRIENDS_E2E_TEST)" "$(FRIENDS_E2E_HELPER)" "$(CURDIR)/friends/avatars/animals/manifest.json"
	clang $(FRIENDS_E2E_FLAGS) $(FRIENDS_E2E_DIR)/SZFriendsE2EOnlineHelperMain.m $(FRIENDS_HELPER_OBJS) \
		$(FRIENDS_SERVICE_OBJS) $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		$(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_E2E_ONLINE_HELPER)"
	clang $(FRIENDS_E2E_FLAGS) $(FRIENDS_E2E_ONLINE_TEST_SRCS) $(FRIENDS_HELPER_OBJS) $(FRIENDS_SERVICE_OBJS) \
		$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		$(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_E2E_ONLINE_TEST)"
	SZFRIENDS_E2E_HOST_SERVER_DIR="$(CURDIR)/$(FRIENDS_HOST_SERVER_DIR)" \
		"$(FRIENDS_E2E_ONLINE_TEST)" "$(FRIENDS_E2E_ONLINE_HELPER)" "$(CURDIR)/friends/avatars/animals/manifest.json"

# One person's Friends on several computers (SZFriendsE2EDevices.h): joining nearby and online, sync with a
# partition, removal, erasing, You and files on another computer, and friends reaching any of the computers. Its
# helper is the online helper (a binary of its own here); nearby scenarios give it no host list.
# FRIENDS_E2E_DEVICES_ONLY=1,4 runs only those scenarios, while working on them.
FRIENDS_E2E_DEVICES_HELPER := $(FRIENDS_E2E_BUILD)/szfriends-e2e-devices-helper
FRIENDS_E2E_DEVICES_TEST := $(FRIENDS_E2E_BUILD)/SZFriendsE2EDevicesTests
FRIENDS_E2E_DEVICES_SRCS := $(addprefix $(FRIENDS_E2E_DIR)/, SZFriendsE2EDevicesTests.m SZFriendsE2EDevicesSupport.m \
	SZFriendsE2EDevicesJoinScenarios.m SZFriendsE2EDevicesRevokeScenarios.m SZFriendsE2EDevicesHistoryScenarios.m \
	SZFriendsE2EDevicesFriendScenarios.m SZFriendsE2EDevicesPartitionScenarios.m SZFriendsE2EOnlineHost.m \
	SZFriendsE2EHarness.m)

FRIENDS_TEST_TARGETS += friends-e2e-devices-check
.PHONY: friends-e2e-devices-check
friends-e2e-devices-check: $$(FRIENDS_HELPER_OBJS) $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ) $$(FRIENDS_SERVICE_OBJS) \
		$$(FRIENDS_CLIENT_OBJS) $$(FRIENDS_E2E_HOST_DEPS)
	@mkdir -p "$(FRIENDS_E2E_BUILD)"
	@rm -f "$(FRIENDS_E2E_DEVICES_HELPER)" "$(FRIENDS_E2E_DEVICES_TEST)"
	clang $(FRIENDS_E2E_FLAGS) $(FRIENDS_E2E_DIR)/SZFriendsE2EOnlineHelperMain.m $(FRIENDS_HELPER_OBJS) \
		$(FRIENDS_SERVICE_OBJS) $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) \
		$(FRIENDS_SERVICE_LIBS) $(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_E2E_DEVICES_HELPER)"
	clang $(FRIENDS_E2E_FLAGS) $(FRIENDS_E2E_DEVICES_SRCS) $(FRIENDS_HELPER_OBJS) $(FRIENDS_SERVICE_OBJS) \
		$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		$(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_E2E_DEVICES_TEST)"
	SZFRIENDS_E2E_HOST_SERVER_DIR="$(CURDIR)/$(FRIENDS_HOST_SERVER_DIR)" "$(FRIENDS_E2E_DEVICES_TEST)" \
		"$(FRIENDS_E2E_DEVICES_HELPER)" "$(CURDIR)/friends/avatars/animals/manifest.json" $(FRIENDS_E2E_DEVICES_ONLY)
