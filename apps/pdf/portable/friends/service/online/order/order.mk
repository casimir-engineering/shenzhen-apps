# Shenzhen Friends online order (owner: route order area): the phases, timers, leaving the relay and the technique
# log of an Internet attempt (ADR 0011), in friends/service/online/order/. Pure: no sockets and no stack, so its
# objects need only Foundation. Included by friends/friends.mk through its own line (the area-makefile wildcard
# reaches three levels down); make runs with cwd portable/, so every path is relative to it. Suite:
# friends-order-check, a scripted clock throughout, nothing on the network.

FRIENDS_ORDER_DIR := friends/service/online/order
FRIENDS_ORDER_BUILD := $(FRIENDS_BUILD)/online/order
FRIENDS_ORDER_SRCS := $(sort $(wildcard $(FRIENDS_ORDER_DIR)/*.m))
FRIENDS_ORDER_HDRS := $(sort $(wildcard $(FRIENDS_ORDER_DIR)/*.h)) friends/service/online/SZFriendsOnlineTransport.h \
	friends/service/online/nat/SZFriendsNAT.h friends/service/discovery/SZFriendsDiscovery.h \
	friends/service/session/SZFriendsSession.h
FRIENDS_ORDER_OBJS := $(patsubst $(FRIENDS_ORDER_DIR)/%.m,$(FRIENDS_ORDER_BUILD)/%.o,$(FRIENDS_ORDER_SRCS))

FRIENDS_SERVICE_OBJS += $(FRIENDS_ORDER_OBJS)
FRIENDS_PUBLIC_HEADERS += $(FRIENDS_ORDER_DIR)/SZFriendsOnlineOrder.h

$(FRIENDS_ORDER_BUILD)/%.o: $(FRIENDS_ORDER_DIR)/%.m $(FRIENDS_ORDER_HDRS) $(FRIENDS_ORDER_DIR)/order.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) -c "$<" -o "$@"

# The test is compiled inside the phony target, after an rm, so a stale binary can never pass for a new one.
FRIENDS_ORDER_TEST := $(FRIENDS_ORDER_BUILD)/SZFriendsOnlineOrderTests
FRIENDS_ORDER_TEST_SRCS = $(sort $(wildcard $(FRIENDS_ORDER_DIR)/tests/*.m))

FRIENDS_TEST_TARGETS += friends-order-check
.PHONY: friends-order-check
friends-order-check:
	@mkdir -p "$(FRIENDS_ORDER_BUILD)"
	@rm -f "$(FRIENDS_ORDER_TEST)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) -I$(FRIENDS_ORDER_DIR)/tests $(FRIENDS_ORDER_SRCS) \
		$(FRIENDS_ORDER_TEST_SRCS) -framework Foundation -o "$(FRIENDS_ORDER_TEST)"
	"$(FRIENDS_ORDER_TEST)"
