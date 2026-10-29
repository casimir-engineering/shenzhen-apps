# Shenzhen Friends helper (owner: helper area): the helper executable, its standalone bundle, and its suite.
# Included by friends/friends.mk; make runs with cwd portable/, so every path is relative to portable/.
#
# Output: $(FRIENDS_BUILD)/Shenzhen Friends.app, background-only, ad-hoc signed unless an identity is given, linked
# with every service area's objects (FRIENDS_SERVICE_OBJS) and the client library. Embedding it in an app's
# Contents/Helpers/ and signing it there is the lead's integration step. Suite: friends-helper-check.

FRIENDS_HELPER_DIR := friends/service/helper
FRIENDS_HELPER_BUILD := $(FRIENDS_BUILD)/helper
FRIENDS_HELPER_APP_NAME := Shenzhen Friends

# Version. The build number orders helpers for handover (PROTOCOL.md § Lifecycle): YYMMDDBB from the app's
# "YY.M.DD" version and build, so it increases with every release. Override all three for other hosts. It is also
# CFBundleVersion, which the views read from the embedded helper's bundle for hello.embedded_helper.build_number.
FRIENDS_HELPER_SHORT_VERSION ?= $(if $(MAC_VERSION),$(MAC_VERSION),0.0.0)
FRIENDS_HELPER_BUNDLE_VERSION ?= $(if $(MAC_BUILD),$(MAC_BUILD),0)
FRIENDS_HELPER_BUILD_NUMBER ?= $(shell echo "$(FRIENDS_HELPER_SHORT_VERSION) $(FRIENDS_HELPER_BUNDLE_VERSION)" | \
	awk '{ split($$1, v, "."); printf "%02d%02d%02d%02d", v[1] % 100, v[2], v[3], $$2 }')

# Signing: like the Collection companion, ad hoc by default; a real identity adds the hardened runtime.
FRIENDS_HELPER_SIGN_IDENTITY ?= $(if $(MAC_SIGN_IDENTITY),$(MAC_SIGN_IDENTITY),-)

# What the helper reads from its bundle at start (ADR 0002 § Bundle replacement): `source` or
# `source=destination`, the destination relative to Contents/Resources (default: the source's own name);
# directories are copied whole. Areas may append to FRIENDS_HELPER_RESOURCES. The animal set goes where
# SZFriendsAnimalSet looks in a standalone helper, and only what the app ships of it (manifest.json, svg/,
# pdf/*.pdf), not the generator's checksums or .gitignore; the host list files are the host area's
# FRIENDS_HOST_RESOURCES. Recursive '=' because host.mk sorts after this file. The word list needs nothing here: the
# identity area compiles it into the helper. Files are listed one by one, never as a directory, because the bundle
# stamp depends on each source: a directory's time changes only when a file is added or removed, so an animal edited
# in place would otherwise leave the bundle stale.
FRIENDS_HELPER_ANIMALS := friends/avatars/animals
FRIENDS_HELPER_ANIMAL_RESOURCES = $(if $(wildcard $(FRIENDS_HELPER_ANIMALS)/manifest.json), \
	$(FRIENDS_HELPER_ANIMALS)/manifest.json=Friends/animals/manifest.json \
	$(foreach svg,$(wildcard $(FRIENDS_HELPER_ANIMALS)/svg/*.svg),$(svg)=Friends/animals/svg/$(notdir $(svg))) \
	$(foreach pdf,$(wildcard $(FRIENDS_HELPER_ANIMALS)/pdf/*.pdf),$(pdf)=Friends/animals/pdf/$(notdir $(pdf))))
FRIENDS_HELPER_BUNDLE_RESOURCES = $(FRIENDS_HELPER_ANIMAL_RESOURCES) $(FRIENDS_HOST_RESOURCES) \
	$(FRIENDS_HELPER_RESOURCES)
FRIENDS_HELPER_RESOURCE_SOURCES = $(foreach r,$(FRIENDS_HELPER_BUNDLE_RESOURCES),$(firstword $(subst =, ,$(r))))

# The helper's own pure and IPC parts, which need no other service area: what the unit tests link.
FRIENDS_HELPER_CORE_NAMES := SZFriendsStatePaths SZFriendsInstanceLock SZFriendsHelperPolicy SZFriendsPeerCheck \
	SZFriendsHelperSupport SZFriendsClientContext SZFriendsIPCConnection SZFriendsIPCServer SZFriendsHelperLifecycle
# The dispatch layer and startup, which reach every other area through its header.
FRIENDS_HELPER_DISPATCH_NAMES := SZFriendsHelperServices SZFriendsHelperFacts SZFriendsSubscriptions \
	SZFriendsIntentRouter SZFriendsIntentRouter+Profile SZFriendsIntentRouter+People SZFriendsIntentRouter+Content \
	SZFriendsIntentRouter+History \
	SZFriendsIntentRouter+Cancel SZFriendsIntentRouter+Mentions SZFriendsIntentRouter+Links SZFriendsHelperLinks \
	SZFriendsIntentRouter+Join SZFriendsIntentRouter+Devices SZFriendsIntentRouter+Reset \
	SZFriendsIntentRouter+Notifications SZFriendsHostCheckIn SZFriendsHelperMain
# Nearby orchestration (nearby/): discovery, sessions, delivery and transfers wired together for the helper.
FRIENDS_HELPER_NEARBY_SRCS := $(sort $(wildcard $(FRIENDS_HELPER_DIR)/nearby/*.m))
FRIENDS_HELPER_NEARBY_OBJS := $(patsubst $(FRIENDS_HELPER_DIR)/nearby/%.m,$(FRIENDS_HELPER_BUILD)/obj/nearby/%.o,\
	$(FRIENDS_HELPER_NEARBY_SRCS))
FRIENDS_HELPER_UNIT_OBJS := $(patsubst %,$(FRIENDS_HELPER_BUILD)/obj/%.o,$(FRIENDS_HELPER_CORE_NAMES))
FRIENDS_HELPER_OBJS := $(FRIENDS_HELPER_UNIT_OBJS) \
	$(patsubst %,$(FRIENDS_HELPER_BUILD)/obj/%.o,$(FRIENDS_HELPER_DISPATCH_NAMES)) $(FRIENDS_HELPER_NEARBY_OBJS)
FRIENDS_HELPER_MAIN_OBJ := $(FRIENDS_HELPER_BUILD)/obj/main.o
# Every Friends header: the helper includes most of them, and a changed contract must rebuild it.
FRIENDS_HELPER_HDRS := $(sort $(wildcard $(FRIENDS_HELPER_DIR)/*.h $(FRIENDS_HELPER_DIR)/nearby/*.h \
	friends/service/*/*.h friends/avatars/*.h friends/client/*.h))

$(FRIENDS_HELPER_BUILD)/obj/nearby/%.o: $(FRIENDS_HELPER_DIR)/nearby/%.m $(FRIENDS_HELPER_HDRS) \
		$(FRIENDS_HELPER_DIR)/helper.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -c "$<" -o "$@"

$(FRIENDS_HELPER_BUILD)/obj/%.o: $(FRIENDS_HELPER_DIR)/%.m $(FRIENDS_HELPER_HDRS) $(FRIENDS_HELPER_DIR)/helper.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -c "$<" -o "$@"

# IOKit for sleep and wake (nearby/SZFriendsWakeMonitor.m): the helper links no UI toolkit, so no NSWorkspace.
# UserNotifications posts its notifications and CoreServices' LaunchServices opens their clicks (service/notify/).
FRIENDS_HELPER_FRAMEWORKS := -framework Foundation -framework Security -framework IOKit -framework UserNotifications \
	-framework CoreServices -framework CoreWLAN -framework CoreLocation
FRIENDS_HELPER_EXE := $(FRIENDS_HELPER_BUILD)/szfriends-helper
$(FRIENDS_HELPER_EXE): $(FRIENDS_HELPER_OBJS) $(FRIENDS_HELPER_MAIN_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ) \
		$$(FRIENDS_SERVICE_OBJS) $$(FRIENDS_CLIENT_OBJS)
	@mkdir -p "$(@D)"
	clang $(MAC_TARGET_FLAGS) -fobjc-arc $(FRIENDS_HELPER_OBJS) $(FRIENDS_HELPER_MAIN_OBJ) $(FRIENDS_SERVICE_OBJS) \
		$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		$(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$@"

# Stamps stand in for the bundle as a make target: make cannot name a path with a space in it.
FRIENDS_HELPER_APP := $(FRIENDS_BUILD)/$(FRIENDS_HELPER_APP_NAME).app
FRIENDS_HELPER_BUNDLE_STAMP := $(FRIENDS_HELPER_BUILD)/bundle.stamp
FRIENDS_HELPER_PLIST = "$(FRIENDS_HELPER_APP)/Contents/Info.plist"
# Licences of what the executable links, as Contents/Resources/Licenses/<name>.txt: libsodium and cJSON, the
# online transport's stack (ADR 0009 § Licences), and miniupnpc for the NAT techniques' UPnP. Mbed TLS's LICENSE
# holds both of its licences (Apache-2.0, which Friends uses, and GPL-2.0-or-later), and goes whole.
FRIENDS_HELPER_LICENSES := ../ext/libsodium/LICENSE=libsodium ../ext/cjson/LICENSE=cJSON \
	../ext/libdatachannel/LICENSE=libdatachannel ../ext/libjuice/LICENSE=libjuice ../ext/usrsctp/LICENSE.md=usrsctp \
	../ext/plog/LICENSE=plog ../ext/mbedtls/LICENSE=mbedtls ../ext/miniupnpc/LICENSE=miniupnpc
# The icon notification banners show beside "Shenzhen Friends" (CFBundleIconFile), made from AppIcon.svg.
FRIENDS_HELPER_ICON := $(FRIENDS_HELPER_DIR)/AppIcon.icns
$(FRIENDS_HELPER_BUNDLE_STAMP): $(FRIENDS_HELPER_EXE) $(FRIENDS_HELPER_DIR)/Info.plist $(FRIENDS_HELPER_DIR)/helper.mk \
		$(FRIENDS_HELPER_ICON) \
		$(foreach license,$(FRIENDS_HELPER_LICENSES),$(firstword $(subst =, ,$(license)))) \
		$$(FRIENDS_HELPER_RESOURCE_SOURCES)
	rm -rf "$(FRIENDS_HELPER_APP)"
	mkdir -p "$(FRIENDS_HELPER_APP)/Contents/MacOS" "$(FRIENDS_HELPER_APP)/Contents/Resources/Licenses"
	cp "$(FRIENDS_HELPER_DIR)/Info.plist" $(FRIENDS_HELPER_PLIST)
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(FRIENDS_HELPER_SHORT_VERSION)" $(FRIENDS_HELPER_PLIST)
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(FRIENDS_HELPER_BUILD_NUMBER)" $(FRIENDS_HELPER_PLIST)
	/usr/libexec/PlistBuddy -c "Set :SZFriendsBuildNumber $(FRIENDS_HELPER_BUILD_NUMBER)" $(FRIENDS_HELPER_PLIST)
	plutil -lint -s $(FRIENDS_HELPER_PLIST)
	cp "$(FRIENDS_HELPER_EXE)" "$(FRIENDS_HELPER_APP)/Contents/MacOS/$(FRIENDS_HELPER_APP_NAME)"
	cp "$(FRIENDS_HELPER_ICON)" "$(FRIENDS_HELPER_APP)/Contents/Resources/AppIcon.icns"
	@for entry in $(FRIENDS_HELPER_LICENSES); do \
		echo "cp $${entry%%=*} Licenses/$${entry#*=}.txt"; \
		cp "$${entry%%=*}" "$(FRIENDS_HELPER_APP)/Contents/Resources/Licenses/$${entry#*=}.txt" || exit 1; \
	done
	@for entry in $(FRIENDS_HELPER_BUNDLE_RESOURCES); do \
		source=$${entry%%=*}; destination=$${entry#*=}; \
		[ "$$destination" = "$$entry" ] && destination=$$(basename "$$source"); \
		mkdir -p "$$(dirname "$(FRIENDS_HELPER_APP)/Contents/Resources/$$destination")"; \
		echo "cp -R $$source Resources/$$destination"; \
		cp -R "$$source" "$(FRIENDS_HELPER_APP)/Contents/Resources/$$destination" || exit 1; \
	done
	xattr -cr "$(FRIENDS_HELPER_APP)"
	@if [ "$(FRIENDS_HELPER_SIGN_IDENTITY)" = "-" ]; then \
		echo 'codesign --force --sign - "$(FRIENDS_HELPER_APP)"'; codesign --force --sign - "$(FRIENDS_HELPER_APP)"; \
	else \
		codesign --force --timestamp --options runtime --sign "$(FRIENDS_HELPER_SIGN_IDENTITY)" "$(FRIENDS_HELPER_APP)"; \
	fi
	@touch "$@"

.PHONY: friends-helper-bundle friends-helper-check
friends-helper-bundle: $(FRIENDS_HELPER_BUNDLE_STAMP)

# Tests are compiled inside the target (make skips a rebuild when source and binary share an mtime second). The
# process tests link the same service objects as the helper, so they can seed a store the helper then opens.
FRIENDS_HELPER_TEST_DIR := $(FRIENDS_HELPER_DIR)/tests
FRIENDS_HELPER_UNIT_TEST := $(FRIENDS_HELPER_BUILD)/SZFriendsHelperUnitTests
FRIENDS_HELPER_PROCESS_SRCS := $(sort $(wildcard $(FRIENDS_HELPER_TEST_DIR)/SZFriendsHelperProcess*.m))
FRIENDS_HELPER_PROCESS_TEST := $(FRIENDS_HELPER_BUILD)/SZFriendsHelperProcessTests
FRIENDS_HELPER_NEARBY_TEST := $(FRIENDS_HELPER_BUILD)/SZFriendsHelperNearbyTests
FRIENDS_HELPER_NEARBY_TEST_SRCS := $(sort $(wildcard $(FRIENDS_HELPER_TEST_DIR)/SZFriendsHelperNearby*.m))
FRIENDS_HELPER_TEST_FLAGS = $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS)

FRIENDS_TEST_TARGETS += friends-helper-check
friends-helper-check: $(FRIENDS_HELPER_OBJS) $(FRIENDS_HELPER_BUNDLE_STAMP) \
		$(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ) $$(FRIENDS_SERVICE_OBJS) $$(FRIENDS_CLIENT_OBJS)
	@rm -f "$(FRIENDS_HELPER_UNIT_TEST)" "$(FRIENDS_HELPER_PROCESS_TEST)" "$(FRIENDS_HELPER_NEARBY_TEST)"
	@# The bundle stamp depends on every animal file it copies, so editing one rebuilds the bundle.
	@missing="$(filter-out $(FRIENDS_HELPER_RESOURCE_SOURCES),$(wildcard $(FRIENDS_HELPER_ANIMALS)/svg/*.svg \
		$(FRIENDS_HELPER_ANIMALS)/pdf/*.pdf))"; \
		test -z "$$missing" || { echo "the helper bundle stamp does not track: $$missing" >&2; exit 1; }
	clang $(FRIENDS_HELPER_TEST_FLAGS) $(FRIENDS_HELPER_TEST_DIR)/SZFriendsHelperUnitTests.m \
		$(FRIENDS_HELPER_UNIT_OBJS) $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_HELPER_FRAMEWORKS) \
		-o "$(FRIENDS_HELPER_UNIT_TEST)"
	"$(FRIENDS_HELPER_UNIT_TEST)" friends/fixtures
	clang $(FRIENDS_HELPER_TEST_FLAGS) $(FRIENDS_HELPER_PROCESS_SRCS) $(FRIENDS_SERVICE_OBJS) $(FRIENDS_CLIENT_OBJS) \
		$(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		$(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_HELPER_PROCESS_TEST)"
	"$(FRIENDS_HELPER_PROCESS_TEST)" "$(FRIENDS_HELPER_APP)" friends/fixtures
	clang $(FRIENDS_HELPER_TEST_FLAGS) $(FRIENDS_HELPER_NEARBY_TEST_SRCS) $(FRIENDS_HELPER_OBJS) \
		$(FRIENDS_SERVICE_OBJS) $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		$(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(FRIENDS_HELPER_NEARBY_TEST)"
	"$(FRIENDS_HELPER_NEARBY_TEST)"
