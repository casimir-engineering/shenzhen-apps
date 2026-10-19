ifndef SPDF_PAGE_DISPLAY_TESTS_INCLUDED
SPDF_PAGE_DISPLAY_TESTS_INCLUDED := 1
# Production-linked page-display scenarios: the real reader and render queues
# run offscreen against synthetic documents at a forced 2x backing scale. No
# window is shown and no state outside a temporary directory is touched.
include mac/tests/workspace-probe.mk
PAGE_DISPLAY_BASE_OBJS := $(filter-out $(BUILD)/workspace-probe/mac/tests/SPDFMacWorkspaceProbe.o,$(MAC_WORKSPACE_PROBE_OBJS))
PAGE_DISPLAY_TEST_SRCS := mac/tests/SPDFMacPageDisplayTests.mm mac/tests/SPDFMacPageDisplaySidebarTests.mm
PAGE_DISPLAY_TEST_OBJS := $(patsubst %.mm,$(BUILD)/workspace-probe/%.o,$(PAGE_DISPLAY_TEST_SRCS))
PAGE_DISPLAY_TEST := $(BUILD)/SPDFMacPageDisplayTests
-include $(PAGE_DISPLAY_TEST_OBJS:.o=.d)
$(PAGE_DISPLAY_TEST): $(PAGE_DISPLAY_BASE_OBJS) $(PAGE_DISPLAY_TEST_OBJS) $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) mupdf-libs
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(PAGE_DISPLAY_BASE_OBJS) $(PAGE_DISPLAY_TEST_OBJS) $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) -framework Cocoa -framework QuartzCore -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreServices -framework Security -framework LocalAuthentication -lm -Wl,-dead_strip -o "$@"
.PHONY: mac-page-display-acceptance
mac-page-display-acceptance: $(PAGE_DISPLAY_TEST)
	"$(PAGE_DISPLAY_TEST)"

endif
