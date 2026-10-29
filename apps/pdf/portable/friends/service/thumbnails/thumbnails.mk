# Shenzhen Friends file previews (owner: thumbnails): the QOI codec, the PNG writer, QuickLook rendering, and the fuzz
# harness for the decoder and the session frame parser. Included by friends/friends.mk; make runs with cwd portable/.

FRIENDS_THUMBNAILS_DIR := friends/service/thumbnails
FRIENDS_THUMBNAILS_BUILD := $(FRIENDS_BUILD)/thumbnails
# C99 for everything that touches a friend's bytes (a later Linux helper reuses it as is); Objective-C for the rest.
FRIENDS_THUMBNAILS_C_SRCS := $(addprefix $(FRIENDS_THUMBNAILS_DIR)/,szfriends_qoi.c szfriends_image.c)
FRIENDS_THUMBNAILS_M_SRCS := $(addprefix $(FRIENDS_THUMBNAILS_DIR)/,SZFriendsThumbnailCodec.m \
	SZFriendsThumbnailMaker.m)
FRIENDS_THUMBNAILS_HDRS := $(wildcard $(FRIENDS_THUMBNAILS_DIR)/*.h)
FRIENDS_THUMBNAILS_OBJS := \
	$(patsubst $(FRIENDS_THUMBNAILS_DIR)/%.c,$(FRIENDS_THUMBNAILS_BUILD)/%.o,$(FRIENDS_THUMBNAILS_C_SRCS)) \
	$(patsubst $(FRIENDS_THUMBNAILS_DIR)/%.m,$(FRIENDS_THUMBNAILS_BUILD)/%.o,$(FRIENDS_THUMBNAILS_M_SRCS))
# QuickLook draws the sender's preview; CoreGraphics turns its picture into pixels; UniformTypeIdentifiers names the
# type of a snapshot stored without its extension.
FRIENDS_THUMBNAILS_LIBS := -framework QuickLookThumbnailing -framework CoreGraphics -framework UniformTypeIdentifiers

FRIENDS_SERVICE_OBJS += $(FRIENDS_THUMBNAILS_OBJS)
FRIENDS_SERVICE_LIBS += $(FRIENDS_THUMBNAILS_LIBS)
# The store's header for keeping previews belongs to this feature, so it is checked from here.
FRIENDS_PUBLIC_HEADERS += $(FRIENDS_THUMBNAILS_DIR)/SZFriendsThumbnails.h $(FRIENDS_THUMBNAILS_DIR)/szfriends_qoi.h \
	$(FRIENDS_THUMBNAILS_DIR)/szfriends_image.h friends/service/store/SZFriendsTransferThumbnails.h

$(FRIENDS_THUMBNAILS_BUILD)/%.o: $(FRIENDS_THUMBNAILS_DIR)/%.c $(FRIENDS_THUMBNAILS_HDRS) \
		$(FRIENDS_THUMBNAILS_DIR)/thumbnails.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_C_FLAGS) -c "$<" -o "$@"

$(FRIENDS_THUMBNAILS_BUILD)/%.o: $(FRIENDS_THUMBNAILS_DIR)/%.m $(FRIENDS_THUMBNAILS_HDRS) \
		$(FRIENDS_THUMBNAILS_DIR)/thumbnails.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) -c "$<" -o "$@"

# The suite and the corpus replay compile every source again with AddressSanitizer and UndefinedBehaviorSanitizer,
# inside the phony target (make skips a rebuild when source and binary share an mtime second). The frame target needs
# the session codec: its sources are compiled in rather than linked from the session area, with libsodium, which the
# limits file's lane tokens hash with (ADR 0018 § 6).
FRIENDS_THUMBNAILS_SANITIZE := -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer
FRIENDS_THUMBNAILS_TEST := $(FRIENDS_THUMBNAILS_BUILD)/SZFriendsThumbnailTests
FRIENDS_THUMBNAILS_TEST_SRCS = $(sort $(wildcard $(FRIENDS_THUMBNAILS_DIR)/tests/*.m))
FRIENDS_THUMBNAILS_FUZZ_DIR := $(FRIENDS_THUMBNAILS_DIR)/fuzz
FRIENDS_THUMBNAILS_CORPUS := $(FRIENDS_THUMBNAILS_FUZZ_DIR)/corpus
FRIENDS_THUMBNAILS_FRAME_SRCS := $(addprefix friends/service/session/,SZFriendsSessionLimits.m SZFriendsFrameSchema.m \
	SZFriendsFrame.m SZFriendsHandshakePayload.m)
FRIENDS_THUMBNAILS_FUZZ_QOI := $(FRIENDS_THUMBNAILS_BUILD)/szfriends-fuzz-qoi
FRIENDS_THUMBNAILS_FUZZ_FRAME := $(FRIENDS_THUMBNAILS_BUILD)/szfriends-fuzz-frame
FRIENDS_THUMBNAILS_FUZZ_LIBS := -framework Foundation -framework UniformTypeIdentifiers -framework CoreGraphics \
	-framework QuickLookThumbnailing $(FRIENDS_SODIUM_LIB)

# The two fuzz targets, built by $(1) with $(2) as the sanitizer flags and $(3) as the driver (empty for libFuzzer).
# The build directory first: a fuzz run whose FRIENDS_FUZZ_WORK is outside BUILD would otherwise link into nowhere.
define FRIENDS_THUMBNAILS_BUILD_FUZZERS
	@mkdir -p "$(FRIENDS_THUMBNAILS_BUILD)"
	$(1) $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c99 $(FRIENDS_INCLUDES) -g $(2) \
		$(FRIENDS_THUMBNAILS_FUZZ_DIR)/szfriends_fuzz_qoi.c $(FRIENDS_THUMBNAILS_C_SRCS) $(3) \
		-o "$(FRIENDS_THUMBNAILS_FUZZ_QOI)"
	$(1) $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) $(FRIENDS_INCLUDES) $(FRIENDS_SODIUM_CFLAGS) -g $(2) -fobjc-arc \
		$(FRIENDS_THUMBNAILS_FUZZ_DIR)/SZFriendsFuzzFrame.m $(FRIENDS_THUMBNAILS_FRAME_SRCS) \
		$(FRIENDS_THUMBNAILS_M_SRCS) $(FRIENDS_THUMBNAILS_C_SRCS) $(3) $(FRIENDS_THUMBNAILS_FUZZ_LIBS) \
		-o "$(FRIENDS_THUMBNAILS_FUZZ_FRAME)"
endef

FRIENDS_TEST_TARGETS += friends-thumbnails-check
.PHONY: friends-thumbnails-check friends-thumbnails-fuzz friends-thumbnails-fuzz-seeds
friends-thumbnails-check: $(FRIENDS_SODIUM_LIB)
	@mkdir -p "$(FRIENDS_THUMBNAILS_BUILD)"
	@rm -f "$(FRIENDS_THUMBNAILS_TEST)" "$(FRIENDS_THUMBNAILS_FUZZ_QOI)" "$(FRIENDS_THUMBNAILS_FUZZ_FRAME)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_THUMBNAILS_SANITIZE) \
		-I$(FRIENDS_THUMBNAILS_DIR)/tests $(FRIENDS_THUMBNAILS_TEST_SRCS) $(FRIENDS_THUMBNAILS_M_SRCS) \
		$(FRIENDS_THUMBNAILS_C_SRCS) -framework Foundation -framework ImageIO $(FRIENDS_THUMBNAILS_LIBS) \
		-o "$(FRIENDS_THUMBNAILS_TEST)"
	"$(FRIENDS_THUMBNAILS_TEST)"
	@# Every committed corpus input, through both fuzz targets under the sanitizers: a crash a fuzz run once found
	@# stays found.
	$(call FRIENDS_THUMBNAILS_BUILD_FUZZERS,clang,$(FRIENDS_THUMBNAILS_SANITIZE),\
		$(FRIENDS_THUMBNAILS_FUZZ_DIR)/szfriends_fuzz_driver.c)
	"$(FRIENDS_THUMBNAILS_FUZZ_QOI)" "$(FRIENDS_THUMBNAILS_CORPUS)/qoi"
	"$(FRIENDS_THUMBNAILS_FUZZ_FRAME)" "$(FRIENDS_THUMBNAILS_CORPUS)/frame"

# A fuzz run: FRIENDS_FUZZ_SECONDS per target (default 600), with libFuzzer when FRIENDS_FUZZ_CLANG has its runtime
# (Homebrew LLVM does; Apple clang does not), otherwise the mutation driver. New corpus entries and crashing inputs go
# to FRIENDS_FUZZ_WORK, never into the repository; copy a crash into the corpus once it is fixed.
FRIENDS_FUZZ_SECONDS ?= 600
FRIENDS_FUZZ_CLANG ?= /opt/homebrew/opt/llvm/bin/clang
FRIENDS_FUZZ_WORK ?= $(FRIENDS_THUMBNAILS_BUILD)/fuzz-work
FRIENDS_THUMBNAILS_COMMA := ,
friends-thumbnails-fuzz:
	@rm -rf "$(FRIENDS_FUZZ_WORK)"
	@mkdir -p "$(FRIENDS_FUZZ_WORK)/qoi" "$(FRIENDS_FUZZ_WORK)/frame" "$(FRIENDS_FUZZ_WORK)/crashes"
	@if printf 'int LLVMFuzzerTestOneInput(const char *d, unsigned long n) { (void)d; (void)n; return 0; }\n' | \
		"$(FRIENDS_FUZZ_CLANG)" -fsanitize=fuzzer -x c - -o "$(FRIENDS_FUZZ_WORK)/probe" 2>/dev/null; then \
		echo "libFuzzer: $(FRIENDS_FUZZ_CLANG)"; \
		$(MAKE) --no-print-directory friends-thumbnails-fuzz-libfuzzer; \
	else \
		echo "no libFuzzer runtime in $(FRIENDS_FUZZ_CLANG): mutation driver"; \
		$(MAKE) --no-print-directory friends-thumbnails-fuzz-driver; \
	fi

.PHONY: friends-thumbnails-fuzz-libfuzzer friends-thumbnails-fuzz-driver
friends-thumbnails-fuzz-libfuzzer: $(FRIENDS_SODIUM_LIB)
	$(call FRIENDS_THUMBNAILS_BUILD_FUZZERS,"$(FRIENDS_FUZZ_CLANG)" -isysroot "$$(xcrun --show-sdk-path)",\
		-fsanitize=fuzzer$(FRIENDS_THUMBNAILS_COMMA)address$(FRIENDS_THUMBNAILS_COMMA)undefined \
		-fno-sanitize-recover=undefined,)
	"$(FRIENDS_THUMBNAILS_FUZZ_QOI)" -max_total_time=$(FRIENDS_FUZZ_SECONDS) -print_final_stats=1 -max_len=64000 \
		-artifact_prefix="$(FRIENDS_FUZZ_WORK)/crashes/qoi-" \
		"$(FRIENDS_FUZZ_WORK)/qoi" "$(FRIENDS_THUMBNAILS_CORPUS)/qoi"
	"$(FRIENDS_THUMBNAILS_FUZZ_FRAME)" -max_total_time=$(FRIENDS_FUZZ_SECONDS) -print_final_stats=1 -max_len=65519 \
		-artifact_prefix="$(FRIENDS_FUZZ_WORK)/crashes/frame-" "$(FRIENDS_FUZZ_WORK)/frame" \
		"$(FRIENDS_THUMBNAILS_CORPUS)/frame"

friends-thumbnails-fuzz-driver: $(FRIENDS_SODIUM_LIB)
	$(call FRIENDS_THUMBNAILS_BUILD_FUZZERS,clang,$(FRIENDS_THUMBNAILS_SANITIZE),\
		$(FRIENDS_THUMBNAILS_FUZZ_DIR)/szfriends_fuzz_driver.c)
	"$(FRIENDS_THUMBNAILS_FUZZ_QOI)" -seconds $(FRIENDS_FUZZ_SECONDS) -crashes "$(FRIENDS_FUZZ_WORK)/crashes" \
		"$(FRIENDS_THUMBNAILS_CORPUS)/qoi"
	"$(FRIENDS_THUMBNAILS_FUZZ_FRAME)" -seconds $(FRIENDS_FUZZ_SECONDS) -crashes "$(FRIENDS_FUZZ_WORK)/crashes" \
		"$(FRIENDS_THUMBNAILS_CORPUS)/frame"

# Regenerates the seed corpus after a format change (the committed files are this program's output).
FRIENDS_THUMBNAILS_SEEDS := $(FRIENDS_THUMBNAILS_BUILD)/SZFriendsFuzzSeeds
friends-thumbnails-fuzz-seeds: $(FRIENDS_SODIUM_LIB)
	@mkdir -p "$(FRIENDS_THUMBNAILS_BUILD)"
	@rm -f "$(FRIENDS_THUMBNAILS_SEEDS)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) \
		$(FRIENDS_THUMBNAILS_FUZZ_DIR)/SZFriendsFuzzSeeds.m \
		$(FRIENDS_THUMBNAILS_FRAME_SRCS) $(FRIENDS_THUMBNAILS_M_SRCS) $(FRIENDS_THUMBNAILS_C_SRCS) \
		$(FRIENDS_THUMBNAILS_FUZZ_LIBS) -o "$(FRIENDS_THUMBNAILS_SEEDS)"
	"$(FRIENDS_THUMBNAILS_SEEDS)" "$(FRIENDS_THUMBNAILS_CORPUS)/qoi" "$(FRIENDS_THUMBNAILS_CORPUS)/frame"
