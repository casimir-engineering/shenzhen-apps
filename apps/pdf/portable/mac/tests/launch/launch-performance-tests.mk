ifndef SPDF_LAUNCH_PERFORMANCE_TESTS_INCLUDED
SPDF_LAUNCH_PERFORMANCE_TESTS_INCLUDED := 1
# Launch performance gate: the real reader launched headlessly (no window on screen, no Dock icon, no activation,
# state in a scratch directory) against the previous release tag built from source in the same run. See
# mac/tests/launch/run-launch-performance.py for the checks and their margins.
#
# The probe also builds inside an older tree (a release tag) with
#   make -f Makefile -f <this file> launch-performance-probe LAUNCH_PERF_SRC_DIR=<this directory>
# which is how the gate builds the release it compares against.
include mac/tests/workspace-probe.mk
LAUNCH_PERF_SRC_DIR ?= mac/tests/launch
LAUNCH_PERF_PROBE := $(BUILD)/SPDFMacLaunchPerformanceProbe
LAUNCH_PERF_OBJS := $(BUILD)/launch-performance/probe.o $(BUILD)/launch-performance/fixture.o \
	$(BUILD)/launch-performance/spawn-guard.o
LAUNCH_PERF_BASE_OBJS = $(filter-out \
	$(BUILD)/workspace-probe/mac/tests/SPDFMacWorkspaceProbe.o,$(MAC_WORKSPACE_PROBE_OBJS))
$(BUILD)/launch-performance/probe.o: $(LAUNCH_PERF_SRC_DIR)/SPDFMacLaunchPerformanceProbe.mm
	@mkdir -p "$(@D)"
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -c "$<" -o "$@"
$(BUILD)/launch-performance/fixture.o: $(LAUNCH_PERF_SRC_DIR)/SPDFMacLaunchPerformanceFixture.mm
	@mkdir -p "$(@D)"
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -c "$<" -o "$@"
$(BUILD)/launch-performance/spawn-guard.o: $(LAUNCH_PERF_SRC_DIR)/SPDFMacLaunchSpawnGuard.mm
	@mkdir -p "$(@D)"
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -c "$<" -o "$@"
# Linked like the reader (-dead_strip) but with its symbols kept, so the probe's main-thread samples have names.
$(LAUNCH_PERF_PROBE): $(LAUNCH_PERF_BASE_OBJS) $(LAUNCH_PERF_OBJS) $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) \
	$(MAC_GUMBO_OBJS) mupdf-libs
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(LAUNCH_PERF_BASE_OBJS) $(LAUNCH_PERF_OBJS) $(CORE_OBJS) \
		$(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) -framework Cocoa -framework QuartzCore \
		-framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreServices \
		-framework Security -framework LocalAuthentication $(MAC_FRIENDS_FRAMEWORKS) -lm -Wl,-dead_strip -o \
		"$@"
.PHONY: launch-performance-probe mac-launch-performance-gate
launch-performance-probe: $(LAUNCH_PERF_PROBE)
mac-launch-performance-gate: $(LAUNCH_PERF_PROBE) $(MAC_BIN)
	python3 -I $(LAUNCH_PERF_SRC_DIR)/run-launch-performance.py --app "$(abspath $(MAC_APP))" \
		--probe "$(abspath $(LAUNCH_PERF_PROBE))" --work "$(abspath $(BUILD))/launch-performance" \
		--portable "$(CURDIR)" --mupdf "$(abspath $(MUPDF_DIR))" --launch-dir "$(abspath $(LAUNCH_PERF_SRC_DIR))"

endif
