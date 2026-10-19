ifndef SPDF_MINIMAP_FILL_TESTS_INCLUDED
SPDF_MINIMAP_FILL_TESTS_INCLUDED := 1
# Production-linked minimap scenarios: the real reader, render queues and strip
# run offscreen against synthetic drawing sets. No window is shown and no state
# outside a temporary directory is touched.
include mac/tests/workspace-probe.mk
MINIMAP_FILL_BASE_OBJS := $(filter-out $(BUILD)/workspace-probe/mac/tests/SPDFMacWorkspaceProbe.o,$(MAC_WORKSPACE_PROBE_OBJS))
MINIMAP_FILL_TEST := $(BUILD)/SPDFMacMinimapFillTests
-include $(BUILD)/workspace-probe/mac/tests/SPDFMacMinimapFillTests.d
$(MINIMAP_FILL_TEST): $(MINIMAP_FILL_BASE_OBJS) $(BUILD)/workspace-probe/mac/tests/SPDFMacMinimapFillTests.o $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) mupdf-libs
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(MINIMAP_FILL_BASE_OBJS) $(BUILD)/workspace-probe/mac/tests/SPDFMacMinimapFillTests.o $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) -framework Cocoa -framework QuartzCore -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreServices -framework Security -framework LocalAuthentication -lm -Wl,-dead_strip -o "$@"
.PHONY: mac-minimap-fill-acceptance
mac-minimap-fill-acceptance: $(MINIMAP_FILL_TEST)
	"$(MINIMAP_FILL_TEST)"

endif
