# Cmd+J and Cmd+K for Friends on the real reader (mac/tests/SPDFMacFriendsShortcutProbe.mm).
# Run from portable with: make -f Makefile -f mac/tests/friends-shortcut-probe.mk mac-friends-shortcut-probe
# Links the workspace probe's reader objects (every reader source, the host adapter, the Friends views, client
# library and cJSON) with the protocol area's in-process fake helper. The probe sets SPDF_STATE_DIR and
# SZFRIENDS_STATE_DIR to a temporary folder, runs with a Prohibited activation policy (no Dock icon, never active)
# and makes every window it orders in transparent and click-through. It draws the Cmd+K palette to
# build/friends-shortcut-probe/palette.png.
include mac/tests/workspace-probe.mk
MAC_FRIENDS_SHORTCUT_PROBE := $(BUILD)/SPDFMacFriendsShortcutProbe
MAC_FRIENDS_SHORTCUT_PROBE_OBJ := $(BUILD)/friends-shortcut-probe/SPDFMacFriendsShortcutProbe.o
-include $(MAC_FRIENDS_SHORTCUT_PROBE_OBJ:.o=.d)
$(MAC_FRIENDS_SHORTCUT_PROBE_OBJ): mac/tests/SPDFMacFriendsShortcutProbe.mm
	@mkdir -p "$(@D)"
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore \
		-I$(MUPDF_DIR)/include -Ifriends -Imac/friends -MMD -MP -c "$<" -o "$@"
# Compiled inside the phony target after rm -f, so a stale binary is never mistaken for a fresh pass.
.PHONY: mac-friends-shortcut-probe
mac-friends-shortcut-probe: $(MAC_FRIENDS_SHORTCUT_PROBE_OBJ) $(MAC_WORKSPACE_PROBE_OBJS) $(CORE_OBJS) $(YAML_OBJ) \
		$(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $$(MAC_FRIENDS_LINK) $$(FRIENDS_FAKE_HELPER_LIB) mupdf-libs
	@rm -f "$(MAC_FRIENDS_SHORTCUT_PROBE)"
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(MAC_FRIENDS_SHORTCUT_PROBE_OBJ) \
		$(filter-out $(BUILD)/workspace-probe/mac/tests/SPDFMacWorkspaceProbe.o,$(MAC_WORKSPACE_PROBE_OBJS)) \
		$(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) $(FRIENDS_FAKE_HELPER_LIB) -lpthread \
		-framework Cocoa -framework QuartzCore -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers \
		-framework CoreServices -framework Security -framework LocalAuthentication -lm -o "$(MAC_FRIENDS_SHORTCUT_PROBE)"
	SPDF_PALETTE_SHOT="$(BUILD)/friends-shortcut-probe/palette.png" "$(MAC_FRIENDS_SHORTCUT_PROBE)"
