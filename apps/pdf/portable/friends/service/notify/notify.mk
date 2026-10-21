# Shenzhen Friends system notifications on a Mac (owner: helper area): the notifier, this Mac's settings, the test
# home's JSON-lines sink and the UNUserNotificationCenter poster (SZFriendsNotify.h, ADR 0017). Included by
# friends/friends.mk; make runs with cwd portable/. The objects join FRIENDS_SERVICE_OBJS, which the helper links.

FRIENDS_NOTIFY_DIR := friends/service/notify
FRIENDS_NOTIFY_BUILD := $(FRIENDS_BUILD)/notify
FRIENDS_NOTIFY_SRCS := $(sort $(wildcard $(FRIENDS_NOTIFY_DIR)/*.m))
FRIENDS_NOTIFY_OBJS := $(patsubst $(FRIENDS_NOTIFY_DIR)/%.m,$(FRIENDS_NOTIFY_BUILD)/%.o,$(FRIENDS_NOTIFY_SRCS))
FRIENDS_NOTIFY_HDRS := $(wildcard $(FRIENDS_NOTIFY_DIR)/*.h) friends/service/store/SZFriendsStore.h \
	friends/service/store/SZFriendsStoreSync.h friends/service/store/SZFriendsTransfers.h \
	friends/service/presentation/SZFriendsPresentation.h \
	friends/service/presentation/SZFriendsPresentationNotifications.h friends/client/szfriends_client.h
# UserNotifications posts; CoreServices' LaunchServices opens a click's URL in the remembered app.
FRIENDS_NOTIFY_LIBS := -framework UserNotifications -framework CoreServices

FRIENDS_SERVICE_OBJS += $(FRIENDS_NOTIFY_OBJS)
FRIENDS_SERVICE_LIBS += $(FRIENDS_NOTIFY_LIBS)
FRIENDS_PUBLIC_HEADERS += $(FRIENDS_NOTIFY_DIR)/SZFriendsNotify.h

$(FRIENDS_NOTIFY_BUILD)/%.o: $(FRIENDS_NOTIFY_DIR)/%.m $(FRIENDS_NOTIFY_HDRS) $(FRIENDS_NOTIFY_DIR)/notify.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) -c "$<" -o "$@"

# The suite drives the notifier with a real store in a scratch directory and the JSON-lines sink: never the
# notification centre. It links every service object, as the helper's process tests do. Compiled inside the phony
# target: make skips a rebuild when source and binary share an mtime second.
FRIENDS_NOTIFY_TEST := $(FRIENDS_NOTIFY_BUILD)/SZFriendsNotifyTests
FRIENDS_TEST_TARGETS += friends-notify-check
.PHONY: friends-notify-check
friends-notify-check: $$(FRIENDS_SERVICE_OBJS) $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ) $$(FRIENDS_CLIENT_OBJS)
	@mkdir -p "$(FRIENDS_NOTIFY_BUILD)"
	@rm -f "$(FRIENDS_NOTIFY_TEST)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) \
		$(sort $(wildcard $(FRIENDS_NOTIFY_DIR)/tests/*.m)) $(FRIENDS_SERVICE_OBJS) $(FRIENDS_CLIENT_OBJS) \
		$(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) -framework Foundation -Wl,-dead_strip \
		-o "$(FRIENDS_NOTIFY_TEST)"
	"$(FRIENDS_NOTIFY_TEST)"
