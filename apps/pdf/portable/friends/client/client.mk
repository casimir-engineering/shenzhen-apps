# Shenzhen Friends client library and fake helper (owner: protocol area). Make runs with cwd portable/.
#
# Outputs for other areas:
#   FRIENDS_CLIENT_OBJS        the C client library; link it with $(FRIENDS_CJSON_OBJ) (views, helper, apps)
#   FRIENDS_FAKE_HELPER_LIB    the fake helper as a static library for views' and host-adapter tests
#   FRIENDS_FAKE_HELPER_EXE    the fake helper as a process (spawn tests, GTK view development)
#   FRIENDS_FAKE_HELPER_LINK   everything a test links to run the fake in-process (add -Ifriends to compile
#                              against client/fake/szfriends_fake_helper.h)
# Name them as $$(FRIENDS_...) in prerequisite lists (friends.mk § second expansion).

FRIENDS_CLIENT_SRCS := \
	friends/client/szfriends_paths.c \
	friends/client/szfriends_framing.c \
	friends/client/szfriends_socket.c \
	friends/client/szfriends_signing.c \
	friends/client/szfriends_spawn.c \
	friends/client/szfriends_client.c \
	friends/client/szfriends_client_io.c \
	friends/client/szfriends_intents.c \
	friends/client/szfriends_intents_links.c
FRIENDS_CLIENT_LIB_OBJS := $(patsubst friends/client/%.c,$(FRIENDS_BUILD)/client/%.o,$(FRIENDS_CLIENT_SRCS))
FRIENDS_CLIENT_HDRS := friends/client/szfriends_client.h friends/client/szfriends_client_internal.h \
	friends/client/szfriends_intent_build.h
FRIENDS_CLIENT_OBJS += $(FRIENDS_CLIENT_LIB_OBJS)

FRIENDS_FAKE_HELPER_SRCS := \
	friends/client/fake/szfriends_fake_helper.c \
	friends/client/fake/szfriends_fake_protocol.c \
	friends/client/fake/szfriends_fake_fixtures.c \
	friends/client/fake/szfriends_fake_scripting.c
FRIENDS_FAKE_HELPER_OBJS := $(patsubst friends/client/fake/%.c,$(FRIENDS_BUILD)/client-fake/%.o,\
	$(FRIENDS_FAKE_HELPER_SRCS))
FRIENDS_FAKE_HELPER_HDRS := $(FRIENDS_CLIENT_HDRS) friends/client/fake/szfriends_fake_helper.h \
	friends/client/fake/szfriends_fake_internal.h
FRIENDS_FAKE_HELPER_LIB := $(FRIENDS_BUILD)/client-fake/libszfriends_fake_helper.a
FRIENDS_FAKE_HELPER_EXE := $(FRIENDS_BUILD)/client-fake/szfriends-fake-helper
FRIENDS_FAKE_HELPER_LINK = $(FRIENDS_FAKE_HELPER_LIB) $(FRIENDS_CLIENT_LIB_OBJS) $(FRIENDS_CJSON_OBJ) -lpthread

FRIENDS_PUBLIC_HEADERS += friends/client/fake/szfriends_fake_helper.h

# The app's optimization level, so the library the reader links is the one the tests exercised.
FRIENDS_CLIENT_CFLAGS = $(FRIENDS_C_FLAGS) $(PORTABLE_OPTFLAGS) $(FRIENDS_CJSON_CFLAGS)

$(FRIENDS_BUILD)/client/%.o: friends/client/%.c $(FRIENDS_CLIENT_HDRS) $(FRIENDS_CJSON_OBJ) friends/client/client.mk
	@mkdir -p "$(@D)"
	clang $(FRIENDS_CLIENT_CFLAGS) -c "$<" -o "$@"

$(FRIENDS_BUILD)/client-fake/%.o: friends/client/fake/%.c $(FRIENDS_FAKE_HELPER_HDRS) friends/client/client.mk
	@mkdir -p "$(@D)"
	clang $(FRIENDS_CLIENT_CFLAGS) -c "$<" -o "$@"

# Removed first so an object dropped from the list cannot survive as a stale archive member.
$(FRIENDS_FAKE_HELPER_LIB): $(FRIENDS_FAKE_HELPER_OBJS)
	@mkdir -p "$(@D)"
	@rm -f "$@"
	ar rcs "$@" $(FRIENDS_FAKE_HELPER_OBJS)

$(FRIENDS_FAKE_HELPER_EXE): friends/client/fake/szfriends_fake_main.c $(FRIENDS_FAKE_HELPER_LIB) \
		$(FRIENDS_CLIENT_LIB_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_FAKE_HELPER_HDRS)
	@mkdir -p "$(@D)"
	clang $(FRIENDS_CLIENT_CFLAGS) friends/client/fake/szfriends_fake_main.c $(FRIENDS_FAKE_HELPER_LINK) -o "$@"

.PHONY: friends-client friends-client-check
friends-client: $(FRIENDS_CLIENT_LIB_OBJS) $(FRIENDS_FAKE_HELPER_LIB) $(FRIENDS_FAKE_HELPER_EXE)

# The test binary is compiled inside the phony target (README § Building and testing): make skips a rebuild when
# source and binary share an mtime second. It gets the fixtures and the fake helper executable to spawn.
FRIENDS_CLIENT_TEST := $(FRIENDS_BUILD)/client/SZFriendsClientTests
FRIENDS_CLIENT_TEST_SRCS = $(sort $(wildcard friends/client/tests/*.c))
FRIENDS_TEST_TARGETS += friends-client-check
friends-client-check: $(FRIENDS_CLIENT_LIB_OBJS) $(FRIENDS_FAKE_HELPER_LIB) $(FRIENDS_FAKE_HELPER_EXE) \
		$(FRIENDS_CJSON_OBJ)
	@mkdir -p "$(FRIENDS_BUILD)/client"
	@rm -f "$(FRIENDS_CLIENT_TEST)"
	clang $(FRIENDS_C_FLAGS) $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_CJSON_CFLAGS) $(FRIENDS_CLIENT_TEST_SRCS) \
		$(FRIENDS_FAKE_HELPER_LINK) -o "$(FRIENDS_CLIENT_TEST)"
	"$(FRIENDS_CLIENT_TEST)" friends/fixtures "$(FRIENDS_FAKE_HELPER_EXE)"
