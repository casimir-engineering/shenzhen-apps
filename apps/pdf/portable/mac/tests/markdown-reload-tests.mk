ifndef SPDF_MARKDOWN_RELOAD_TESTS_INCLUDED
SPDF_MARKDOWN_RELOAD_TESTS_INCLUDED := 1
# Production-linked: the real reader opens a Markdown file offscreen and rereads
# it the way the file watcher does. No window is shown and no state outside a
# temporary directory is touched.
include mac/tests/workspace-probe.mk
MARKDOWN_RELOAD_BASE_OBJS := $(filter-out $(BUILD)/workspace-probe/mac/tests/SPDFMacWorkspaceProbe.o,$(MAC_WORKSPACE_PROBE_OBJS))
MARKDOWN_RELOAD_TEST := $(BUILD)/SPDFMacMarkdownReloadSidebarTests
-include $(BUILD)/workspace-probe/mac/tests/SPDFMacMarkdownReloadSidebarTests.d
$(MARKDOWN_RELOAD_TEST): $(MARKDOWN_RELOAD_BASE_OBJS) $(BUILD)/workspace-probe/mac/tests/SPDFMacMarkdownReloadSidebarTests.o $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) mupdf-libs
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(MARKDOWN_RELOAD_BASE_OBJS) $(BUILD)/workspace-probe/mac/tests/SPDFMacMarkdownReloadSidebarTests.o $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) -framework Cocoa -framework QuartzCore -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreServices -framework Security -framework LocalAuthentication -lm -Wl,-dead_strip -o "$@"
.PHONY: mac-markdown-reload-acceptance
mac-markdown-reload-acceptance: $(MARKDOWN_RELOAD_TEST)
	"$(MARKDOWN_RELOAD_TEST)"

endif
