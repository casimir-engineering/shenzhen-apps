# Shenzhen Friends GTK4 views (owner: gtk views). Included by friends/friends.mk; make runs with cwd portable/.
#
# Outputs for hosts (Shenzhen Files builds these from a pinned checkout, never a working copy others use):
#   friends-gtk-lib     $(FRIENDS_GTK_LIB): the views, the C client library and cJSON in one archive; link it with
#                       `pkg-config --libs gtk4 libadwaita-1 json-glib-1.0`, and compile against -I<portable/friends>
#   friends-gtk-check   the suite: display-free tests, then offscreen widget probes rendered to $(FRIENDS_GTK_RENDERS)
# GTK 4.22, libadwaita 1.9 and json-glib come from pkg-config (Homebrew on macOS). Without them the suite fails with a
# message rather than skipping, as the host server suite does without Node.js: a skipped suite proves nothing.

FRIENDS_GTK_BUILD := $(FRIENDS_BUILD)/gtk
FRIENDS_GTK_PKGS := gtk4 libadwaita-1 json-glib-1.0
FRIENDS_GTK_SRCS := $(sort $(wildcard friends/gtk/*.c))
FRIENDS_GTK_HDRS := $(wildcard friends/gtk/*.h) friends/client/szfriends_client.h
FRIENDS_GTK_RESOURCE_C := $(FRIENDS_GTK_BUILD)/szfriends_gtk_resources.c
FRIENDS_GTK_RESOURCE_DEPS := friends/gtk/szfriends_gtk.gresource.xml friends/gtk/szfriends_gtk.css \
	$(wildcard friends/gtk/icons/*.svg)
FRIENDS_GTK_LIB_OBJS := $(patsubst friends/gtk/%.c,$(FRIENDS_GTK_BUILD)/%.o,$(FRIENDS_GTK_SRCS)) \
	$(FRIENDS_GTK_BUILD)/szfriends_gtk_resources.o
FRIENDS_GTK_LIB := $(FRIENDS_GTK_BUILD)/libszfriends_gtk.a
FRIENDS_PUBLIC_HEADERS += friends/gtk/szfriends_gtk.h friends/gtk/szfriends_gtk_host.h

# C11 without -pedantic: GLib's headers use extensions -pedantic rejects. pkg-config runs in the recipe, so reading
# this file (every make goal in portable/) never needs GTK. The app's optimization level, as the client library uses.
FRIENDS_GTK_CFLAGS = $(MAC_TARGET_FLAGS) -std=c11 -Wall -Wextra -Werror $(FRIENDS_INCLUDES) $(PORTABLE_OPTFLAGS)
FRIENDS_GTK_PKG_CFLAGS = $$(pkg-config --cflags $(FRIENDS_GTK_PKGS))
FRIENDS_GTK_PKG_LIBS = $$(pkg-config --libs $(FRIENDS_GTK_PKGS))
FRIENDS_GTK_REQUIRE = @pkg-config --exists '$(FRIENDS_GTK_PKGS)' || { echo "friends-gtk: needs $(FRIENDS_GTK_PKGS) \
	through pkg-config (brew install gtk4 libadwaita json-glib)" >&2; exit 1; }

$(FRIENDS_GTK_BUILD)/%.o: friends/gtk/%.c $(FRIENDS_GTK_HDRS) friends/gtk/gtk.mk
	@mkdir -p "$(@D)"
	$(FRIENDS_GTK_REQUIRE)
	clang $(FRIENDS_GTK_CFLAGS) $(FRIENDS_GTK_PKG_CFLAGS) -c "$<" -o "$@"

$(FRIENDS_GTK_RESOURCE_C): $(FRIENDS_GTK_RESOURCE_DEPS) friends/gtk/gtk.mk
	@mkdir -p "$(@D)"
	$(FRIENDS_GTK_REQUIRE)
	glib-compile-resources --sourcedir=friends/gtk --generate-source --manual-register --c-name szfriends_gtk \
		--target="$@" friends/gtk/szfriends_gtk.gresource.xml

# Generated code: warnings stay on, -Werror off, since a newer glib-compile-resources must not break the build.
$(FRIENDS_GTK_BUILD)/szfriends_gtk_resources.o: $(FRIENDS_GTK_RESOURCE_C)
	clang $(MAC_TARGET_FLAGS) -std=c11 $(PORTABLE_OPTFLAGS) $(FRIENDS_GTK_PKG_CFLAGS) -c "$<" -o "$@"

# Removed first so an object dropped from the list cannot survive as a stale archive member.
$(FRIENDS_GTK_LIB): $(FRIENDS_GTK_LIB_OBJS) $$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ)
	@mkdir -p "$(@D)"
	@rm -f "$@"
	ar rcs "$@" $(FRIENDS_GTK_LIB_OBJS) $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ)

.PHONY: friends-gtk-lib friends-gtk-check
friends-gtk-lib: $(FRIENDS_GTK_LIB)

# Compiled inside the phony target (README § Building and testing): make skips a rebuild when source and binary
# share an mtime second. Two binaries: the display-free suite runs anywhere; the probes open the GTK display, so they
# need a logged-in session, and on macOS they link a tiny interposer (tests/szfriends_gtk_quiet.c) that keeps GDK
# from turning the test into a foreground app: no Dock icon, no focus taken from whatever the person is using.
FRIENDS_GTK_TEST := $(FRIENDS_GTK_BUILD)/SZFriendsGtkTests
FRIENDS_GTK_PROBES := $(FRIENDS_GTK_BUILD)/SZFriendsGtkProbes
FRIENDS_GTK_QUIET := $(FRIENDS_GTK_BUILD)/libszfriends_gtk_quiet.dylib
FRIENDS_GTK_RENDERS := $(FRIENDS_GTK_BUILD)/renders
FRIENDS_GTK_TEST_SRCS = $(sort $(wildcard friends/gtk/tests/szfriends_gtk_test_*.c))
FRIENDS_GTK_PROBE_SRCS = $(sort $(wildcard friends/gtk/tests/szfriends_gtk_probe_*.c))
# The suite runs only here, against the GTK pkg-config finds, which Homebrew builds for the running macOS: linking
# it for the app's 12.0 floor would print a warning per library, burying real ones.
ifeq ($(UNAME_S),Darwin)
FRIENDS_GTK_TEST_TARGET = -arch $(MAC_ARCH) -mmacosx-version-min=$$(sw_vers -productVersion | cut -d. -f1,2)
endif
FRIENDS_GTK_TEST_CFLAGS = $(FRIENDS_GTK_TEST_TARGET) -std=c11 -Wall -Wextra -Werror $(FRIENDS_INCLUDES) \
	-Ifriends/gtk/tests $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_CJSON_CFLAGS)
FRIENDS_GTK_TEST_LINK = $(FRIENDS_FAKE_HELPER_LIB) $(FRIENDS_GTK_LIB) -lpthread $(FRIENDS_GTK_PKG_LIBS)
ifeq ($(UNAME_S),Darwin)
FRIENDS_GTK_PROBE_LINK = -L"$(FRIENDS_GTK_BUILD)" -lszfriends_gtk_quiet -framework ApplicationServices
endif

FRIENDS_TEST_TARGETS += friends-gtk-check
friends-gtk-check: $(FRIENDS_GTK_LIB) $$(FRIENDS_FAKE_HELPER_LIB) $$(FRIENDS_FAKE_HELPER_EXE)
	$(FRIENDS_GTK_REQUIRE)
	@mkdir -p "$(FRIENDS_GTK_RENDERS)"
	@rm -f "$(FRIENDS_GTK_TEST)" "$(FRIENDS_GTK_PROBES)" "$(FRIENDS_GTK_QUIET)"
	clang $(FRIENDS_GTK_TEST_CFLAGS) $(FRIENDS_GTK_PKG_CFLAGS) friends/gtk/tests/szfriends_gtk_support.c \
		$(FRIENDS_GTK_TEST_SRCS) $(FRIENDS_GTK_TEST_LINK) -o "$(FRIENDS_GTK_TEST)"
	"$(FRIENDS_GTK_TEST)" friends/fixtures friends/PROTOCOL.md "$(FRIENDS_FAKE_HELPER_EXE)" \
		friends/avatars/animals/manifest.json
ifeq ($(UNAME_S),Darwin)
	clang $(FRIENDS_GTK_TEST_TARGET) -std=c11 -Wall -Wextra -Werror -dynamiclib \
		friends/gtk/tests/szfriends_gtk_quiet.c \
		-framework ApplicationServices -install_name @executable_path/libszfriends_gtk_quiet.dylib \
		-o "$(FRIENDS_GTK_QUIET)"
endif
	clang $(FRIENDS_GTK_TEST_CFLAGS) $(FRIENDS_GTK_PKG_CFLAGS) friends/gtk/tests/szfriends_gtk_support.c \
		$(FRIENDS_GTK_PROBE_SRCS) $(FRIENDS_GTK_TEST_LINK) $(FRIENDS_GTK_PROBE_LINK) -o "$(FRIENDS_GTK_PROBES)"
	"$(FRIENDS_GTK_PROBES)" friends/fixtures friends/avatars/animals/manifest.json "$(FRIENDS_GTK_RENDERS)"

# The list and Nearby pages (owner: gtk-list) have a suite of their own beside friends-gtk-check, so the pages of
# wave 6b land without sharing one recipe: SZFriendsGtkListTests needs no display (the rows' look and the arming rule,
# from the fixtures); SZFriendsGtkListProbes drives the pages against the fake helper and renders them offscreen to
# $(FRIENDS_GTK_LIST_RENDERS), with its own copy of the quiet interposer beside it.
FRIENDS_GTK_LIST_BUILD := $(FRIENDS_GTK_BUILD)/list
FRIENDS_GTK_LIST_TEST := $(FRIENDS_GTK_LIST_BUILD)/SZFriendsGtkListTests
FRIENDS_GTK_LIST_PROBES := $(FRIENDS_GTK_LIST_BUILD)/SZFriendsGtkListProbes
FRIENDS_GTK_LIST_RENDERS := $(FRIENDS_GTK_LIST_BUILD)/renders
FRIENDS_GTK_LIST_QUIET := $(FRIENDS_GTK_LIST_BUILD)/libszfriends_gtk_quiet.dylib
FRIENDS_GTK_LIST_TEST_SRCS = $(sort $(wildcard friends/gtk/tests/szfriends_gtk_list_test*.c))
FRIENDS_GTK_LIST_PROBE_SRCS = friends/gtk/tests/szfriends_gtk_probe_support.c \
	$(sort $(wildcard friends/gtk/tests/szfriends_gtk_list_probe*.c))
ifeq ($(UNAME_S),Darwin)
FRIENDS_GTK_LIST_PROBE_LINK = -L"$(FRIENDS_GTK_LIST_BUILD)" -lszfriends_gtk_quiet -framework ApplicationServices
endif

FRIENDS_TEST_TARGETS += friends-gtk-list-check
friends-gtk-list-check: $(FRIENDS_GTK_LIB) $$(FRIENDS_FAKE_HELPER_LIB)
	$(FRIENDS_GTK_REQUIRE)
	@mkdir -p "$(FRIENDS_GTK_LIST_RENDERS)"
	@rm -f "$(FRIENDS_GTK_LIST_TEST)" "$(FRIENDS_GTK_LIST_PROBES)" "$(FRIENDS_GTK_LIST_QUIET)"
	clang $(FRIENDS_GTK_TEST_CFLAGS) $(FRIENDS_GTK_PKG_CFLAGS) friends/gtk/tests/szfriends_gtk_support.c \
		$(FRIENDS_GTK_LIST_TEST_SRCS) $(FRIENDS_GTK_TEST_LINK) -o "$(FRIENDS_GTK_LIST_TEST)"
	"$(FRIENDS_GTK_LIST_TEST)" friends/fixtures
ifeq ($(UNAME_S),Darwin)
	clang $(FRIENDS_GTK_TEST_TARGET) -std=c11 -Wall -Wextra -Werror -dynamiclib \
		friends/gtk/tests/szfriends_gtk_quiet.c \
		-framework ApplicationServices -install_name @executable_path/libszfriends_gtk_quiet.dylib \
		-o "$(FRIENDS_GTK_LIST_QUIET)"
endif
	clang $(FRIENDS_GTK_TEST_CFLAGS) $(FRIENDS_GTK_PKG_CFLAGS) friends/gtk/tests/szfriends_gtk_support.c \
		$(FRIENDS_GTK_LIST_PROBE_SRCS) $(FRIENDS_GTK_TEST_LINK) $(FRIENDS_GTK_LIST_PROBE_LINK) \
		-o "$(FRIENDS_GTK_LIST_PROBES)"
	"$(FRIENDS_GTK_LIST_PROBES)" friends/fixtures friends/avatars/animals/manifest.json \
		"$(FRIENDS_GTK_LIST_RENDERS)"

# The conversation page (owner: gtk-conversation) has a suite of its own beside friends-gtk-check, as the list does:
# SZFriendsGtkConversationTests needs no display (what a click on a message's words does, the card's and the
# composer's intents, the link menu's words, previews only from the helper's cache); SZFriendsGtkConversationProbes
# drives the page against the fake helper and renders it offscreen to $(FRIENDS_GTK_CONVERSATION_RENDERS), with its
# own copy of the quiet interposer beside it.
FRIENDS_GTK_CONVERSATION_BUILD := $(FRIENDS_GTK_BUILD)/conversation
FRIENDS_GTK_CONVERSATION_TEST := $(FRIENDS_GTK_CONVERSATION_BUILD)/SZFriendsGtkConversationTests
FRIENDS_GTK_CONVERSATION_PROBES := $(FRIENDS_GTK_CONVERSATION_BUILD)/SZFriendsGtkConversationProbes
FRIENDS_GTK_CONVERSATION_RENDERS := $(FRIENDS_GTK_CONVERSATION_BUILD)/renders
FRIENDS_GTK_CONVERSATION_QUIET := $(FRIENDS_GTK_CONVERSATION_BUILD)/libszfriends_gtk_quiet.dylib
FRIENDS_GTK_CONVERSATION_TEST_SRCS = $(sort $(wildcard friends/gtk/tests/szfriends_gtk_conversation_test*.c))
# The list probes' hand-moved clock too: every Block in the views arms on that one clock.
FRIENDS_GTK_CONVERSATION_PROBE_SRCS = friends/gtk/tests/szfriends_gtk_probe_support.c \
	friends/gtk/tests/szfriends_gtk_list_probe_clock.c \
	$(sort $(wildcard friends/gtk/tests/szfriends_gtk_conversation_probe*.c))
ifeq ($(UNAME_S),Darwin)
FRIENDS_GTK_CONVERSATION_PROBE_LINK = -L"$(FRIENDS_GTK_CONVERSATION_BUILD)" -lszfriends_gtk_quiet \
	-framework ApplicationServices
endif

FRIENDS_TEST_TARGETS += friends-gtk-conversation-check
friends-gtk-conversation-check: $(FRIENDS_GTK_LIB) $$(FRIENDS_FAKE_HELPER_LIB)
	$(FRIENDS_GTK_REQUIRE)
	@mkdir -p "$(FRIENDS_GTK_CONVERSATION_RENDERS)"
	@rm -f "$(FRIENDS_GTK_CONVERSATION_TEST)" "$(FRIENDS_GTK_CONVERSATION_PROBES)" \
		"$(FRIENDS_GTK_CONVERSATION_QUIET)"
	clang $(FRIENDS_GTK_TEST_CFLAGS) $(FRIENDS_GTK_PKG_CFLAGS) friends/gtk/tests/szfriends_gtk_support.c \
		$(FRIENDS_GTK_CONVERSATION_TEST_SRCS) $(FRIENDS_GTK_TEST_LINK) -o "$(FRIENDS_GTK_CONVERSATION_TEST)"
	"$(FRIENDS_GTK_CONVERSATION_TEST)" friends/fixtures
ifeq ($(UNAME_S),Darwin)
	clang $(FRIENDS_GTK_TEST_TARGET) -std=c11 -Wall -Wextra -Werror -dynamiclib \
		friends/gtk/tests/szfriends_gtk_quiet.c \
		-framework ApplicationServices -install_name @executable_path/libszfriends_gtk_quiet.dylib \
		-o "$(FRIENDS_GTK_CONVERSATION_QUIET)"
endif
	clang $(FRIENDS_GTK_TEST_CFLAGS) $(FRIENDS_GTK_PKG_CFLAGS) friends/gtk/tests/szfriends_gtk_support.c \
		$(FRIENDS_GTK_CONVERSATION_PROBE_SRCS) $(FRIENDS_GTK_TEST_LINK) $(FRIENDS_GTK_CONVERSATION_PROBE_LINK) \
		-o "$(FRIENDS_GTK_CONVERSATION_PROBES)"
	"$(FRIENDS_GTK_CONVERSATION_PROBES)" friends/fixtures friends/avatars/animals/manifest.json \
		"$(FRIENDS_GTK_CONVERSATION_RENDERS)"

# The details, profile and Settings pages (owner: gtk-details-profile) have a suite of their own beside
# friends-gtk-check, as the list and the conversation do: SZFriendsGtkDetailsTests needs no display (the crop square,
# which photos the views decode, the arming rule, the intents built from what was typed, the QR encoder against
# libqrencode's symbols); SZFriendsGtkDetailsProbes drives the three pages against the fake helper and renders them
# offscreen to $(FRIENDS_GTK_DETAILS_RENDERS), with its own copy of the quiet interposer beside it.
FRIENDS_GTK_DETAILS_BUILD := $(FRIENDS_GTK_BUILD)/details
FRIENDS_GTK_DETAILS_TEST := $(FRIENDS_GTK_DETAILS_BUILD)/SZFriendsGtkDetailsTests
FRIENDS_GTK_DETAILS_PROBES := $(FRIENDS_GTK_DETAILS_BUILD)/SZFriendsGtkDetailsProbes
FRIENDS_GTK_DETAILS_RENDERS := $(FRIENDS_GTK_DETAILS_BUILD)/renders
FRIENDS_GTK_DETAILS_QUIET := $(FRIENDS_GTK_DETAILS_BUILD)/libszfriends_gtk_quiet.dylib
FRIENDS_GTK_DETAILS_TEST_SRCS = $(sort $(wildcard friends/gtk/tests/szfriends_gtk_details_test*.c))
# The list probes' hand-moved clock too: every Block in the views arms on that one clock.
FRIENDS_GTK_DETAILS_PROBE_SRCS = friends/gtk/tests/szfriends_gtk_probe_support.c \
	friends/gtk/tests/szfriends_gtk_list_probe_clock.c \
	$(sort $(wildcard friends/gtk/tests/szfriends_gtk_details_probe*.c))
ifeq ($(UNAME_S),Darwin)
FRIENDS_GTK_DETAILS_PROBE_LINK = -L"$(FRIENDS_GTK_DETAILS_BUILD)" -lszfriends_gtk_quiet \
	-framework ApplicationServices
endif

FRIENDS_TEST_TARGETS += friends-gtk-details-check
friends-gtk-details-check: $(FRIENDS_GTK_LIB) $$(FRIENDS_FAKE_HELPER_LIB)
	$(FRIENDS_GTK_REQUIRE)
	@mkdir -p "$(FRIENDS_GTK_DETAILS_RENDERS)"
	@rm -f "$(FRIENDS_GTK_DETAILS_TEST)" "$(FRIENDS_GTK_DETAILS_PROBES)" "$(FRIENDS_GTK_DETAILS_QUIET)"
	clang $(FRIENDS_GTK_TEST_CFLAGS) $(FRIENDS_GTK_PKG_CFLAGS) friends/gtk/tests/szfriends_gtk_support.c \
		$(FRIENDS_GTK_DETAILS_TEST_SRCS) $(FRIENDS_GTK_TEST_LINK) -o "$(FRIENDS_GTK_DETAILS_TEST)"
	"$(FRIENDS_GTK_DETAILS_TEST)" friends/fixtures
ifeq ($(UNAME_S),Darwin)
	clang $(FRIENDS_GTK_TEST_TARGET) -std=c11 -Wall -Wextra -Werror -dynamiclib \
		friends/gtk/tests/szfriends_gtk_quiet.c \
		-framework ApplicationServices -install_name @executable_path/libszfriends_gtk_quiet.dylib \
		-o "$(FRIENDS_GTK_DETAILS_QUIET)"
endif
	clang $(FRIENDS_GTK_TEST_CFLAGS) $(FRIENDS_GTK_PKG_CFLAGS) friends/gtk/tests/szfriends_gtk_support.c \
		$(FRIENDS_GTK_DETAILS_PROBE_SRCS) $(FRIENDS_GTK_TEST_LINK) $(FRIENDS_GTK_DETAILS_PROBE_LINK) \
		-o "$(FRIENDS_GTK_DETAILS_PROBES)"
	"$(FRIENDS_GTK_DETAILS_PROBES)" friends/fixtures friends/avatars/animals/manifest.json \
		"$(FRIENDS_GTK_DETAILS_RENDERS)"
