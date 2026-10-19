# Shenzhen Friends host area: the helper's host client (friends/service/host/) and the Node.js host service
# (server/friends/). Included by friends/friends.mk; make runs with cwd portable/.
#
#   friends-host-check         the helper's client: unit tests with a scripted socket, then the same client against
#                              the Node service on loopback (needs Node.js, like the next suite)
#   friends-host-server-check  the service's own node:test suite (npm test)
#   friends-host-release-check NOT a test suite: fails while the helper pins a test key or ships a bundled list
#                              that does not verify. Run it before a release; it fails today by design.

FRIENDS_HOST_DIR := friends/service/host
FRIENDS_HOST_SERVER_DIR := server/friends
FRIENDS_HOST_BUILD := $(FRIENDS_BUILD)/service/host
FRIENDS_HOST_SRCS := $(sort $(wildcard $(FRIENDS_HOST_DIR)/*.m))
FRIENDS_HOST_HDRS := $(FRIENDS_HOST_DIR)/SZFriendsHostConnection.h $(FRIENDS_HOST_DIR)/SZFriendsHostInternal.h \
	$(FRIENDS_HOST_DIR)/SZFriendsCheckInClientPrivate.h friends/service/identity/SZFriendsIdentity.h
FRIENDS_HOST_OBJS := $(patsubst $(FRIENDS_HOST_DIR)/%.m,$(FRIENDS_HOST_BUILD)/%.o,$(FRIENDS_HOST_SRCS))

# The helper bundle copies these into its Resources: the signed bootstrap list (the floor and the first hosts to
# try) and the pinned host-list keys. Both are TEST material today; see resources/README.md.
FRIENDS_HOST_RESOURCES := $(FRIENDS_HOST_DIR)/resources/bootstrap-hosts.json \
	$(FRIENDS_HOST_DIR)/resources/pinned-keys.json

FRIENDS_SERVICE_OBJS += $(FRIENDS_HOST_OBJS)
FRIENDS_SERVICE_LIBS += -framework Foundation -framework Network

$(FRIENDS_HOST_BUILD)/%.o: $(FRIENDS_HOST_DIR)/%.m $(FRIENDS_HOST_HDRS) $(FRIENDS_HOST_DIR)/host.mk
	@mkdir -p "$(@D)"
	clang $(FRIENDS_OBJC_FLAGS) $(PORTABLE_OPTFLAGS) $(FRIENDS_SODIUM_CFLAGS) -c "$<" -o "$@"

# Node.js 22.16 is the floor (ADR 0005: node:sqlite unflagged with its busy timeout). The suites fail rather than
# skip without it, so a machine that cannot run them never reports the host as tested.
.PHONY: friends-host-node friends-host-check friends-host-server-check friends-host-release-check
friends-host-node:
	@command -v node >/dev/null 2>&1 || { echo "friends-host: Node.js 22.16 or later must be on PATH to test the \
	Friends host (brew install node); these suites never skip." >&2; exit 1; }
	@node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && \
	b >= 16) ? 0 : 1)' || { echo "friends-host: Node.js 22.16 or later is required; found $$(node --version)." >&2; \
	exit 1; }

# npm ci installs exactly the lockfile (ws, verified against its sha512 integrity); rerun only when it changes.
$(FRIENDS_HOST_SERVER_DIR)/node_modules/.package-lock.json: $(FRIENDS_HOST_SERVER_DIR)/package-lock.json \
		$(FRIENDS_HOST_SERVER_DIR)/package.json | friends-host-node
	cd "$(FRIENDS_HOST_SERVER_DIR)" && npm ci --no-audit --no-fund --prefer-offline
	@touch "$@"

FRIENDS_TEST_TARGETS += friends-host-server-check
friends-host-server-check: friends-host-node $(FRIENDS_HOST_SERVER_DIR)/node_modules/.package-lock.json
	cd "$(FRIENDS_HOST_SERVER_DIR)" && npm test

# Compiled on every run (make skips a rebuild when source and binary share an mtime second). The test links the
# area's production objects with fakes of the identity header, never another area's code.
FRIENDS_HOST_TEST := $(FRIENDS_HOST_BUILD)/SZFriendsHostTests
FRIENDS_HOST_TEST_SRCS := $(sort $(wildcard $(FRIENDS_HOST_DIR)/tests/*.m))
FRIENDS_TEST_TARGETS += friends-host-check
friends-host-check: $(FRIENDS_HOST_OBJS) $(FRIENDS_SODIUM_LIB) friends-host-node \
		$(FRIENDS_HOST_SERVER_DIR)/node_modules/.package-lock.json
	@mkdir -p "$(FRIENDS_HOST_BUILD)"
	@rm -f "$(FRIENDS_HOST_TEST)"
	clang $(FRIENDS_OBJC_FLAGS) $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_SODIUM_CFLAGS) -I$(FRIENDS_HOST_DIR)/tests \
		$(FRIENDS_HOST_TEST_SRCS) $(FRIENDS_HOST_OBJS) $(FRIENDS_SODIUM_LIB) -framework Foundation -framework Network \
		-o "$(FRIENDS_HOST_TEST)"
	SZFRIENDS_HOST_SERVER_DIR="$(FRIENDS_HOST_SERVER_DIR)" \
		SZFRIENDS_HOST_VECTORS="$(FRIENDS_HOST_SERVER_DIR)/test/vectors/host-list-v1.json" \
		SZFRIENDS_HOST_RESOURCES="$(FRIENDS_HOST_DIR)/resources" "$(FRIENDS_HOST_TEST)"

friends-host-release-check: friends-host-node
	node "$(FRIENDS_HOST_SERVER_DIR)/tools/friends-hostlist.js" release-check \
		--pinned-file "$(FRIENDS_HOST_DIR)/resources/pinned-keys.json" \
		--bootstrap "$(FRIENDS_HOST_DIR)/resources/bootstrap-hosts.json"
