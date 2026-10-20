# friends-one-identity-check (owner: helper orchestration): one person's Friends is one identity, one helper and one
# history on each computer, whichever of ShenzhenPDF, Shenzhen Files and Shenzhen 3D run there, and one profile across
# their computers (SZFriendsE2EOneIdentity.h). Included by friends/friends.mk; make runs with cwd portable/.
#
# Not in friends-suite: it runs Shenzhen 3D's Electron shell, which lives beside this module in the Shenzhen
# repository (apps/3d). The repository's `make friends-one-identity-e2e` runs it, and `make friends-tests` with it.
# FRIENDS_ONEID_3D names that tree, set up with npm ci, scripts/friends/setup-friends.sh and npm run build; without it
# the target stops and says so. Nothing it starts is ever shown: the AppKit app is never a foreground app, the GTK
# app links the views' quiet interposer, and Electron runs as a hidden, background-only copy.

FRIENDS_ONEID_BUILD := $(FRIENDS_E2E_BUILD)/oneid
FRIENDS_ONEID_HELPER := $(FRIENDS_ONEID_BUILD)/szfriends-e2e-oneid-helper
FRIENDS_ONEID_TEST := $(FRIENDS_ONEID_BUILD)/SZFriendsE2EOneIdentityTests
FRIENDS_ONEID_APPKIT_APP := $(FRIENDS_ONEID_BUILD)/szfriends-e2e-appkit-app
FRIENDS_ONEID_GTK_APP := $(FRIENDS_ONEID_BUILD)/szfriends-e2e-gtk-views-app
FRIENDS_ONEID_QUIET := $(FRIENDS_ONEID_BUILD)/libszfriends_gtk_quiet.dylib
FRIENDS_ONEID_SRCS := $(addprefix $(FRIENDS_E2E_DIR)/, SZFriendsE2EOneIdentityTests.m SZFriendsE2EOneIdentityMac.m \
	SZFriendsE2EOneIdentityApps.m SZFriendsE2EOneIdentityViews.m SZFriendsE2EOneIdentityDevices.m SZFriendsE2EApps.m \
	SZFriendsE2EDevicesSupport.m SZFriendsE2EOnlineHost.m SZFriendsE2EHarness.m)
FRIENDS_ONEID_3D ?=
FRIENDS_ONEID_NODE = $(shell command -v node 2>/dev/null)
# FRIENDS_ONEID_ONLY=1,4 runs only those scenarios, while working on them.
FRIENDS_ONEID_ONLY ?=

.PHONY: friends-one-identity-check
friends-one-identity-check: $$(FRIENDS_HELPER_OBJS) $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ) \
		$$(FRIENDS_SERVICE_OBJS) $$(FRIENDS_CLIENT_OBJS) $$(FRIENDS_VIEWS_OBJS) $$(FRIENDS_AVATARS_SET_OBJS) \
		$$(FRIENDS_GTK_LIB) $$(FRIENDS_E2E_HOST_DEPS)
	$(FRIENDS_GTK_REQUIRE)
	@test -n "$(FRIENDS_ONEID_3D)" && test -f "$(FRIENDS_ONEID_3D)/electron/friends-one-identity-app.mjs" || \
		{ echo "friends-one-identity-check: FRIENDS_ONEID_3D must name Shenzhen 3D's tree (apps/3d); run it as" \
			"make friends-one-identity-e2e from the repository's root" >&2; exit 1; }
	@test -n "$(FRIENDS_ONEID_NODE)" || { echo "friends-one-identity-check: needs node on PATH" >&2; exit 1; }
	@mkdir -p "$(FRIENDS_ONEID_BUILD)"
	@rm -f "$(FRIENDS_ONEID_HELPER)" "$(FRIENDS_ONEID_TEST)" "$(FRIENDS_ONEID_APPKIT_APP)" "$(FRIENDS_ONEID_GTK_APP)" \
		"$(FRIENDS_ONEID_QUIET)"
	clang $(FRIENDS_E2E_FLAGS) $(FRIENDS_E2E_DIR)/SZFriendsE2EOneIdentityHelperMain.m $(FRIENDS_HELPER_OBJS) \
		$(FRIENDS_SERVICE_OBJS) $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) \
		$(FRIENDS_SERVICE_LIBS) $(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_ONEID_HELPER)"
	clang $(FRIENDS_E2E_FLAGS) $(FRIENDS_ONEID_SRCS) $(FRIENDS_HELPER_OBJS) $(FRIENDS_SERVICE_OBJS) \
		$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		$(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_ONEID_TEST)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_E2E_DIR)/szfriends_e2e_appkit_app.m \
		$(FRIENDS_VIEWS_OBJS) $(FRIENDS_AVATARS_SET_OBJS) $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) \
		$(FRIENDS_VIEWS_LIBS) -o "$(FRIENDS_ONEID_APPKIT_APP)"
	clang $(FRIENDS_GTK_TEST_TARGET) -std=c11 -Wall -Wextra -Werror -dynamiclib friends/gtk/tests/szfriends_gtk_quiet.c \
		-framework ApplicationServices -install_name @executable_path/libszfriends_gtk_quiet.dylib \
		-o "$(FRIENDS_ONEID_QUIET)"
	clang $(FRIENDS_GTK_TEST_TARGET) -std=c11 -Wall -Wextra -Werror $(FRIENDS_INCLUDES) $(PORTABLE_TEST_OPTFLAGS) \
		$(FRIENDS_GTK_PKG_CFLAGS) $(FRIENDS_E2E_DIR)/szfriends_e2e_gtk_views_app.c $(FRIENDS_GTK_LIB) \
		$(FRIENDS_GTK_PKG_LIBS) -L"$(FRIENDS_ONEID_BUILD)" -lszfriends_gtk_quiet -framework ApplicationServices \
		-o "$(FRIENDS_ONEID_GTK_APP)"
	SZFRIENDS_E2E_HOST_SERVER_DIR="$(CURDIR)/$(FRIENDS_HOST_SERVER_DIR)" \
		SZFRIENDS_E2E_APPKIT_APP="$(FRIENDS_ONEID_APPKIT_APP)" SZFRIENDS_E2E_GTK_APP="$(FRIENDS_ONEID_GTK_APP)" \
		SZFRIENDS_E2E_GTK_QUIET="$(FRIENDS_ONEID_QUIET)" SZFRIENDS_E2E_NODE="$(FRIENDS_ONEID_NODE)" \
		SZFRIENDS_E2E_3D="$(abspath $(FRIENDS_ONEID_3D))" \
		"$(FRIENDS_ONEID_TEST)" "$(FRIENDS_ONEID_HELPER)" "$(CURDIR)/friends/avatars/animals/manifest.json" \
		$(FRIENDS_ONEID_ONLY)
