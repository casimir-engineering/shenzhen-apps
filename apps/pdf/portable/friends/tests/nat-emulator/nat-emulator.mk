# Shenzhen Friends NAT emulator (owner: nat-emulator area): friends-nat-emulator-check. Lead decision 12 (hole punching
# like Keet's): a userspace NAT per simulated host on loopback (szfnat.h), its own tests (szfnat_tests.c), and the real
# online driver through every pair of NAT types (SZFNATMatrix.h), which writes the punching matrix. friends/friends.mk
# picks this file up through its friends/*/*/*.mk wildcard; make runs with cwd portable/.
#
# The matrix needs Node.js 22.16 or later on PATH (the host service's own STUN responder answers on the public side)
# and fails without it. A coturn built from pinned source, named by FRIENDS_TEST_COTURN (server/friends/README.md
# § Testing), lets the symmetric pairs show the relay carrying them; without it they show that the driver asked for it.
# FRIENDS_NAT_MATRIX_DOC=1 also writes the matrix to friends/docs/punching-matrix.md; every run writes it to the build.

FRIENDS_NATEMU_DIR := friends/tests/nat-emulator
FRIENDS_NATEMU_BUILD = $(FRIENDS_BUILD)/nat-emulator
FRIENDS_NATEMU_SANITIZE := -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer
FRIENDS_NATEMU_C_SRCS := $(FRIENDS_NATEMU_DIR)/szfnat.c $(FRIENDS_NATEMU_DIR)/szfnat_tcp.c
FRIENDS_NATEMU_DOC = $(if $(filter 1,$(FRIENDS_NAT_MATRIX_DOC)),"$(CURDIR)/friends/docs/punching-matrix.md")

ifeq ($(UNAME_S),Darwin)
FRIENDS_TEST_TARGETS += friends-nat-emulator-check
endif
.PHONY: friends-nat-emulator-build friends-nat-emulator-check
# Every binary is compiled inside the recipe after an rm, so a stale one never passes. The peer links every service
# object (the driver with its transport, order and NAT techniques) and the shim, which sits beside it
# (@executable_path), so it starts behind its NAT whenever SZFNAT_INSIDE_PORT is set.
friends-nat-emulator-build: $$(FRIENDS_SERVICE_OBJS) $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ)
	@mkdir -p "$(FRIENDS_NATEMU_BUILD)"
	@cd "$(FRIENDS_NATEMU_BUILD)" && rm -f libszfnat_shim.dylib szfnat_tests szfnat-peer SZFNATMatrix
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_C_FLAGS) -dynamiclib \
		-install_name @executable_path/libszfnat_shim.dylib $(FRIENDS_NATEMU_DIR)/szfnat_shim.c \
		-o "$(FRIENDS_NATEMU_BUILD)/libszfnat_shim.dylib"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_C_FLAGS) $(FRIENDS_NATEMU_SANITIZE) $(FRIENDS_NATEMU_C_SRCS) \
		$(FRIENDS_NATEMU_DIR)/szfnat_tests.c -L"$(FRIENDS_NATEMU_BUILD)" -lszfnat_shim \
		-o "$(FRIENDS_NATEMU_BUILD)/szfnat_tests"
	"$(FRIENDS_NATEMU_BUILD)/szfnat_tests"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) $(FRIENDS_NATEMU_DIR)/SZFNATPeer.m \
		$(FRIENDS_SERVICE_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		-L"$(FRIENDS_NATEMU_BUILD)" -lszfnat_shim -framework Foundation -framework Security \
		-framework LocalAuthentication -framework IOKit -Wl,-dead_strip -o "$(FRIENDS_NATEMU_BUILD)/szfnat-peer"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_C_FLAGS) -c $(FRIENDS_NATEMU_DIR)/szfnat.c \
		-o "$(FRIENDS_NATEMU_BUILD)/szfnat.o"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_C_FLAGS) -c $(FRIENDS_NATEMU_DIR)/szfnat_tcp.c \
		-o "$(FRIENDS_NATEMU_BUILD)/szfnat_tcp.o"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_NATEMU_DIR)/SZFNATMatrix.m \
		$(FRIENDS_NATEMU_DIR)/SZFNATWorld.m "$(FRIENDS_NATEMU_BUILD)/szfnat.o" "$(FRIENDS_NATEMU_BUILD)/szfnat_tcp.o" \
		-framework Foundation -o "$(FRIENDS_NATEMU_BUILD)/SZFNATMatrix"

friends-nat-emulator-check: friends-nat-emulator-build
	"$(FRIENDS_NATEMU_BUILD)/SZFNATMatrix" "$(FRIENDS_NATEMU_BUILD)/szfnat-peer" "$(CURDIR)/$(FRIENDS_HOST_SERVER_DIR)" \
		"$(CURDIR)/$(FRIENDS_NATEMU_DIR)/stun-host.mjs" "$(FRIENDS_NATEMU_BUILD)/punching-matrix.md" \
		$(FRIENDS_NATEMU_DOC)
