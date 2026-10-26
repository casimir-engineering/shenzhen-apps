ifndef SPDF_WORKSPACE_PROBE_INCLUDED
SPDF_WORKSPACE_PROBE_INCLUDED := 1
# Run from portable with: make -f Makefile -f mac/tests/workspace-probe.mk mac-workspace-probe
# Compiles the actual reader, replacing only its entry point. No app bundle is
# started and no updater runs. Click-routing checks briefly realize a fully
# transparent offscreen fixture; all other window presentation is forbidden.
MAC_WORKSPACE_PROBE := $(BUILD)/SPDFMacWorkspaceProbe
MAC_WORKSPACE_PROBE_SRCS := mac/tests/SPDFMacWorkspaceProbe.mm mac/tests/SPDFMacSidebarHitProbe.mm $(MAC_SRCS)
MAC_WORKSPACE_PROBE_OBJS := $(patsubst %.mm,$(BUILD)/workspace-probe/%.o,$(MAC_WORKSPACE_PROBE_SRCS))
.PHONY: mac-workspace-probe
-include $(MAC_WORKSPACE_PROBE_OBJS:.o=.d)
$(BUILD)/workspace-probe/%.o: %.mm
	@mkdir -p "$(@D)"
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Dmain=spdf_reader_entrypoint -Imac -Icore -I$(MUPDF_DIR)/include -MMD -MP -c "$<" -o "$@"
$(MAC_WORKSPACE_PROBE): $(MAC_WORKSPACE_PROBE_OBJS) $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) mupdf-libs | $(BUILD)
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(MAC_WORKSPACE_PROBE_OBJS) $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) -framework Cocoa -framework QuartzCore -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreServices -framework Security -framework LocalAuthentication -lm -Wl,-dead_strip -Wl,-x -o "$@"
mac-workspace-probe: $(MAC_WORKSPACE_PROBE)
	"$(MAC_WORKSPACE_PROBE)" "$(WORKSPACE_EVIDENCE_DIR)"

# Public README fixtures reuse the production objects from the workspace probe.
MAC_README_PROBE := $(BUILD)/SPDFMacReadmeProbe
MAC_README_PROBE_OBJS := $(filter-out $(BUILD)/workspace-probe/mac/tests/SPDFMacWorkspaceProbe.o,$(MAC_WORKSPACE_PROBE_OBJS)) $(BUILD)/workspace-probe/mac/tests/SPDFMacReadmeProbe.o
-include $(MAC_README_PROBE_OBJS:.o=.d)
$(MAC_README_PROBE): $(MAC_README_PROBE_OBJS) $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) mupdf-libs
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(MAC_README_PROBE_OBJS) $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) -framework Cocoa -framework QuartzCore -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreServices -framework Security -framework LocalAuthentication -lm -Wl,-dead_strip -Wl,-x -o "$@"
.PHONY: mac-readme-probe
mac-readme-probe: $(MAC_README_PROBE)
	"$(MAC_README_PROBE)" "$(WORKSPACE_EVIDENCE_DIR)"

# Scripted cross-document comparison, rendered by the real chat/card components.
MAC_AI_README_PROBE := $(BUILD)/SPDFMacAIReadmeProbe
MAC_AI_README_OBJS := $(filter-out $(BUILD)/workspace-probe/mac/tests/SPDFMacWorkspaceProbe.o,$(MAC_WORKSPACE_PROBE_OBJS)) $(BUILD)/workspace-probe/mac/tests/SPDFMacAIReadmeProbe.o
-include $(MAC_AI_README_OBJS:.o=.d)
$(MAC_AI_README_PROBE): $(MAC_AI_README_OBJS) $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) mupdf-libs
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(MAC_AI_README_OBJS) $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) -framework Cocoa -framework QuartzCore -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreServices -framework Security -framework LocalAuthentication -lm -Wl,-dead_strip -o "$@"
.PHONY: mac-ai-readme-probe
mac-ai-readme-probe: $(MAC_AI_README_PROBE)
	"$(MAC_AI_README_PROBE)" "$(WORKSPACE_EVIDENCE_DIR)"

# A citation whose tab has closed: inline link and source card clicked through the real reader, chat and Collection.
MAC_AI_SOURCE_CARD_PROBE := $(BUILD)/SPDFMacAISourceCardProbe
MAC_AI_SOURCE_CARD_OBJS := $(filter-out $(BUILD)/workspace-probe/mac/tests/SPDFMacWorkspaceProbe.o,$(MAC_WORKSPACE_PROBE_OBJS)) $(BUILD)/workspace-probe/mac/tests/SPDFMacAISourceCardProbe.o
-include $(MAC_AI_SOURCE_CARD_OBJS:.o=.d)
$(MAC_AI_SOURCE_CARD_PROBE): $(MAC_AI_SOURCE_CARD_OBJS) $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) mupdf-libs
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(MAC_AI_SOURCE_CARD_OBJS) $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) -framework Cocoa -framework QuartzCore -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreServices -framework Security -framework LocalAuthentication -lm -Wl,-dead_strip -o "$@"
.PHONY: mac-ai-source-card-probe
mac-ai-source-card-probe: $(MAC_AI_SOURCE_CARD_PROBE)
	"$(MAC_AI_SOURCE_CARD_PROBE)" "$(WORKSPACE_EVIDENCE_DIR)"

endif
