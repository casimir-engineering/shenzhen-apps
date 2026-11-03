# Your name on comments, changed from where it is shown, on the real reader (mac/tests/SPDFMacCommentAuthorProbe.mm).
# Run from portable with: make -f Makefile -f mac/tests/comment-author-probe.mk mac-comment-author-probe
# Links the workspace probe's reader objects. The probe sets SPDF_STATE_DIR and HOME to a temporary folder, runs with a
# Prohibited activation policy and makes every window it orders in transparent and click-through. It draws the hover
# and edit states, light and dark, to build/comment-author-probe/.
include mac/tests/workspace-probe.mk
MAC_COMMENT_AUTHOR_PROBE := $(BUILD)/SPDFMacCommentAuthorProbe
MAC_COMMENT_AUTHOR_PROBE_OBJ := $(BUILD)/comment-author-probe/SPDFMacCommentAuthorProbe.o
-include $(MAC_COMMENT_AUTHOR_PROBE_OBJ:.o=.d)
$(MAC_COMMENT_AUTHOR_PROBE_OBJ): mac/tests/SPDFMacCommentAuthorProbe.mm
	@mkdir -p "$(@D)"
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore \
		-I$(MUPDF_DIR)/include -MMD -MP -c "$<" -o "$@"
# Linked inside the phony target after rm -f, so a stale binary is never mistaken for a fresh pass.
.PHONY: mac-comment-author-probe
mac-comment-author-probe: $(MAC_COMMENT_AUTHOR_PROBE_OBJ) $(MAC_WORKSPACE_PROBE_OBJS) $(CORE_OBJS) $(YAML_OBJ) \
		$(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $$(MAC_FRIENDS_LINK) mupdf-libs
	@rm -f "$(MAC_COMMENT_AUTHOR_PROBE)"
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(MAC_COMMENT_AUTHOR_PROBE_OBJ) \
		$(filter-out $(BUILD)/workspace-probe/mac/tests/SPDFMacWorkspaceProbe.o,$(MAC_WORKSPACE_PROBE_OBJS)) \
		$(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) -lpthread \
		-framework Cocoa -framework QuartzCore -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers \
		-framework CoreServices -framework Security -framework LocalAuthentication -lm -o "$(MAC_COMMENT_AUTHOR_PROBE)"
	COMMENT_AUTHOR_EVIDENCE_DIR="$(BUILD)/comment-author-probe" "$(MAC_COMMENT_AUTHOR_PROBE)"
