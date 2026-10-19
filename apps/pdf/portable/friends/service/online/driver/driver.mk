# Shenzhen Friends online driver (owner: driver area): the helper's Internet attempts toward friends, joining the host's
# protocol 2, the signalling, the route order, the transport and the NAT techniques (SZFriendsOnlineDriver.h), in
# friends/service/online/driver/. Included by friends/friends.mk through its own line, after the transport's, NAT's
# and order's makefiles; make runs with cwd portable/, so every path is relative to it. Suite: friends-driver-check.

FRIENDS_DRIVER_DIR := friends/service/online/driver
FRIENDS_DRIVER_BUILD := $(FRIENDS_BUILD)/online/driver
FRIENDS_DRIVER_SRCS := $(sort $(wildcard $(FRIENDS_DRIVER_DIR)/*.m))
# Every header an attempt reaches: the online areas', the host's and the session's.
FRIENDS_DRIVER_HDRS := $(sort $(wildcard $(FRIENDS_DRIVER_DIR)/*.h friends/service/online/*.h \
	friends/service/online/*/*.h friends/service/host/*.h friends/service/session/*.h \
	friends/service/identity/*.h friends/service/discovery/SZFriendsDiscovery.h))
FRIENDS_DRIVER_OBJS := $(patsubst $(FRIENDS_DRIVER_DIR)/%.m,$(FRIENDS_DRIVER_BUILD)/%.o,$(FRIENDS_DRIVER_SRCS))

FRIENDS_SERVICE_OBJS += $(FRIENDS_DRIVER_OBJS)
FRIENDS_PUBLIC_HEADERS += $(FRIENDS_DRIVER_DIR)/SZFriendsOnlineDriver.h

$(FRIENDS_DRIVER_BUILD)/%.o: $(FRIENDS_DRIVER_DIR)/%.m $(FRIENDS_DRIVER_HDRS) $(FRIENDS_DRIVER_DIR)/driver.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -c "$<" -o "$@"

# The suite links every service object (the real transport, signalling, order and NAT techniques) and joins two
# attempts in memory, without the host: on loopback only, with the transport bound to 127.0.0.1. The relay scenario
# needs a coturn built from pinned source, named by FRIENDS_TEST_COTURN (server/friends/README.md § Testing); without
# it that scenario skips and says so. Compiled inside the phony target after an rm, so a stale binary never passes.
FRIENDS_DRIVER_TEST := $(FRIENDS_DRIVER_BUILD)/SZFriendsOnlineDriverTests
FRIENDS_DRIVER_TEST_SRCS = $(sort $(wildcard $(FRIENDS_DRIVER_DIR)/tests/*.m))

ifeq ($(UNAME_S),Darwin)
FRIENDS_TEST_TARGETS += friends-driver-check
endif
.PHONY: friends-driver-check
friends-driver-check: $$(FRIENDS_SERVICE_OBJS) $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ)
	@mkdir -p "$(FRIENDS_DRIVER_BUILD)"
	@rm -f "$(FRIENDS_DRIVER_TEST)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -I$(FRIENDS_DRIVER_DIR)/tests \
		$(FRIENDS_DRIVER_TEST_SRCS) $(FRIENDS_SERVICE_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) \
		$(FRIENDS_SERVICE_LIBS) -framework Foundation -framework Security -framework LocalAuthentication \
		-framework IOKit -Wl,-dead_strip -o "$(FRIENDS_DRIVER_TEST)"
	"$(FRIENDS_DRIVER_TEST)"
