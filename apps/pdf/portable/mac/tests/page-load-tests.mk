ifndef SPDF_PAGE_LOAD_TESTS_INCLUDED
SPDF_PAGE_LOAD_TESTS_INCLUDED := 1
# Production-linked page-load scenarios: the real reader and render queues run
# offscreen against synthetic drawing sets at a forced 2x backing scale. No
# window is shown and no state outside a temporary directory is touched.
include mac/tests/workspace-probe.mk
PAGE_LOAD_BASE_OBJS := $(filter-out $(BUILD)/workspace-probe/mac/tests/SPDFMacWorkspaceProbe.o,$(MAC_WORKSPACE_PROBE_OBJS))
PAGE_LOAD_TEST := $(BUILD)/SPDFMacPageLoadTests
-include $(BUILD)/workspace-probe/mac/tests/SPDFMacPageLoadTests.d
$(PAGE_LOAD_TEST): $(PAGE_LOAD_BASE_OBJS) $(BUILD)/workspace-probe/mac/tests/SPDFMacPageLoadTests.o $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) mupdf-libs
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(PAGE_LOAD_BASE_OBJS) $(BUILD)/workspace-probe/mac/tests/SPDFMacPageLoadTests.o $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) -framework Cocoa -framework QuartzCore -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreServices -framework Security -framework LocalAuthentication -lm -Wl,-dead_strip -o "$@"
.PHONY: mac-page-load-acceptance
mac-page-load-acceptance: $(PAGE_LOAD_TEST)
	"$(PAGE_LOAD_TEST)"

endif
