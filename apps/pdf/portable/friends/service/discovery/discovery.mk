# Shenzhen Friends nearby discovery (owner: discovery area). Included by friends/friends.mk; cwd is portable/.
#
# Production objects go to FRIENDS_SERVICE_OBJS for the helper. The suite builds two test programs:
#   SZFriendsDiscoveryTests      pure and scripted: tags, merger, racer, visibility, coordinator, the Bluetooth
#                                adapter over a fake radio, streams, TXT records. No radios at all.
#   SZFriendsNetworkAdapterTests two real Network.framework adapters on the loopback interface only; skips with
#                                a message if mDNS does not answer there within 8 s.
# No test creates a Bluetooth manager or touches a non-loopback interface (hardware-matrix.md covers those).

FRIENDS_DISCOVERY_DIR := friends/service/discovery
FRIENDS_DISCOVERY_BUILD := $(FRIENDS_BUILD)/discovery

FRIENDS_DISCOVERY_SRCS := $(addprefix $(FRIENDS_DISCOVERY_DIR)/, \
	SZFriendsPresence.m \
	SZFriendsDiscoveryMerger.m \
	SZFriendsRouteRacer.m \
	SZFriendsVisibility.m \
	SZFriendsDiscoveryCoordinator.m \
	SZFriendsNetworkTXT.m \
	SZFriendsNetworkStream.m \
	SZFriendsNetworkAdapter.m \
	SZFriendsNetworkAdapter+Browse.m \
	SZFriendsAdmission.m \
	SZFriendsBluetoothPresence.m \
	SZFriendsBluetoothAdapter.m \
	SZFriendsCoreBluetoothRadio.m \
	SZFriendsCoreBluetoothRadio+Central.m \
	SZFriendsRunLoopByteStream.m)
# The session header is included for SZFriendsByteStream only; no session object is linked.
FRIENDS_DISCOVERY_HDRS := $(wildcard $(FRIENDS_DISCOVERY_DIR)/*.h) friends/service/session/SZFriendsSession.h
FRIENDS_DISCOVERY_OBJS := \
	$(patsubst $(FRIENDS_DISCOVERY_DIR)/%.m,$(FRIENDS_DISCOVERY_BUILD)/%.o,$(FRIENDS_DISCOVERY_SRCS))
FRIENDS_DISCOVERY_FRAMEWORKS := -framework Foundation -framework Network -framework CoreBluetooth

FRIENDS_PUBLIC_HEADERS += friends/service/discovery/SZFriendsDiscoveryCoordinator.h
FRIENDS_SERVICE_OBJS += $(FRIENDS_DISCOVERY_OBJS)
FRIENDS_SERVICE_LIBS += -framework Network -framework CoreBluetooth

$(FRIENDS_DISCOVERY_BUILD)/%.o: $(FRIENDS_DISCOVERY_DIR)/%.m $(FRIENDS_DISCOVERY_HDRS) \
		$(FRIENDS_DISCOVERY_DIR)/discovery.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -c "$<" -o "$@"

FRIENDS_DISCOVERY_TEST := $(FRIENDS_DISCOVERY_BUILD)/SZFriendsDiscoveryTests
FRIENDS_DISCOVERY_TEST_SRCS := $(addprefix $(FRIENDS_DISCOVERY_DIR)/tests/, \
	SZFriendsDiscoveryTests.m \
	SZFriendsDiscoveryTestSupport.m \
	SZFriendsRacerTests.m \
	SZFriendsMergerTests.m \
	SZFriendsCoordinatorTests.m \
	SZFriendsBluetoothAdapterTests.m \
	SZFriendsBluetoothTestRadio.m \
	SZFriendsBluetoothVisibilityTests.m \
	SZFriendsAdmissionTests.m \
	SZFriendsStreamTests.m)
FRIENDS_DISCOVERY_NETWORK_TEST := $(FRIENDS_DISCOVERY_BUILD)/SZFriendsNetworkAdapterTests
FRIENDS_DISCOVERY_NETWORK_TEST_SRCS := $(addprefix $(FRIENDS_DISCOVERY_DIR)/tests/, \
	SZFriendsNetworkAdapterTests.m \
	SZFriendsDiscoveryTestSupport.m)

FRIENDS_TEST_TARGETS += friends-discovery-check
.PHONY: friends-discovery-check
# Test programs are compiled inside the recipe, after an rm, so a stale binary can never pass for a new one (make
# skips a rebuild when source and binary share an mtime second).
friends-discovery-check: $(FRIENDS_DISCOVERY_OBJS) $(FRIENDS_SODIUM_LIB)
	@mkdir -p "$(FRIENDS_DISCOVERY_BUILD)"
	@rm -f "$(FRIENDS_DISCOVERY_TEST)" "$(FRIENDS_DISCOVERY_NETWORK_TEST)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -I$(FRIENDS_DISCOVERY_DIR)/tests \
		$(FRIENDS_DISCOVERY_TEST_SRCS) $(FRIENDS_DISCOVERY_OBJS) $(FRIENDS_SODIUM_LIB) $(FRIENDS_DISCOVERY_FRAMEWORKS) \
		-o "$(FRIENDS_DISCOVERY_TEST)"
	"$(FRIENDS_DISCOVERY_TEST)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -I$(FRIENDS_DISCOVERY_DIR)/tests \
		$(FRIENDS_DISCOVERY_NETWORK_TEST_SRCS) $(FRIENDS_DISCOVERY_OBJS) $(FRIENDS_SODIUM_LIB) \
		$(FRIENDS_DISCOVERY_FRAMEWORKS) -o "$(FRIENDS_DISCOVERY_NETWORK_TEST)"
	"$(FRIENDS_DISCOVERY_NETWORK_TEST)"
