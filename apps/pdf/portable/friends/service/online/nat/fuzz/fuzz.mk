# Fuzz targets of the NAT techniques (ADR 0011 § Verification), included by ../nat.mk. Everything they parse arrives
# before anyone is authenticated, from the LAN or the Internet:
#   stun       our STUN codec (classifier, prober, STUN over TCP)
#   pcp        our PCP and NAT-PMP answer parsers
#   candidate  candidate lines and numeric addresses from the peer's signalling
#   ssdp       miniupnpc's M-SEARCH answer parsing          (any device on the LAN)
#   desc       miniupnpc's device description XML and URLs  (the IGD's HTTP server)
#   soap       miniupnpc's SOAP answers and port listings   (the IGD's HTTP server)
#   http       miniupnpc's HTTP reading, chunked coding included
#
# friends-nat-check replays the whole corpus (fuzz/corpus/<target>/) through every target under ASan and UBSan with
# the thumbnails area's mutation driver (no new inputs, Apple clang). friends-nat-fuzz runs each target for
# FRIENDS_NAT_FUZZ_SECONDS (default 600), with libFuzzer when FRIENDS_NAT_FUZZ_CLANG has its runtime (Homebrew LLVM
# does), otherwise the mutation driver; run it with -j to fuzz the targets side by side. New inputs go to
# FRIENDS_NAT_FUZZ_WORK, and libFuzzer then merges the ones that add coverage into fuzz/corpus/ (kept in the
# repository). libFuzzer runs in fork mode and keeps going past a crash, so a known upstream bug
# (fuzz/findings/README.md) does not cut a run short; crashes go to FRIENDS_NAT_FUZZ_WORK/crashes and fail the target
# at the end. A crash's input is copied into the corpus once it is fixed.

FRIENDS_NAT_FUZZ_DIR := $(FRIENDS_NAT_DIR)/fuzz
FRIENDS_NAT_CORPUS := $(FRIENDS_NAT_FUZZ_DIR)/corpus
FRIENDS_NAT_FUZZ_BUILD := $(FRIENDS_NAT_BUILD)/fuzz
FRIENDS_NAT_FUZZ_TARGETS := stun pcp candidate ssdp desc soap http
FRIENDS_NAT_FUZZ_DRIVER := friends/service/thumbnails/fuzz/szfriends_fuzz_driver.c
FRIENDS_NAT_FUZZ_SECONDS ?= 600
FRIENDS_NAT_FUZZ_CLANG ?= /opt/homebrew/opt/llvm/bin/clang
FRIENDS_NAT_FUZZ_WORK ?= $(FRIENDS_NAT_FUZZ_BUILD)/work

FRIENDS_NAT_FUZZ_SRCS_stun := $(FRIENDS_NAT_FUZZ_DIR)/SZFriendsNATFuzzStun.m $(FRIENDS_NAT_DIR)/SZFriendsNATStun.m
FRIENDS_NAT_FUZZ_SRCS_pcp := $(FRIENDS_NAT_FUZZ_DIR)/SZFriendsNATFuzzPCP.m $(FRIENDS_NAT_DIR)/SZFriendsNATPCP.m
FRIENDS_NAT_FUZZ_SRCS_candidate := $(FRIENDS_NAT_FUZZ_DIR)/SZFriendsNATFuzzCandidate.m \
	$(FRIENDS_NAT_DIR)/SZFriendsNATPrediction.m $(FRIENDS_NAT_DIR)/SZFriendsNATEndpoint.m
# minissdpc.c is included by its target (its parser is static), so its object stays out.
FRIENDS_NAT_FUZZ_SRCS_ssdp := $(FRIENDS_NAT_FUZZ_DIR)/szfriends_fuzz_upnp_ssdp.c \
	$(filter-out %/minissdpc.c,$(FRIENDS_UPNP_SRCS))
FRIENDS_NAT_FUZZ_SRCS_desc := $(FRIENDS_NAT_FUZZ_DIR)/szfriends_fuzz_upnp_desc.c $(FRIENDS_UPNP_SRCS)
FRIENDS_NAT_FUZZ_SRCS_soap := $(FRIENDS_NAT_FUZZ_DIR)/szfriends_fuzz_upnp_soap.c $(FRIENDS_UPNP_SRCS)
FRIENDS_NAT_FUZZ_SRCS_http := $(FRIENDS_NAT_FUZZ_DIR)/szfriends_fuzz_upnp_http.c $(FRIENDS_UPNP_SRCS)
# Longest input per target: one SSDP datagram as miniupnpc reads it; 64 KiB for everything else.
FRIENDS_NAT_FUZZ_MAX_ssdp := 1536
FRIENDS_NAT_FUZZ_MAX_DEFAULT := 65536

# Upstream code is compiled as it is, so its warnings are not ours to fix here (-w); ARC applies to the .m targets.
FRIENDS_NAT_FUZZ_FLAGS = $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -g -w -fobjc-arc $(FRIENDS_INCLUDES) \
	$(FRIENDS_UPNP_CONFIG) $(FRIENDS_NAT_CFLAGS) -I$(FRIENDS_UPNP_GENERATED)
# The replay builds and the libFuzzer builds have different names, so a suite run during a fuzz run cannot replace
# the binary a fuzz run is about to merge with.
friends_nat_fuzz_binary = $(FRIENDS_NAT_FUZZ_BUILD)/szfriends-nat-fuzz-$(1)
friends_nat_libfuzzer_binary = $(FRIENDS_NAT_FUZZ_BUILD)/szfriends-nat-libfuzzer-$(1)
friends_nat_comma := ,

# $(1) compiler, $(2) sanitizer flags, $(3) the driver (empty for libFuzzer), $(4) target, $(5) output.
friends_nat_fuzz_build = $(1) $(FRIENDS_NAT_FUZZ_FLAGS) $(2) $(FRIENDS_NAT_FUZZ_SRCS_$(4)) $(3) -framework Foundation \
	-o "$(5)"

# One shell line: build each target with the driver, then replay its corpus; the first failure stops it.
FRIENDS_NAT_FUZZ_REPLAY = mkdir -p "$(FRIENDS_NAT_FUZZ_BUILD)" && \
	$(foreach t,$(FRIENDS_NAT_FUZZ_TARGETS),$(call friends_nat_fuzz_build,clang,$(FRIENDS_NAT_SANITIZE),\
	$(FRIENDS_NAT_FUZZ_DRIVER),$(t),$(call friends_nat_fuzz_binary,$(t))) && \
	"$(call friends_nat_fuzz_binary,$(t))" "$(FRIENDS_NAT_CORPUS)/$(t)" &&) true

FRIENDS_NAT_FUZZ_RUNS := $(addprefix friends-nat-fuzz-,$(FRIENDS_NAT_FUZZ_TARGETS))
.PHONY: friends-nat-fuzz $(FRIENDS_NAT_FUZZ_RUNS)
friends-nat-fuzz: $(FRIENDS_NAT_FUZZ_RUNS)

$(FRIENDS_NAT_FUZZ_RUNS): friends-nat-fuzz-%: $(FRIENDS_UPNP_STRINGS)
	@mkdir -p "$(FRIENDS_NAT_FUZZ_BUILD)" "$(FRIENDS_NAT_FUZZ_WORK)/$*" "$(FRIENDS_NAT_FUZZ_WORK)/crashes"
	@if printf 'int LLVMFuzzerTestOneInput(const char *d, unsigned long n) { (void)d; (void)n; return 0; }\n' | \
		"$(FRIENDS_NAT_FUZZ_CLANG)" -fsanitize=fuzzer -x c - -o "$(FRIENDS_NAT_FUZZ_WORK)/probe-$*" 2>/dev/null; then \
		echo "libFuzzer ($(FRIENDS_NAT_FUZZ_CLANG)): $*"; \
		$(call friends_nat_fuzz_build,"$(FRIENDS_NAT_FUZZ_CLANG)" -isysroot "$$(xcrun --show-sdk-path)",\
			-fsanitize=fuzzer$(friends_nat_comma)address$(friends_nat_comma)undefined \
			-fno-sanitize-recover=undefined,,$*,$(call friends_nat_libfuzzer_binary,$*)) && \
		"$(call friends_nat_libfuzzer_binary,$*)" -fork=1 -ignore_crashes=1 -ignore_ooms=1 -ignore_timeouts=1 \
			-max_total_time=$(FRIENDS_NAT_FUZZ_SECONDS) -print_final_stats=1 \
			-max_len=$(or $(FRIENDS_NAT_FUZZ_MAX_$*),$(FRIENDS_NAT_FUZZ_MAX_DEFAULT)) -rss_limit_mb=2048 \
			-artifact_prefix="$(FRIENDS_NAT_FUZZ_WORK)/crashes/$*-" "$(FRIENDS_NAT_FUZZ_WORK)/$*" \
			"$(FRIENDS_NAT_CORPUS)/$*" ; \
		"$(call friends_nat_libfuzzer_binary,$*)" -merge=1 -rss_limit_mb=2048 "$(FRIENDS_NAT_CORPUS)/$*" \
			"$(FRIENDS_NAT_FUZZ_WORK)/$*" && \
		if ls "$(FRIENDS_NAT_FUZZ_WORK)/crashes/$*-"* >/dev/null 2>&1; then \
			echo "$*: crashes in $(FRIENDS_NAT_FUZZ_WORK)/crashes (fuzz/findings/README.md lists the known ones)" >&2; \
			exit 1; \
		fi; \
	else \
		echo "no libFuzzer runtime in $(FRIENDS_NAT_FUZZ_CLANG): mutation driver for $*"; \
		$(call friends_nat_fuzz_build,clang,$(FRIENDS_NAT_SANITIZE),$(FRIENDS_NAT_FUZZ_DRIVER),$*,\
			$(call friends_nat_fuzz_binary,$*)) && \
		"$(call friends_nat_fuzz_binary,$*)" -seconds $(FRIENDS_NAT_FUZZ_SECONDS) \
			-crashes "$(FRIENDS_NAT_FUZZ_WORK)/crashes" "$(FRIENDS_NAT_CORPUS)/$*"; \
	fi
