# Shenzhen Friends portable core (Rust, portable/friends/core-rs) and the golden vectors that tie it to this helper.
# Included by friends/friends.mk; make runs with cwd portable/. ADR 0015 is the decision.
#
#   friends-vectors-check   Objective-C only: rebuilds the vector exporter from the helper's own sources, exports into
#                           the build tree and fails when friends/fixtures/vectors/ differs. A change to the wire
#                           format, the Noise code, CPace, identity or Friends IDs that forgets the Rust side fails
#                           here, on a Mac without a Rust toolchain.
#   friends-vectors-export  The same export, written over friends/fixtures/vectors/ (then run the Rust suite).
#   friends-core-rs-check   cargo test for the Rust workspace against those same files. Needs cargo; not part of
#                           friends-suite until the release machines carry a pinned Rust toolchain (ADR 0015 § Waves).
#   friends-core-rs-cross-check
#                           cargo check of every crate and test for each platform the core ships on (Windows MSVC
#                           and GNU, Linux, Android's four ABIs, iOS) and of the pure crates for wasm32. rustup's
#                           stable toolchain with those targets added; nothing is linked or run, so the datachannel
#                           stack's C and C++ are not compiled (SZFRIENDS_DATACHANNEL_NO_NATIVE).
#   friends-core-rs-interop-check
#                           a Rust peer against the helper's own session, store and transfer code
#                           (tools/objc-session-peer, linked against the service objects) on loopback: requests, Add by
#                           ID, 200 MiB with resume after a cut and across rekeys, tampering, and one person's two
#                           devices joining, syncing and parting, each side approving (crates/szfriends-interop);
#                           then a whole Rust helper against the whole Objective-C helper meeting on loopback Bonjour
#                           under a test service type: found while visible, asked, accepted, Add by ID, a decline,
#                           messages and a file, a new computer joining the other's profile and syncing with it, each
#                           in both directions (tests/objc_nearby.rs); and the two meeting over a shared test air
#                           first, the network coming up later (tests/objc_routes.rs).
#   friends-core-rs-fuzz    the cargo-fuzz targets for FRIENDS_FUZZ_SECONDS each (fuzz/).
#   friends-core-rs-vm-check
#                           the suites built and run inside the Windows 11 and Ubuntu Parallels VMs
#                           (tools/run-device-tests.sh windows-vm, linux-vm). The VMs must already be running.
#   friends-core-rs-online-check
#                           the Rust core online against the helper's check-in client and online driver through
#                           the local Node host and coturn, direct and relayed, each side offering, and a download
#                           link (crates/szfriends-interop); a Rust helper and the Objective-C helper joining each
#                           other's profile and adding each other by ID through the host alone; then two Rust
#                           helpers' services reaching each other online, direct and relayed
#                           (crates/szfriends-helper/tests/online.rs), and Reset Friends releasing the old ID at the
#                           host, or going ahead without it (tests/online_reset.rs).
#   friends-core-rs-nat-check
#                           the NAT emulator's punching matrix with tools/nat-peer (the Rust core) as the offerer,
#                           then as the answerer, against the helper's own peer.
#   friends-datachannel-rs-check
#                           szfriends-datachannel-sys against the helper: its suite with a Rust peer talking to the
#                           helper's own online transport (tools/objc-dc-peer) over 127.0.0.1. macOS; needs cargo.
#   friends-transfer-bench  on demand, not in any suite: the transfer bench of ADR 0018 (examples/transfer_bench.rs):
#                           Rust and Objective-C peers, each its own process, through a proxy emulating each route's
#                           rate, delay and loss, then a cut and a silence; JSON lines to transfer-bench.jsonl in the
#                           build tree and a table (MB/s, share of the link, CPU s/GB, recovery). BENCH_* narrow it.
#   friends-transfer-interop
#                           on demand, not in any suite: the interop matrix (examples/transfer_interop.rs): peers
#                           built from the release tags (tools/released-peers.sh) against today's, and today's against
#                           each other, on each emulated route, with resume after a cut. INTEROP_* narrow it.

FRIENDS_CORE_RS_DIR := friends/core-rs
# Cargo reads a workspace's .cargo/config.toml only when it runs from inside it; these targets run from portable/, so
# they name it (the static C runtime on Windows, the bundled SQLite's flags).
FRIENDS_CORE_RS_MANIFEST = --manifest-path "$(FRIENDS_CORE_RS_DIR)/Cargo.toml" \
	--config "$(abspath $(FRIENDS_CORE_RS_DIR))/.cargo/config.toml"
FRIENDS_CORE_RS_BUILD := $(FRIENDS_BUILD)/core-rs
FRIENDS_VECTORS_DIR := friends/fixtures/vectors
FRIENDS_VECTORS_TOOL_DIR := $(FRIENDS_CORE_RS_DIR)/tools/objc-vectors
FRIENDS_VECTORS_TOOL := $(FRIENDS_CORE_RS_BUILD)/SZFVectorExport
FRIENDS_VECTORS_OUT := $(FRIENDS_CORE_RS_BUILD)/vectors

# What the exporter calls: the Noise state machine, frame codec and secure channel (session), identity, CPace, join
# tags and Friends IDs (identity), presence tags and the session race (discovery; the racer needs the TXT helpers),
# the Bluetooth presence value, the store with what it links (the mention form, pictures, previews), sync, and the
# fast-transfer area with BLAKE3 (its vectors go to transfer/ beside the others). Production sources, not copies.
FRIENDS_VECTORS_SRCS = $(wildcard $(FRIENDS_VECTORS_TOOL_DIR)/*.m) $(FRIENDS_SESSION_C_SRCS) \
	$(FRIENDS_SESSION_M_SRCS) $(FRIENDS_IDENTITY_SRCS) \
	friends/service/discovery/SZFriendsPresence.m friends/service/discovery/SZFriendsRouteRacer.m \
	friends/service/discovery/SZFriendsNetworkTXT.m friends/service/discovery/SZFriendsBluetoothPresence.m \
	$(FRIENDS_STORE_SRCS) $(FRIENDS_SYNC_SRCS) $(FRIENDS_TRANSFER_SRCS) \
	friends/service/presentation/SZFriendsMentions.m friends/avatars/SZFriendsPicture.m \
	friends/avatars/SZFriendsAnimalSet.m friends/avatars/SZFriendsPictureErrors.m
FRIENDS_VECTORS_STORE_FIXTURE := friends/service/store/tests/fixtures/store-v1.sql

.PHONY: friends-vectors-tool
friends-vectors-tool: $(FRIENDS_SODIUM_LIB) $(FRIENDS_BLAKE3_LIB) $$(FRIENDS_IDENTITY_WORDS_O)
	@mkdir -p "$(FRIENDS_CORE_RS_BUILD)"
	@rm -f "$(FRIENDS_VECTORS_TOOL)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) $(FRIENDS_BLAKE3_CFLAGS) \
		-Wno-missing-prototypes -x objective-c $(filter %.m,$(FRIENDS_VECTORS_SRCS)) -x c $(filter %.c,$(FRIENDS_VECTORS_SRCS)) -x none \
		$(FRIENDS_IDENTITY_WORDS_O) $(FRIENDS_SODIUM_LIB) $(FRIENDS_BLAKE3_LIB) -framework Foundation $(FRIENDS_IDENTITY_LIBS) \
		$(FRIENDS_STORE_LIBS) -o "$(FRIENDS_VECTORS_TOOL)"

FRIENDS_TEST_TARGETS += friends-vectors-check
.PHONY: friends-vectors-check
friends-vectors-check: friends-vectors-tool
	@rm -rf "$(FRIENDS_VECTORS_OUT)"
	@mkdir -p "$(FRIENDS_VECTORS_OUT)"
	"$(FRIENDS_VECTORS_TOOL)" "$(FRIENDS_VECTORS_OUT)" "$(FRIENDS_VECTORS_STORE_FIXTURE)"
	@for file in "$(FRIENDS_VECTORS_OUT)"/*.json; do \
		cmp -s "$$file" "$(FRIENDS_VECTORS_DIR)/$$(basename "$$file")" || { \
			echo "$$(basename "$$file") differs from the helper's behaviour:" \
				"run make friends-vectors-export, then make friends-core-rs-check" >&2; exit 1; }; \
	done
	@# ADR 0018's vectors were written from the record by the Rust core first: the helper must give the same bytes.
	@for file in "$(FRIENDS_VECTORS_DIR)"/transfer/*.json; do \
		cmp -s "$$file" "$(FRIENDS_VECTORS_OUT)/transfer/$$(basename "$$file")" || { \
			echo "transfer/$$(basename "$$file"): the helper does not give these bytes (ADR 0018)" >&2; exit 1; }; \
	done
	@# A committed objc-*.json the exporter no longer writes would keep feeding the Rust suites stale vectors.
	@for file in "$(FRIENDS_VECTORS_DIR)"/objc-*.json; do \
		[ -f "$(FRIENDS_VECTORS_OUT)/$$(basename "$$file")" ] || { \
			echo "$$(basename "$$file") is committed but no longer exported: delete it" >&2; exit 1; }; \
	done
	@echo "friends-vectors-check passed"

.PHONY: friends-vectors-export
friends-vectors-export: friends-vectors-tool
	@mkdir -p "$(FRIENDS_VECTORS_DIR)"
	"$(FRIENDS_VECTORS_TOOL)" "$(FRIENDS_VECTORS_DIR)" "$(FRIENDS_VECTORS_STORE_FIXTURE)"

.PHONY: friends-core-rs-check
friends-core-rs-check:
	CARGO_TARGET_DIR="$(abspath $(FRIENDS_CORE_RS_BUILD))/target" \
		cargo test $(FRIENDS_CORE_RS_MANIFEST) --workspace --locked

# Every target a Shenzhen 3D build ships the core on, plus the GNU Windows ABI so a MinGW host stays possible.
FRIENDS_CORE_RS_TARGETS := x86_64-pc-windows-msvc aarch64-pc-windows-msvc x86_64-pc-windows-gnu \
	x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu \
	aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android \
	aarch64-apple-ios aarch64-apple-ios-sim
# The crates a later browser client could reuse (ADR 0015 § Web). Crypto and identity need a random source and a
# key store a browser does not give them without that client's own decision.
FRIENDS_CORE_RS_WASM_CRATES := -p szfriends-wire -p szfriends-contract

# The store bundles SQLite's C everywhere but on Apple systems (ADR 0015 § 7), so checking a target compiles C for it:
# the NDK's clang for Android (the newest NDK under the SDK, or FRIENDS_ANDROID_NDK), `zig cc` for Linux
# (tools/zig-cc.sh), MinGW for Windows GNU. No MSVC headers exist on a Mac, so the MSVC targets check against a linked
# SQLite instead (LIBSQLITE3_SYS_USE_PKG_CONFIG) and BLAKE3 without its C and assembly (szfriends-core's blake3-pure):
# the Rust is checked the same, and the C of both is built for MSVC in the Windows VM (friends-core-rs-vm-check).
FRIENDS_ANDROID_NDK ?= $(lastword $(sort $(wildcard $(HOME)/Library/Android/sdk/ndk/*)))
FRIENDS_ANDROID_NDK_BIN = $(FRIENDS_ANDROID_NDK)/toolchains/llvm/prebuilt/darwin-x86_64/bin

.PHONY: friends-core-rs-cross-check
friends-core-rs-cross-check:
	@toolchain=$$(rustup run stable rustc --print sysroot) && \
	export RUSTC="$$toolchain/bin/rustc" CARGO_TARGET_DIR="$(abspath $(FRIENDS_CORE_RS_BUILD))/cross-target" && \
	for target in $(FRIENDS_CORE_RS_TARGETS); do \
		triple=$$(echo "$$target" | tr '-' '_'); features=; \
		case "$$target" in \
		*-windows-msvc) set -- LIBSQLITE3_SYS_USE_PKG_CONFIG=1; features="--features szfriends-core/blake3-pure" ;; \
		*-unknown-linux-gnu) set -- "CC_$$triple=$(abspath $(FRIENDS_CORE_RS_DIR))/tools/zig-cc.sh" \
			"AR_$$triple=zig ar" "SZFRIENDS_ZIG_TARGET=$${target%%-unknown-linux-gnu}-linux-gnu" ;; \
		*-android*) clang=$$(echo "$$target" | sed 's/^armv7-/armv7a-/'); \
			set -- "CC_$$triple=$(FRIENDS_ANDROID_NDK_BIN)/$${clang}24-clang" \
			"AR_$$triple=$(FRIENDS_ANDROID_NDK_BIN)/llvm-ar" ;; \
		*) set -- ;; \
		esac; \
		echo "cargo check --target $$target"; \
		env SZFRIENDS_DATACHANNEL_NO_NATIVE=1 "$$@" "$$toolchain/bin/cargo" check \
			$(FRIENDS_CORE_RS_MANIFEST) --workspace --all-targets --locked $$features \
			--target "$$target" --quiet || exit 1; \
	done && \
	echo "cargo check --target wasm32-unknown-unknown" && \
	"$$toolchain/bin/cargo" check $(FRIENDS_CORE_RS_MANIFEST) $(FRIENDS_CORE_RS_WASM_CRATES) \
		--locked --target wasm32-unknown-unknown --quiet

.PHONY: friends-core-rs-vm-check
friends-core-rs-vm-check:
	"$(FRIENDS_CORE_RS_DIR)/tools/run-device-tests.sh" windows-vm
	"$(FRIENDS_CORE_RS_DIR)/tools/run-device-tests.sh" linux-vm

# cargo-fuzz targets (fuzz/): every decoder a peer or a client feeds, and a responder channel fed a stranger's bytes.
# FRIENDS_FUZZ_SECONDS per target (default 600), libFuzzer's own engine without a sanitizer (the crates are safe Rust;
# panics, failed invariants and overflow checks are the findings), seeded with the helper's frame corpus. New corpus
# entries and any crash land in the build tree, never in the source tree. rustup's stable toolchain and cargo-fuzz.
FRIENDS_FUZZ_SECONDS ?= 600
FRIENDS_CORE_RS_FUZZ_TARGETS := frame handshake_payload stream channel_responder chunk_flow json_lines device_chain \
	join_message sync_message block_flow
FRIENDS_CORE_RS_FUZZ_SEEDS := friends/service/thumbnails/fuzz/corpus/frame

.PHONY: friends-core-rs-fuzz
friends-core-rs-fuzz:
	@out="$(abspath $(FRIENDS_CORE_RS_BUILD))/fuzz" && mkdir -p "$$out" && \
	for target in $(FRIENDS_CORE_RS_FUZZ_TARGETS); do \
		mkdir -p "$$out/corpus/$$target" "$$out/artifacts/$$target" && \
		echo "cargo fuzz run $$target for $(FRIENDS_FUZZ_SECONDS) s" && \
		(cd "$(FRIENDS_CORE_RS_DIR)" && CARGO_TARGET_DIR="$$out/target" rustup run stable cargo fuzz run -s none \
			"$$target" "$$out/corpus/$$target" "$(abspath $(FRIENDS_CORE_RS_FUZZ_SEEDS))" -- \
			-max_total_time=$(FRIENDS_FUZZ_SECONDS) -artifact_prefix="$$out/artifacts/$$target/" \
			-print_final_stats=1) || exit 1; \
	done; echo "friends-core-rs-fuzz passed"

# The Objective-C interop peer: the helper's service objects with tools/objc-session-peer as main, linked as the
# two-helper harness links its runner (tests/e2e/e2e.mk), then the interop suite with it as the other side. Release
# builds of the Rust peer, so 200 MiB moves at the speed the two codecs allow. Loopback only; temporary homes.
FRIENDS_SESSION_PEER_DIR := $(FRIENDS_CORE_RS_DIR)/tools/objc-session-peer
FRIENDS_SESSION_PEER := $(FRIENDS_CORE_RS_BUILD)/SZFSessionPeer

.PHONY: friends-session-peer
friends-session-peer: $$(FRIENDS_SERVICE_OBJS) $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ) $$(FRIENDS_CLIENT_OBJS)
	@mkdir -p "$(FRIENDS_CORE_RS_BUILD)"
	@rm -f "$(FRIENDS_SESSION_PEER)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) $(FRIENDS_SODIUM_CFLAGS) -Wno-missing-prototypes \
		$(wildcard $(FRIENDS_SESSION_PEER_DIR)/*.m) $(FRIENDS_SERVICE_OBJS) $(FRIENDS_CLIENT_OBJS) \
		$(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) -framework Foundation -Wl,-dead_strip \
		-o "$(FRIENDS_SESSION_PEER)"

.PHONY: friends-core-rs-interop-check
friends-core-rs-interop-check: friends-session-peer $$(FRIENDS_HELPER_EXE)
	SZFRIENDS_OBJC_PEER="$(abspath $(FRIENDS_SESSION_PEER))" \
		CARGO_TARGET_DIR="$(abspath $(FRIENDS_CORE_RS_BUILD))/target" \
		cargo test $(FRIENDS_CORE_RS_MANIFEST) --locked --release -p szfriends-interop \
		--test objc_interop -- --test-threads=1 --nocapture
	SZFRIENDS_OBJC_HELPER="$(abspath $(FRIENDS_HELPER_EXE))" \
		CARGO_TARGET_DIR="$(abspath $(FRIENDS_CORE_RS_BUILD))/target" \
		cargo test $(FRIENDS_CORE_RS_MANIFEST) --locked --release -p szfriends-interop \
		--test objc_nearby -- --test-threads=1 --nocapture
	SZFRIENDS_OBJC_HELPER="$(abspath $(FRIENDS_HELPER_EXE))" \
		CARGO_TARGET_DIR="$(abspath $(FRIENDS_CORE_RS_BUILD))/target" \
		cargo test $(FRIENDS_CORE_RS_MANIFEST) --locked --release -p szfriends-interop \
		--test objc_again --test objc_dir_bridge --test objc_routes -- --test-threads=1 --nocapture

# Online between the Rust core and the helper's own check-in client and online driver (the session peer above in
# its online mode), through the local Node host (server/friends, its node_modules installed) and a coturn built from
# pinned source at the host's 5 Mbit/s cap (FRIENDS_TEST_COTURN): direct and relayed, each side offering, a message
# and a file in ADR 0001 sessions over the data channels; then two Rust cores the same way, and a download link from
# the Rust core through the link page's own script; a Rust helper and the Objective-C helper with nothing nearby,
# each joining the other's profile through the host and syncing online, and each adding the other by ID through it;
# links and Add by ID between a Rust helper and the Objective-C helper (the links e2e helper, loopback allowed); then
# two Rust helpers' services, friends with no other route, reaching each other the same way, and the same two meeting
# nearby too, where the better route in the owner's order takes over and a worse one never does, and one person's
# computers joined through the host alone, whose sync moves off the relay once a direct connection works. Loopback
# only; temporary homes.
.PHONY: friends-core-rs-online-check
friends-core-rs-online-check: friends-session-peer friends-links-e2e-helper $$(FRIENDS_HELPER_EXE)
	SZFRIENDS_OBJC_PEER="$(abspath $(FRIENDS_SESSION_PEER))" SZFRIENDS_OBJC_HELPER="$(abspath $(FRIENDS_HELPER_EXE))" \
		SZFRIENDS_HOST_SERVER_DIR="$(abspath $(FRIENDS_HOST_SERVER_DIR))" FRIENDS_TEST_COTURN="$(FRIENDS_TEST_COTURN)" \
		CARGO_TARGET_DIR="$(abspath $(FRIENDS_CORE_RS_BUILD))/target" \
		cargo test $(FRIENDS_CORE_RS_MANIFEST) --locked --release -p szfriends-interop \
		--test online_interop -- --test-threads=1 --nocapture
	SZFRIENDS_OBJC_LINKS_HELPER="$(abspath $(FRIENDS_LINKS_E2E_HELPER))" \
		SZFRIENDS_HOST_SERVER_DIR="$(abspath $(FRIENDS_HOST_SERVER_DIR))" \
		CARGO_TARGET_DIR="$(abspath $(FRIENDS_CORE_RS_BUILD))/target" \
		cargo test $(FRIENDS_CORE_RS_MANIFEST) --locked --release -p szfriends-interop \
		--test objc_links -- --test-threads=1 --nocapture
	SZFRIENDS_OBJC_PEER="$(abspath $(FRIENDS_SESSION_PEER))" \
		SZFRIENDS_HOST_SERVER_DIR="$(abspath $(FRIENDS_HOST_SERVER_DIR))" FRIENDS_TEST_COTURN="$(FRIENDS_TEST_COTURN)" \
		CARGO_TARGET_DIR="$(abspath $(FRIENDS_CORE_RS_BUILD))/target" \
		cargo test $(FRIENDS_CORE_RS_MANIFEST) --locked --release -p szfriends-helper \
		--test online --test online_reset --test route_order --test profile_routes -- --nocapture

# The NAT emulator's punching matrix (tests/nat-emulator) with the Rust core on one side of every pair: once as the
# offerer, once as the answerer, against the helper's own peer, each through every pair of NAT types and checked
# against what that pair must show. tools/nat-peer is the Rust host; the matrix inserts the emulator's shim into it.
# Needs Node.js 22.16 or later; FRIENDS_TEST_COTURN lets the symmetric pairs show the relay. The matrices go to the
# build tree.
FRIENDS_NAT_RUST_PEER = $(abspath $(FRIENDS_CORE_RS_BUILD))/target/release/szfnat-rust-peer

.PHONY: friends-core-rs-nat-check
friends-core-rs-nat-check: friends-nat-emulator-build
	CARGO_TARGET_DIR="$(abspath $(FRIENDS_CORE_RS_BUILD))/target" \
		cargo build $(FRIENDS_CORE_RS_MANIFEST) --locked --release -p szfriends-nat-peer
	SZFNAT_OFFERER_PEER="$(FRIENDS_NAT_RUST_PEER)" "$(FRIENDS_NATEMU_BUILD)/SZFNATMatrix" \
		"$(FRIENDS_NATEMU_BUILD)/szfnat-peer" "$(CURDIR)/$(FRIENDS_HOST_SERVER_DIR)" \
		"$(CURDIR)/$(FRIENDS_NATEMU_DIR)/stun-host.mjs" "$(FRIENDS_CORE_RS_BUILD)/punching-matrix-rust-offerer.md"
	SZFNAT_ANSWERER_PEER="$(FRIENDS_NAT_RUST_PEER)" "$(FRIENDS_NATEMU_BUILD)/SZFNATMatrix" \
		"$(FRIENDS_NATEMU_BUILD)/szfnat-peer" "$(CURDIR)/$(FRIENDS_HOST_SERVER_DIR)" \
		"$(CURDIR)/$(FRIENDS_NATEMU_DIR)/stun-host.mjs" "$(FRIENDS_CORE_RS_BUILD)/punching-matrix-rust-answerer.md"

# The helper's transport sources and the stack's archives, built for this Mac, answering the Rust peer of
# crates/szfriends-datachannel-sys/tests/objc_interop.rs. That test skips, and says so, without SZFRIENDS_DC_OBJC_PEER.
FRIENDS_DC_PEER := $(FRIENDS_CORE_RS_BUILD)/SZFDataChannelPeer
FRIENDS_DC_PEER_SRC := $(FRIENDS_CORE_RS_DIR)/tools/objc-dc-peer/SZFDataChannelPeer.m

.PHONY: friends-datachannel-rs-check
friends-datachannel-rs-check: $$(FRIENDS_DATACHANNEL_LIBS)
	@mkdir -p "$(FRIENDS_CORE_RS_BUILD)"
	@rm -f "$(FRIENDS_DC_PEER)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_ONLINE_CFLAGS) "$(FRIENDS_DC_PEER_SRC)" \
		$(FRIENDS_ONLINE_TRANSPORT_SRCS) $(FRIENDS_ONLINE_LINK) -framework Foundation -o "$(FRIENDS_DC_PEER)"
	CARGO_TARGET_DIR="$(abspath $(FRIENDS_CORE_RS_BUILD))/target" \
		SZFRIENDS_DC_OBJC_PEER="$(abspath $(FRIENDS_DC_PEER))" \
		cargo test $(FRIENDS_CORE_RS_MANIFEST) -p szfriends-datachannel-sys --locked

# The transfer bench and the interop matrix (ADR 0018 § Verification, WP5). Release builds, as the helpers ship; on
# demand only. Loopback; temporary homes; the released peers' worktrees and builds stay under the build tree.
FRIENDS_TRANSFER_EXAMPLES = $(abspath $(FRIENDS_CORE_RS_BUILD))/target/release/examples

.PHONY: friends-transfer-examples
friends-transfer-examples:
	CARGO_TARGET_DIR="$(abspath $(FRIENDS_CORE_RS_BUILD))/target" cargo build $(FRIENDS_CORE_RS_MANIFEST) --locked \
		--release -p szfriends-interop --example session_peer --example transfer_bench --example transfer_interop

.PHONY: friends-transfer-bench
friends-transfer-bench: friends-session-peer friends-transfer-examples
	SZFRIENDS_OBJC_PEER="$(abspath $(FRIENDS_SESSION_PEER))" \
		BENCH_OUT="$${BENCH_OUT:-$(abspath $(FRIENDS_CORE_RS_BUILD))/transfer-bench.jsonl}" \
		"$(FRIENDS_TRANSFER_EXAMPLES)/transfer_bench"

.PHONY: friends-transfer-interop
friends-transfer-interop: friends-session-peer friends-transfer-examples
	eval "$$($(FRIENDS_CORE_RS_DIR)/tools/released-peers.sh "$(FRIENDS_CORE_RS_BUILD)/released")" && \
		SZFRIENDS_OBJC_PEER="$(abspath $(FRIENDS_SESSION_PEER))" \
		INTEROP_OUT="$${INTEROP_OUT:-$(abspath $(FRIENDS_CORE_RS_BUILD))/transfer-interop.jsonl}" \
		"$(FRIENDS_TRANSFER_EXAMPLES)/transfer_interop"
