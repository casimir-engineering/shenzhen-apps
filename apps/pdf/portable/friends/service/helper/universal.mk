# The helper for Intel Macs too (ADR 0015 § 2): Shenzhen 3D ships one universal Mac app, so its helper must run on
# both architectures. Included by friends/friends.mk's wildcard, after helper.mk.
#
#   friends-helper-universal   the helper built whole for arm64 and for x86_64, each in its own build tree under
#                              $(BUILD)/friends/universal/<arch> (every object, libsodium and the online stack
#                              included, depends on the architecture), the two executables joined with lipo, and
#                              the bundle made again around the universal executable.
#   friends-universal-check    the x86_64 slice's own suites under Rosetta: libsodium (with deps.mk's x86_64
#                              configuration, AES-256-GCM included), the session area and link signalling, the
#                              vector exporter against every committed vector file, and the online stack's link
#                              test; then both slices of the universal executable are inspected (architectures,
#                              macOS 12 floor, system libraries only). Nothing runs the
#                              helper itself.
#
# The sub-makes get the variables that shape the objects and the signing identity, and SPDF_RELEASE_MODE=0, whose
# release overrides would otherwise force MAC_ARCH back to arm64 (they set the same floor and flags passed here).

FRIENDS_UNIVERSAL_BUILD = $(abspath $(BUILD))/friends/universal
FRIENDS_UNIVERSAL_ARCHS := arm64 x86_64
FRIENDS_UNIVERSAL_EXE = $(FRIENDS_UNIVERSAL_BUILD)/szfriends-helper
FRIENDS_UNIVERSAL_APP = $(FRIENDS_UNIVERSAL_BUILD)/$(FRIENDS_HELPER_APP_NAME).app
friends_universal_slice = $(FRIENDS_UNIVERSAL_BUILD)/$(1)/friends/helper/szfriends-helper
friends_universal_make = $(MAKE) --no-print-directory SPDF_RELEASE_MODE=0 BUILD="$(FRIENDS_UNIVERSAL_BUILD)/$(1)" \
	MAC_ARCH=$(1) "MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET)" "PORTABLE_OPTFLAGS=$(PORTABLE_OPTFLAGS)" \
	"FRIENDS_HELPER_SIGN_IDENTITY=$(FRIENDS_HELPER_SIGN_IDENTITY)" \
	"FRIENDS_HELPER_SHORT_VERSION=$(FRIENDS_HELPER_SHORT_VERSION)" \
	"FRIENDS_HELPER_BUNDLE_VERSION=$(FRIENDS_HELPER_BUNDLE_VERSION)"

.PHONY: friends-helper-universal friends-universal-check
friends-helper-universal:
	$(call friends_universal_make,arm64) friends-helper-bundle
	$(call friends_universal_make,x86_64) "$(call friends_universal_slice,x86_64)"
	lipo -create $(foreach arch,$(FRIENDS_UNIVERSAL_ARCHS),"$(call friends_universal_slice,$(arch))") \
		-output "$(FRIENDS_UNIVERSAL_EXE)"
	lipo "$(FRIENDS_UNIVERSAL_EXE)" -verify_arch $(FRIENDS_UNIVERSAL_ARCHS)
	rm -rf "$(FRIENDS_UNIVERSAL_APP)"
	cp -R "$(FRIENDS_UNIVERSAL_BUILD)/arm64/friends/$(FRIENDS_HELPER_APP_NAME).app" "$(FRIENDS_UNIVERSAL_APP)"
	cp "$(FRIENDS_UNIVERSAL_EXE)" "$(FRIENDS_UNIVERSAL_APP)/Contents/MacOS/$(FRIENDS_HELPER_APP_NAME)"
	@if [ "$(FRIENDS_HELPER_SIGN_IDENTITY)" = "-" ]; then \
		echo 'codesign --force --sign - "$(FRIENDS_UNIVERSAL_APP)"'; codesign --force --sign - "$(FRIENDS_UNIVERSAL_APP)"; \
	else \
		codesign --force --timestamp --options runtime --sign "$(FRIENDS_HELPER_SIGN_IDENTITY)" \
			"$(FRIENDS_UNIVERSAL_APP)"; \
	fi
	@ls -l "$(FRIENDS_UNIVERSAL_EXE)" $(foreach arch,$(FRIENDS_UNIVERSAL_ARCHS),"$(call friends_universal_slice,$(arch))")

# Rosetta reports AVX to x86_64 code only when asked (ROSETTA_ADVERTISE_AVX=1), and libsodium offers AES-256-GCM,
# which seals download links, only where it finds AES-NI, PCLMUL and AVX. Every Intel Mac macOS 12 runs on has all
# three; on Apple silicon the arm64 slice runs, so only these checks need the variable.
friends-universal-check: friends-helper-universal
	ROSETTA_ADVERTISE_AVX=1 $(call friends_universal_make,x86_64) friends-deps-check friends-session-check \
		friends-vectors-check friends-datachannel-check
	@exe="$(FRIENDS_UNIVERSAL_APP)/Contents/MacOS/$(FRIENDS_HELPER_APP_NAME)"; \
	codesign --verify --strict "$(FRIENDS_UNIVERSAL_APP)" || exit 1; \
	archs=$$(lipo -archs "$$exe" | tr ' ' '\n' | LC_ALL=C sort | xargs); \
	test "$$archs" = "$(FRIENDS_UNIVERSAL_ARCHS)" || { echo "architectures: $$archs"; exit 1; }; \
	for arch in $(FRIENDS_UNIVERSAL_ARCHS); do \
		vtool -arch $$arch -show-build "$$exe" | grep -q 'minos 12\.0$$' || { echo "$$arch: not macOS 12"; exit 1; }; \
		extra=$$(otool -arch $$arch -L "$$exe" | sed -n 's/^[[:space:]]*\([^ ]*\) (compatibility.*/\1/p' | \
			grep -v -e '^/usr/lib/' -e '^/System/Library/'); \
		test -z "$$extra" || { echo "$$arch links outside the system: $$extra"; exit 1; }; \
	done; \
	echo "friends-universal-check passed: arm64 and x86_64, macOS 12, system libraries only"
