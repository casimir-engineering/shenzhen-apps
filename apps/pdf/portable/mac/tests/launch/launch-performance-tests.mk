ifndef SPDF_LAUNCH_PERFORMANCE_TESTS_INCLUDED
SPDF_LAUNCH_PERFORMANCE_TESTS_INCLUDED := 1
# Launch performance gate: this tree's app against the previous release's app, as its DMG ships it, both launched
# headlessly (no window on screen, no Dock icon, no activation, state in a scratch directory). See
# mac/tests/launch/run-launch-performance.py for the checks and their margins.
#
# The probe is a library inserted into both apps (DYLD_INSERT_LIBRARIES into an ad hoc signed copy), so the two run
# their own shipped code and are measured by the same probe. LAUNCH_PERF_APP=<ShenzhenPDF.app> measures that app
# instead of building dist/ShenzhenPDF.app: tools/release.sh passes its signed candidate.
LAUNCH_PERF_SRC_DIR ?= mac/tests/launch
LAUNCH_PERF_DYLIB := $(BUILD)/launch-performance/SPDFMacLaunchPerformanceProbe.dylib
LAUNCH_PERF_SRCS := $(addprefix $(LAUNCH_PERF_SRC_DIR)/,SPDFMacLaunchPerformanceProbe.mm SPDFMacLaunchProbeSymbols.mm \
	SPDFMacLaunchPerformanceFixture.mm SPDFMacLaunchSpawnGuard.mm SPDFMacLaunchQuitProbe.mm \
	SPDFMacLaunchProfileSeed.mm SPDFMacLaunchIntegrityProbe.mm)
LAUNCH_PERF_APP ?=
LAUNCH_PERF_TARGET_APP = $(if $(LAUNCH_PERF_APP),$(abspath $(LAUNCH_PERF_APP)),$(abspath $(MAC_APP)))
$(LAUNCH_PERF_DYLIB): $(LAUNCH_PERF_SRCS) $(LAUNCH_PERF_SRC_DIR)/launch-performance-tests.mk
	@mkdir -p "$(@D)"
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -dynamiclib \
		$(LAUNCH_PERF_SRCS) -framework Cocoa -framework QuartzCore -framework CoreGraphics -framework PDFKit -o "$@"
.PHONY: launch-performance-probe mac-launch-performance-gate
launch-performance-probe: $(LAUNCH_PERF_DYLIB)
mac-launch-performance-gate: $(LAUNCH_PERF_DYLIB) $(if $(LAUNCH_PERF_APP),,$(MAC_BIN))
	python3 -I $(LAUNCH_PERF_SRC_DIR)/run-launch-performance.py --app "$(LAUNCH_PERF_TARGET_APP)" \
		--probe "$(abspath $(LAUNCH_PERF_DYLIB))" --work "$(abspath $(BUILD))/launch-performance" \
		--portable "$(CURDIR)"

# Launch and quit on a synthetic 100-tab profile (mac/tests/launch/run-quit-performance.py): budgets for the first
# frame and for the window leaving the screen on quit, and quit-and-relaunch rounds that must lose nothing.
.PHONY: mac-quit-performance-gate mac-quit-integrity-gate
mac-quit-performance-gate mac-quit-integrity-gate: mac-quit-%-gate: $(LAUNCH_PERF_DYLIB) $(if $(LAUNCH_PERF_APP),,$(MAC_BIN))
	python3 -I $(LAUNCH_PERF_SRC_DIR)/run-quit-performance.py $(if $(filter performance,$*),budget,integrity) \
		--app "$(LAUNCH_PERF_TARGET_APP)" --probe "$(abspath $(LAUNCH_PERF_DYLIB))" \
		--work "$(abspath $(BUILD))/quit-performance"

endif
