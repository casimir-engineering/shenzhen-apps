BUILD := build
DIST := ../dist
MUPDF_DIR := ../mupdf
UNAME_S := $(shell uname -s)
SPDF_RELEASE_MODE ?= 0
MAC_ARCH ?= arm64
MACOSX_DEPLOYMENT_TARGET ?= 12.0
MAC_BUNDLE_ID ?= com.intuition.shenzhenpdf
MAC_TEAM_ID ?= 66LJ4BV7Q3
PORTABLE_OPTFLAGS ?= -O2 -DNDEBUG
PORTABLE_TEST_OPTFLAGS := $(filter-out -DNDEBUG,$(PORTABLE_OPTFLAGS))

ifeq ($(SPDF_RELEASE_MODE),1)
override MAC_ARCH := arm64
override MACOSX_DEPLOYMENT_TARGET := 12.0
override MAC_BUNDLE_ID := com.intuition.shenzhenpdf
override MAC_TEAM_ID := 66LJ4BV7Q3
override PORTABLE_OPTFLAGS := -O2 -DNDEBUG
endif

# Where the mupdf static libs live, relative to $(MUPDF_DIR). Overridable so
# builds for another distro's toolchain don't clobber the default output
# (build-rpm.sh uses MUPDF_OUT=build/release-fedora).
ifeq ($(UNAME_S),Darwin)
MAC_TARGET_FLAGS := -arch $(MAC_ARCH) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)
MUPDF_MAC_ARGS := ARCHFLAGS="-arch $(MAC_ARCH)" XCFLAGS="$(MAC_TARGET_FLAGS)"
MUPDF_OUT ?= build/release-macos-$(MAC_ARCH)-$(MACOSX_DEPLOYMENT_TARGET)
export MACOSX_DEPLOYMENT_TARGET
else
MAC_TARGET_FLAGS :=
MUPDF_MAC_ARGS :=
MUPDF_OUT ?= build/release
endif
MUPDF_BUILD := $(MUPDF_DIR)/$(MUPDF_OUT)
MUPDF_LIBS := $(MUPDF_BUILD)/libmupdf.a $(MUPDF_BUILD)/libmupdf-third.a $(MUPDF_BUILD)/libmupdf-pkcs7.a
CPU := $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
# Records a suite that passed on this commit (tools/test-stamp.sh), so tools/release.sh does not run it again on the
# same commit. The tool exists only in the Shenzhen repository; a partial run (a subset of flows, fewer rounds) records
# nothing.
SPDF_TEST_STAMP_TOOL := $(wildcard $(CURDIR)/../../../tools/test-stamp.sh)
spdf_test_stamp = $(if $(SPDF_TEST_STAMP_TOOL),@"$(SPDF_TEST_STAMP_TOOL)" record pdf/$(1),@:)

CORE_SRC := core/shenzhen_pdf_core.c
CORE_HDR := core/shenzhen_pdf_core.h
CORE_OBJ := $(BUILD)/shenzhen_pdf_core.o
CORE_SELECTION_SRC := core/spdf_selection.c
CORE_SELECTION_HDR := core/spdf_selection.h
CORE_SELECTION_OBJ := $(BUILD)/spdf_selection.o
CORE_SELECTION_SUPPORT_SRC := core/spdf_selection_support.c
CORE_SELECTION_SUPPORT_OBJ := $(BUILD)/spdf_selection_support.o
CORE_RECOLOR_SRC := core/spdf_recolor.c
CORE_RECOLOR_HDR := core/spdf_recolor.h
CORE_RECOLOR_OBJ := $(BUILD)/spdf_recolor.o
CORE_IMAGE_PROPERTIES_OBJ := $(BUILD)/spdf_image_properties.o
CORE_PAGE_IMAGES_OBJ := $(BUILD)/spdf_page_images.o
CORE_OBJS := $(CORE_OBJ) $(CORE_SELECTION_OBJ) $(CORE_SELECTION_SUPPORT_OBJ) $(CORE_RECOLOR_OBJ) $(CORE_IMAGE_PROPERTIES_OBJ) \
	$(CORE_PAGE_IMAGES_OBJ)
YAML_SRC := core/spdf_yaml.c
YAML_HDR := core/spdf_yaml.h
YAML_OBJ := $(BUILD)/spdf_yaml.o
MAC_MD4C_OBJ := $(BUILD)/md4c.o
# Vendored Gumbo HTML5 parser (pure C, no dependencies) backing the Markdown
# reader's sanitizing HTML-island whitelist (portable/mac/markdown/SPDFMarkdownHTML*.mm).
MAC_GUMBO_SRCS := $(sort $(wildcard ../ext/gumbo-parser/src/*.c))
MAC_GUMBO_OBJS := $(patsubst ../ext/gumbo-parser/src/%.c,$(BUILD)/gumbo-%.o,$(MAC_GUMBO_SRCS))
CORE_OUTLINE_TEST := $(BUILD)/SPDFCoreOutlineTests
CORE_TEXT_DETECTION_TEST := $(BUILD)/SPDFCoreTextDetectionTests
CORE_PARTIAL_OCR_TEST := $(BUILD)/SPDFCorePartialOCRTests
MAC_OCR_INSTALL_TEST := $(BUILD)/SPDFMacOCRInstallTests
MAC_TOOL_ENV_TEST := $(BUILD)/SPDFMacToolEnvironmentTests
MAC_OCR_VALIDATION_TEST := $(BUILD)/SPDFMacOCRValidationTests
MAC_OCR_COMMAND_TEST := $(BUILD)/SPDFMacOCRCommandTests
CORE_PASSWORD_TEST := $(BUILD)/SPDFCorePasswordTests
CORE_RECOLOR_TEST := $(BUILD)/SPDFCoreRecolorTests
CORE_RENDER_THEME_TEST := $(BUILD)/SPDFCoreRenderThemeTests
CORE_RECOLOR_PROBE := $(BUILD)/SPDFRecolorProbe
CORE_SELECTION_TEST := $(BUILD)/SPDFCoreSelectionTests
CORE_CJK_SELECTION_TEST := $(BUILD)/SPDFCoreCJKSelectionTests
MAC_APP := $(DIST)/ShenzhenPDF.app
MAC_BIN := $(MAC_APP)/Contents/MacOS/ShenzhenPDF
MAC_COLLECTION_BIN := $(BUILD)/ShenzhenPDFCollection
MAC_COLLECTION_APP := $(MAC_APP)/Contents/Helpers/ShenzhenPDF Collection.app
MAC_DMG := $(DIST)/ShenzhenPDF-mac-arm64.dmg
MAC_ICON_SRCS := $(addprefix ../gfx/ShenzhenPDF-,$(addsuffix x32.png,16x16 32x32 64x64 128x128 256x256 512x512 1024x1024))
MAC_WINDOW_SHORTCUT_TEST := $(BUILD)/SPDFMacWindowShortcutsTests
MAC_WINDOW_CHROME_TEST := $(BUILD)/SPDFMacWindowChromeTests
MAC_PASSWORD_TEST := $(BUILD)/SPDFMacPasswordTests
MAC_MINIMAP_WINDOW_TEST := $(BUILD)/SPDFMacMinimapWindowTests
MAC_TAB_STRIP_GEOMETRY_TEST := $(BUILD)/SPDFMacTabStripGeometryTests
MAC_TAB_STRIP_INTERACTION_TEST := $(BUILD)/SPDFMacTabStripInteractionTests
MAC_TAB_STRIP_STYLE_TEST := $(BUILD)/SPDFMacTabStripStyleTests
MAC_READING_THEME_CHROME_TEST := $(BUILD)/SPDFMacReadingThemeChromeTests
MAC_PALETTE_RESULTS_TEST := $(BUILD)/SPDFMacPaletteResultsTests
MAC_FIND_NEAREST_TEST := $(BUILD)/SPDFMacFindNearestTests
MAC_UPDATER_TEST := $(BUILD)/SPDFUpdaterTests
MAC_PROPERTIES_FORMAT_TEST := $(BUILD)/SPDFMacPropertiesFormatTests
MAC_TRANSLATION_FILTER_TEST := $(BUILD)/SPDFTranslationChineseFilterTests
MAC_TRANSLATION_COPY_TEST := $(BUILD)/SPDFTranslationCopyTests
MAC_CURSOR_REGION_TEST := $(BUILD)/SPDFMacCursorRegionsTests
MAC_TAB_LIFECYCLE_TEST := $(BUILD)/SPDFMacTabLifecycleTests
MAC_TAB_STATE_TEST := $(BUILD)/SPDFMacTabStateTests
MAC_SIDEBAR_OUTLINE_TEST := $(BUILD)/SPDFMacSidebarOutlineTests
MAC_PAGE_WHEEL_TEST := $(BUILD)/SPDFMacPageWheelTests
MAC_FILE_EXPLORER_TEST := $(BUILD)/SPDFMacFileExplorerPreferenceTests
MAC_SELECTION_CLICK_TEST := $(BUILD)/SPDFMacSelectionClickTests
MAC_SELECTION_ADAPTER_TEST := $(BUILD)/SPDFMacSelectionAdapterTests
MAC_LAUNCH_WORK_POLICY_TEST := $(BUILD)/SPDFMacLaunchWorkPolicyTests
MAC_STATE_YAML_TEST := $(BUILD)/SPDFStateYamlTests
MAC_DOCUMENT_ACTIVITY_TEST := $(BUILD)/SPDFMacDocumentActivityTests
MAC_RELEASE_NOTES_PREVIEW := $(BUILD)/SPDFReleaseNotesPreview
# Exclude standalone test translation units (each defines its own main()).
MAC_MARKDOWN_SRCS := $(sort $(wildcard mac/markdown/*.mm))
include mac/companion/sources.mk
MAC_SRCS := $(filter-out mac/SPDFUpdaterTests.mm,$(sort $(wildcard mac/*.mm))) $(MAC_MARKDOWN_SRCS)
MAC_HDRS := $(sort $(wildcard mac/*.h) $(wildcard mac/markdown/*.h))
# The reader's sources compile one object each, across all cores, with the headers each includes recorded by -MMD,
# so a change recompiles only what it touches; they used to compile in one clang++ call, one file after the other,
# every time the app was built. The flags are written to MAC_APP_FLAGS_FILE, which every object depends on, so building
# with other flags (PORTABLE_OPTFLAGS, MAC_ARCH, release mode) recompiles them all.
MAC_APP_OBJ_DIR := $(BUILD)/mac-app
MAC_APP_OBJS := $(patsubst %.mm,$(MAC_APP_OBJ_DIR)/%.o,$(MAC_SRCS))
MAC_APP_COMPILE_FLAGS = $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac -Icore -I$(MUPDF_DIR)/include
MAC_APP_FLAGS_FILE := $(MAC_APP_OBJ_DIR)/compile-flags
MAC_VERSION ?= 26.10.25
MAC_BUILD ?= 4
# The release this app is, as people see it and the updater compares it (mac/Info.plist SZFReleaseTag, which
# cut-release.sh sets). MAC_BUILD alone is not it: Friends changes raise MAC_BUILD between releases.
MAC_RELEASE_TAG ?=
MAC_SIGN_IDENTITY ?= -
NOTARY_PROFILE ?=
NOTARY_RESULT ?= $(DIST)/notarytool-$(MAC_VERSION)-$(MAC_BUILD).json

ifeq ($(MAC_SIGN_IDENTITY),-)
MAC_CODESIGN_APP = codesign --force --sign - "$(MAC_APP)"
MAC_CODESIGN_DMG = true
else
MAC_CODESIGN_APP = codesign --force --timestamp --options runtime --sign "$(MAC_SIGN_IDENTITY)" "$(MAC_APP)"
MAC_CODESIGN_DMG = codesign --force --timestamp --sign "$(MAC_SIGN_IDENTITY)" "$(MAC_DMG)"
endif

# `make mac` is the obvious thing to type, and `mac` is also the source
# directory -- without this alias make finds that directory, decides it is up to
# date, and prints "Nothing to be done for `mac'", which reads exactly like a
# successful build that had nothing to do. Hours of "it builds clean" were
# reported off that message while the binary was never relinked.
.PHONY: mac
mac: mac-app

.PHONY: all mac-app core-outline-tests core-password-tests core-recolor-tests core-render-theme-tests core-recolor-probe core-selection-tests icon-tests mac-window-shortcut-tests mac-window-chrome-tests mac-password-tests mac-minimap-window-tests mac-tab-strip-geometry-tests mac-tab-strip-interaction-tests mac-tab-strip-style-tests mac-reading-theme-chrome-tests mac-palette-results-tests mac-find-nearest-tests mac-updater-tests mac-properties-format-tests mac-translation-filter-tests mac-translation-copy-tests mac-cursor-region-tests mac-state-yaml-tests mac-tab-lifecycle-tests mac-tab-state-tests mac-sidebar-outline-tests mac-page-wheel-tests mac-file-explorer-tests mac-selection-click-tests mac-selection-adapter-tests mac-launch-work-policy-tests mac-markdown-tests linux-password-tests file-size-ratchet-tests release-pipeline-tests test-binaries release-notes-preview print-release-config dmg notarize staple release-dmg release-dmg-artifact verify-mac-release verify-mac-unsigned print-mac-signing-identities install clean mupdf-libs linux

all: mac-app

mupdf-libs:
	@test -f "$(MUPDF_BUILD)/libmupdf.a" -a -f "$(MUPDF_BUILD)/libmupdf-third.a" || $(MAKE) -C "$(MUPDF_DIR)" -j$(CPU) build=release OUT="$(MUPDF_OUT)" $(MUPDF_MAC_ARGS) USE_SYSTEM_GLUT=yes brotli=no libs "$(MUPDF_OUT)/libmupdf-third.a"
	@test -f "$(MUPDF_BUILD)/libmupdf-pkcs7.a" || $(MAKE) -C "$(MUPDF_DIR)" -j$(CPU) build=release OUT="$(MUPDF_OUT)" $(MUPDF_MAC_ARGS) USE_SYSTEM_GLUT=yes brotli=no "$(MUPDF_OUT)/libmupdf-pkcs7.a"

$(BUILD):
	mkdir -p "$(BUILD)"

$(CORE_OBJ): $(CORE_SRC) $(CORE_HDR) core/spdf_search_regex.h core/spdf_render_bitmap.h Makefile | $(BUILD)
	clang $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Icore -I$(MUPDF_DIR)/include -c "$(CORE_SRC)" -o "$(CORE_OBJ)"

$(CORE_IMAGE_PROPERTIES_OBJ): core/spdf_image_properties.c core/spdf_image_properties.h Makefile | $(BUILD)
	clang $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Wall -Wextra -Werror -Icore -I$(MUPDF_DIR)/include -c $< -o "$@"

$(CORE_PAGE_IMAGES_OBJ): core/spdf_page_images.c core/spdf_page_images.h Makefile | $(BUILD)
	clang $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Wall -Wextra -Werror -Icore -I$(MUPDF_DIR)/include -c $< -o "$@"

$(CORE_SELECTION_OBJ): $(CORE_SELECTION_SRC) $(CORE_SELECTION_HDR) $(CORE_HDR) Makefile | $(BUILD)
	clang $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Icore -I$(MUPDF_DIR)/include -c "$(CORE_SELECTION_SRC)" -o "$(CORE_SELECTION_OBJ)"

$(CORE_SELECTION_SUPPORT_OBJ): $(CORE_SELECTION_SUPPORT_SRC) $(CORE_SELECTION_HDR) $(CORE_HDR) Makefile | $(BUILD)
	clang $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Icore -I$(MUPDF_DIR)/include -c "$(CORE_SELECTION_SUPPORT_SRC)" -o "$(CORE_SELECTION_SUPPORT_OBJ)"

$(CORE_RECOLOR_OBJ): $(CORE_RECOLOR_SRC) $(CORE_RECOLOR_HDR) Makefile | $(BUILD)
	clang $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Wall -Wextra -Werror -Icore -c "$(CORE_RECOLOR_SRC)" -o "$(CORE_RECOLOR_OBJ)"

$(MAC_MD4C_OBJ): ../ext/md4c/md4c.c ../ext/md4c/md4c.h Makefile | $(BUILD)
	clang $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c11 -I../ext/md4c -c ../ext/md4c/md4c.c -o "$(MAC_MD4C_OBJ)"

$(BUILD)/gumbo-%.o: ../ext/gumbo-parser/src/%.c Makefile | $(BUILD)
	clang $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c99 -I../ext/gumbo-parser/src -c $< -o $@

$(YAML_OBJ): $(YAML_SRC) $(YAML_HDR) Makefile | $(BUILD)
	clang $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Icore -c "$(YAML_SRC)" -o "$(YAML_OBJ)"

mac-app: $(MAC_BIN)

$(CORE_OUTLINE_TEST): core/tests/SPDFCoreOutlineTests.c $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	$(CC) $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Wall -Wextra -Icore -I$(MUPDF_DIR)/include $< "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) $(if $(filter Darwin,$(UNAME_S)),-framework Foundation) -lm -o "$@"

core-outline-tests: $(CORE_OUTLINE_TEST)
	"$(CORE_OUTLINE_TEST)"

$(CORE_TEXT_DETECTION_TEST): core/tests/SPDFCoreTextDetectionTests.c $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	$(CC) $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Wall -Wextra -Icore -I$(MUPDF_DIR)/include $< "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) $(if $(filter Darwin,$(UNAME_S)),-framework Foundation) -lm -o "$@"

core-text-detection-tests: $(CORE_TEXT_DETECTION_TEST)
	"$(CORE_TEXT_DETECTION_TEST)"

$(CORE_PARTIAL_OCR_TEST): core/tests/SPDFCorePartialOCRTests.c $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	$(CC) $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Wall -Wextra -Werror -Icore -I$(MUPDF_DIR)/include $< "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) $(if $(filter Darwin,$(UNAME_S)),-framework Foundation) -lm -o "$@"

core-partial-ocr-tests: $(CORE_PARTIAL_OCR_TEST)
	"$(CORE_PARTIAL_OCR_TEST)"

$(MAC_OCR_INSTALL_TEST): mac/tests/SPDFMacOCRInstallTests.mm mac/SPDFMacOCRInstall.mm mac/SPDFMacOCRInstall.h mac/SPDFMacToolEnvironment.mm mac/SPDFMacSupport.mm mac/SPDFMacToolbarSegments.mm | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore mac/tests/SPDFMacOCRInstallTests.mm mac/SPDFMacOCRInstall.mm mac/SPDFMacToolEnvironment.mm mac/SPDFMacSupport.mm mac/SPDFMacToolbarSegments.mm -framework Cocoa -framework UniformTypeIdentifiers -o "$@"

mac-ocr-install-tests: $(MAC_OCR_INSTALL_TEST)
	"$(MAC_OCR_INSTALL_TEST)"

$(MAC_TOOL_ENV_TEST): mac/tests/SPDFMacToolEnvironmentTests.mm mac/SPDFMacToolEnvironment.mm mac/SPDFMacToolEnvironment.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore mac/tests/SPDFMacToolEnvironmentTests.mm mac/SPDFMacToolEnvironment.mm -framework Cocoa -o "$@"

mac-tool-environment-tests: $(MAC_TOOL_ENV_TEST)
	"$(MAC_TOOL_ENV_TEST)"

$(MAC_OCR_VALIDATION_TEST): mac/tests/SPDFMacOCRValidationTests.mm mac/SPDFMacOCRValidation.mm mac/SPDFMacOCRValidation.h $(CORE_OBJS) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacOCRValidationTests.mm mac/SPDFMacOCRValidation.mm $(CORE_OBJS) $(MUPDF_LIBS) -framework Cocoa -lm -o "$@"

mac-ocr-validation-tests: $(MAC_OCR_VALIDATION_TEST)
	"$(MAC_OCR_VALIDATION_TEST)"

$(MAC_OCR_COMMAND_TEST): mac/tests/SPDFMacOCRCommandTests.mm mac/SPDFMacOCRCommand.mm mac/SPDFMacOCRCommand.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacOCRCommandTests.mm mac/SPDFMacOCRCommand.mm -framework Cocoa -o "$@"

mac-ocr-command-tests: $(MAC_OCR_COMMAND_TEST)
	"$(MAC_OCR_COMMAND_TEST)"

$(CORE_PASSWORD_TEST): core/tests/SPDFCorePasswordTests.c $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	$(CC) $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Wall -Wextra -Icore -I$(MUPDF_DIR)/include $< "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) $(if $(filter Darwin,$(UNAME_S)),-framework Foundation) -lm -o "$@"

core-password-tests: $(CORE_PASSWORD_TEST)
	core/tests/run_password_tests.sh "$(CORE_PASSWORD_TEST)"

$(CORE_RECOLOR_TEST): core/tests/SPDFCoreRecolorTests.c $(CORE_RECOLOR_OBJ) | $(BUILD)
	$(CC) $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Wall -Wextra -Werror -Icore $< "$(CORE_RECOLOR_OBJ)" -lm -o "$@"

core-recolor-tests: $(CORE_RECOLOR_TEST)
	"$(CORE_RECOLOR_TEST)"

$(CORE_RENDER_THEME_TEST): core/tests/SPDFCoreRenderThemeTests.c $(CORE_OBJS) mupdf-libs | $(BUILD)
	$(CC) $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Wall -Wextra -Werror -Icore -I$(MUPDF_DIR)/include $< $(CORE_OBJS) $(MUPDF_LIBS) $(if $(filter Darwin,$(UNAME_S)),-framework Foundation) -lm -o "$@"

core-render-theme-tests: $(CORE_RENDER_THEME_TEST)
	"$(CORE_RENDER_THEME_TEST)"

# Not part of the test suite: renders a real page with and without the dark
# reading theme, times every transform and writes before/after PNGs, so recolor
# quality and cost can be judged from pixels rather than argued.
$(CORE_RECOLOR_PROBE): core/tests/SPDFRecolorProbe.c $(CORE_OBJS) mupdf-libs | $(BUILD)
	$(CC) $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Wall -Wextra -Icore -I$(MUPDF_DIR)/include $< $(CORE_OBJS) $(MUPDF_LIBS) $(if $(filter Darwin,$(UNAME_S)),-framework Foundation) -lm -o "$@"

core-recolor-probe: $(CORE_RECOLOR_PROBE)

$(CORE_SELECTION_TEST): core/tests/SPDFCoreSelectionTests.c $(CORE_OBJS) mupdf-libs | $(BUILD)
	$(CC) $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Wall -Wextra -Icore -I$(MUPDF_DIR)/include $< $(CORE_OBJS) $(MUPDF_LIBS) $(if $(filter Darwin,$(UNAME_S)),-framework Foundation) -lm -o "$@"

$(CORE_CJK_SELECTION_TEST): core/tests/SPDFCoreCJKSelectionTests.c $(CORE_OBJS) mupdf-libs | $(BUILD)
	$(CC) $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -Wall -Wextra -Icore -I$(MUPDF_DIR)/include $< $(CORE_OBJS) $(MUPDF_LIBS) $(if $(filter Darwin,$(UNAME_S)),-framework Foundation) -lm -o "$@"

core-selection-tests: $(CORE_SELECTION_TEST) $(CORE_CJK_SELECTION_TEST)
	"$(CORE_SELECTION_TEST)"
	"$(CORE_CJK_SELECTION_TEST)"

$(MAC_WINDOW_SHORTCUT_TEST): mac/tests/SPDFMacWindowShortcutsTests.mm mac/SPDFMacWindowShortcuts.mm mac/SPDFMacWindowShortcuts.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac mac/tests/SPDFMacWindowShortcutsTests.mm mac/SPDFMacWindowShortcuts.mm -framework Cocoa -o "$(MAC_WINDOW_SHORTCUT_TEST)"

mac-window-shortcut-tests: $(MAC_WINDOW_SHORTCUT_TEST)
	"$(MAC_WINDOW_SHORTCUT_TEST)"

$(MAC_WINDOW_CHROME_TEST): mac/tests/SPDFMacWindowChromeTests.mm mac/SPDFMacWindowChrome.mm mac/SPDFMacWindowChrome.h mac/SPDFMacWindowPlacement.mm mac/SPDFMacWindowPlacement.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac mac/tests/SPDFMacWindowChromeTests.mm mac/SPDFMacWindowChrome.mm mac/SPDFMacWindowPlacement.mm -framework Cocoa -o "$(MAC_WINDOW_CHROME_TEST)"

mac-window-chrome-tests: $(MAC_WINDOW_CHROME_TEST)
	"$(MAC_WINDOW_CHROME_TEST)"

$(MAC_PASSWORD_TEST): mac/tests/SPDFMacPasswordTests.mm mac/SPDFMacPassword.mm mac/SPDFMacPasswordCredentials.mm mac/SPDFMacPassword.h $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacPasswordTests.mm mac/SPDFMacPassword.mm mac/SPDFMacPasswordCredentials.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -lm -o "$(MAC_PASSWORD_TEST)"

mac-password-tests: $(MAC_PASSWORD_TEST)
	"$(MAC_PASSWORD_TEST)"
	mac/tests/SPDFMacPasswordSourceTests.sh

$(MAC_MINIMAP_WINDOW_TEST): mac/tests/SPDFMacMinimapWindowTests.mm mac/SPDFMacMinimapWindow.mm mac/SPDFMacMinimapWindow.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac mac/tests/SPDFMacMinimapWindowTests.mm mac/SPDFMacMinimapWindow.mm -framework Cocoa -o "$(MAC_MINIMAP_WINDOW_TEST)"

mac-minimap-window-tests: $(MAC_MINIMAP_WINDOW_TEST)
	"$(MAC_MINIMAP_WINDOW_TEST)"

$(MAC_TAB_STRIP_GEOMETRY_TEST): mac/tests/SPDFMacTabStripGeometryTests.mm mac/SPDFMacTabStripGeometry.mm mac/SPDFMacTabStripGeometry.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac mac/tests/SPDFMacTabStripGeometryTests.mm mac/SPDFMacTabStripGeometry.mm -framework Foundation -o "$(MAC_TAB_STRIP_GEOMETRY_TEST)"

mac-tab-strip-geometry-tests: $(MAC_TAB_STRIP_GEOMETRY_TEST)
	"$(MAC_TAB_STRIP_GEOMETRY_TEST)"

$(MAC_TAB_STRIP_INTERACTION_TEST): mac/tests/SPDFMacTabStripInteractionTests.mm mac/SPDFMacTabStripLayout.mm \
	mac/SPDFMacTabStripScrolling.mm mac/SPDFMacTabStripHover.mm mac/SPDFMacTabStripMenus.mm \
	mac/SPDFMacTabGroupPicker.mm mac/SPDFMacTabStripDrawing.mm mac/SPDFMacTabStripDrag.mm \
	mac/SPDFMacTabDragSignature.h mac/SPDFMacTabGroupLayout.mm mac/SPDFMacTabGroupInteraction.mm \
	mac/SPDFMacTabGroupNamePrompt.mm mac/SPDFMacTabGroups.mm mac/SPDFMacTabStripView.mm \
	mac/SPDFMacTabAccessibility.mm mac/SPDFMacTabStripView.h mac/SPDFMacTabStripGeometry.mm \
	mac/SPDFMacTabStripGeometry.h mac/SPDFMacTabStripStyle.mm mac/SPDFMacTabStripStyle.h \
	mac/SPDFMacWindowChrome.mm mac/SPDFMacWindowChrome.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacTabStripInteractionTests.mm mac/SPDFMacTabStripLayout.mm mac/SPDFMacTabStripScrolling.mm mac/SPDFMacTabStripHover.mm mac/SPDFMacTabStripMenus.mm mac/SPDFMacTabGroupPicker.mm mac/SPDFMacTabStripDrawing.mm mac/SPDFMacTabStripDrag.mm mac/SPDFMacTabGroupLayout.mm mac/SPDFMacTabGroupInteraction.mm mac/SPDFMacTabGroupNamePrompt.mm mac/SPDFMacTabGroups.mm mac/SPDFMacTabStripView.mm mac/SPDFMacTabAccessibility.mm mac/SPDFMacTabStripGeometry.mm mac/SPDFMacTabStripStyle.mm mac/SPDFMacWindowChrome.mm -framework Cocoa -o "$(MAC_TAB_STRIP_INTERACTION_TEST)"

mac-tab-strip-interaction-tests: $(MAC_TAB_STRIP_INTERACTION_TEST)
	"$(MAC_TAB_STRIP_INTERACTION_TEST)"

.PHONY: mac-tab-group-tests
mac-tab-group-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacTabGroupTests.mm mac/SPDFMacModels.mm mac/SPDFMacTabGroups.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -lm -o "$(BUILD)/SPDFMacTabGroupTests"
	"$(BUILD)/SPDFMacTabGroupTests"
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacTabGroupIntegrationTests.mm mac/SPDFMacModels.mm mac/SPDFMacTabGroups.mm mac/SPDFMacTabGroupIntegration.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -lm -o "$(BUILD)/SPDFMacTabGroupIntegrationTests"
	"$(BUILD)/SPDFMacTabGroupIntegrationTests"

.PHONY: mac-document-opening-tests
mac-document-opening-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-objc-protocol-method-implementation -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacDocumentOpeningTests.mm mac/SPDFMacDocumentOpening.mm mac/SPDFMacOpenRouting.mm mac/SPDFMacModels.mm mac/SPDFMacTabGroups.mm mac/SPDFMacTabGroupIntegration.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -lm -o "$(BUILD)/SPDFMacDocumentOpeningTests"
	"$(BUILD)/SPDFMacDocumentOpeningTests"

.PHONY: mac-tab-group-integration-tests mac-tab-group-interaction-tests
mac-tab-group-integration-tests: mac-tab-group-tests

mac-tab-group-interaction-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacTabGroupInteractionTests.mm mac/SPDFMacTabStripLayout.mm mac/SPDFMacTabStripScrolling.mm mac/SPDFMacTabStripHover.mm mac/SPDFMacTabStripMenus.mm mac/SPDFMacTabGroupPicker.mm mac/SPDFMacTabStripDrawing.mm mac/SPDFMacTabStripDrag.mm mac/SPDFMacTabGroupLayout.mm mac/SPDFMacTabGroupInteraction.mm mac/SPDFMacTabGroupNamePrompt.mm mac/SPDFMacTabGroups.mm mac/SPDFMacTabStripView.mm mac/SPDFMacTabAccessibility.mm mac/SPDFMacTabStripGeometry.mm mac/SPDFMacTabStripStyle.mm mac/SPDFMacWindowChrome.mm -framework Cocoa -o "$(BUILD)/SPDFMacTabGroupInteractionTests"
	"$(BUILD)/SPDFMacTabGroupInteractionTests"

.PHONY: mac-tab-hover-preview-tests
mac-tab-hover-preview-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacTabPreviewCacheTests.mm mac/SPDFMacTabPreviewCache.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -lm -o "$(BUILD)/SPDFMacTabPreviewCacheTests"
	"$(BUILD)/SPDFMacTabPreviewCacheTests"

.PHONY: mac-tab-gap-drop-tests
mac-tab-gap-drop-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacTabGapDropTests.mm mac/SPDFMacModels.mm mac/SPDFMacTabGroupIntegration.mm mac/SPDFMacTabStripLayout.mm mac/SPDFMacTabStripScrolling.mm mac/SPDFMacTabStripHover.mm mac/SPDFMacTabStripMenus.mm mac/SPDFMacTabGroupPicker.mm mac/SPDFMacTabStripDrawing.mm mac/SPDFMacTabStripDrag.mm mac/SPDFMacTabGroupLayout.mm mac/SPDFMacTabGroupInteraction.mm mac/SPDFMacTabGroupNamePrompt.mm mac/SPDFMacTabGroups.mm mac/SPDFMacTabStripView.mm mac/SPDFMacTabAccessibility.mm mac/SPDFMacTabStripGeometry.mm mac/SPDFMacTabStripStyle.mm mac/SPDFMacWindowChrome.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -lm -o "$(BUILD)/SPDFMacTabGapDropTests"
	"$(BUILD)/SPDFMacTabGapDropTests"

.PHONY: mac-agent-pdf-inspection-tests
mac-agent-pdf-inspection-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacAgentPDFInspectionTests.mm mac/SPDFMacAgentPDFInspection.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -framework CoreText -framework CoreGraphics -framework ImageIO -lm -o "$(BUILD)/SPDFMacAgentPDFInspectionTests"
	"$(BUILD)/SPDFMacAgentPDFInspectionTests"

# Focused reader-action and on-demand agent contracts; no app launch.
.PHONY: mac-reader-action-tests mac-agent-tests
mac-reader-action-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacContextPageTests.mm -framework Cocoa -o "$(BUILD)/SPDFMacContextPageTests"
	"$(BUILD)/SPDFMacContextPageTests"
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacMarkdownEditorTests.mm mac/SPDFMacMarkdownEditor.mm mac/SPDFMacMarkdownRouting.mm -framework Cocoa -framework UniformTypeIdentifiers -o "$(BUILD)/SPDFMacMarkdownEditorTests"
	"$(BUILD)/SPDFMacMarkdownEditorTests"

mac-agent-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacAgentCommandTests.mm mac/SPDFMacAgentValidation.mm -framework Cocoa -o "$(BUILD)/SPDFMacAgentCommandTests"
	"$(BUILD)/SPDFMacAgentCommandTests"
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacAgentNavigationTests.mm mac/SPDFMacAgentIntegration.mm mac/SPDFMacAgentValidation.mm -framework Cocoa -o "$(BUILD)/SPDFMacAgentNavigationTests"
	"$(BUILD)/SPDFMacAgentNavigationTests"
	python3 -m unittest discover -s tools/tests -v

# The per-tab fill/outline decision, plus the AppKit colours the roles resolve
# to under both Aqua and Dark Aqua. Links only the seam itself.
$(MAC_TAB_STRIP_STYLE_TEST): mac/tests/SPDFMacTabStripStyleTests.mm mac/SPDFMacTabStripStyle.mm mac/SPDFMacTabStripStyle.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacTabStripStyleTests.mm mac/SPDFMacTabStripStyle.mm -framework Cocoa -o "$(MAC_TAB_STRIP_STYLE_TEST)"

mac-tab-strip-style-tests: $(MAC_TAB_STRIP_STYLE_TEST)
	"$(MAC_TAB_STRIP_STYLE_TEST)"

# The reading-theme chrome seams: the gutter and page-border decisions on
# SPDFDocumentView, the single-segment toolbar pill, and the Translate
# enablement policy. Links the AppKit half only - no mupdf, and no markdown
# pipeline beyond the palette itself.
MAC_READING_THEME_CHROME_SRCS := mac/tests/SPDFMacReadingThemeChromeTests.mm mac/SPDFMacDocumentView.mm mac/SPDFMacEmptyDocumentView.mm \
	mac/SPDFMacPageRendering.mm mac/SPDFMacRenderedPage.mm mac/SPDFMacDelayedLinkActivation.mm \
	mac/SPDFMacDocumentViewTheme.mm mac/SPDFMacSupport.mm mac/SPDFMacToolbarSegments.mm mac/SPDFMacSelectionClick.mm mac/SPDFMacInactiveZoom.mm mac/SPDFMacUIHelpers.mm mac/SPDFMacPaneDividers.mm mac/SPDFMacPageWheel.mm \
	mac/SPDFMacCursorRegions.mm mac/SPDFMacWindowChrome.mm mac/SPDFMacTranslationPolicy.mm \
	mac/markdown/SPDFMarkdownTheme.mm

$(MAC_READING_THEME_CHROME_TEST): $(MAC_READING_THEME_CHROME_SRCS) mac/SPDFMacTranslationPolicy.h mac/markdown/SPDFMarkdownDecorations.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -Imac/markdown $(MAC_READING_THEME_CHROME_SRCS) -framework Cocoa -framework UniformTypeIdentifiers -o "$(MAC_READING_THEME_CHROME_TEST)"

mac-reading-theme-chrome-tests: $(MAC_READING_THEME_CHROME_TEST)
	"$(MAC_READING_THEME_CHROME_TEST)"

$(MAC_PALETTE_RESULTS_TEST): mac/tests/SPDFMacPaletteResultsTests.mm mac/SPDFMacPaletteResults.mm mac/SPDFMacPaletteResults.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac mac/tests/SPDFMacPaletteResultsTests.mm mac/SPDFMacPaletteResults.mm -framework Cocoa -o "$(MAC_PALETTE_RESULTS_TEST)"

mac-palette-results-tests: $(MAC_PALETTE_RESULTS_TEST)
	"$(MAC_PALETTE_RESULTS_TEST)"

# Cmd+K rows: titles, locations, merged copies, movement (pure), then what
# choosing a row does on a headless reader with the production open path.
MAC_PALETTE_NAME_SRCS := mac/SPDFMacPaletteDocumentNames.mm mac/SPDFMacCollectionPaletteModel.mm \
	mac/SPDFMacPaletteResults.mm
.PHONY: mac-palette-document-names-tests mac-palette-activation-tests
mac-palette-document-names-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore \
		mac/tests/SPDFMacPaletteDocumentNamesTests.mm $(MAC_PALETTE_NAME_SRCS) mac/SPDFMacSupport.mm \
		mac/SPDFMacToolbarSegments.mm -framework Cocoa -framework UniformTypeIdentifiers \
		-o "$(BUILD)/SPDFMacPaletteDocumentNamesTests"
	"$(BUILD)/SPDFMacPaletteDocumentNamesTests"

mac-palette-activation-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-objc-protocol-method-implementation \
		-Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacPaletteActivationTests.mm mac/SPDFMacPaletteActivation.mm \
		$(MAC_PALETTE_NAME_SRCS) mac/SPDFMacDocumentOpening.mm mac/SPDFMacOpenRouting.mm mac/SPDFMacModels.mm \
		mac/SPDFMacTabGroups.mm mac/SPDFMacTabGroupIntegration.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) \
		-framework Cocoa -lm -o "$(BUILD)/SPDFMacPaletteActivationTests"
	"$(BUILD)/SPDFMacPaletteActivationTests"

$(MAC_FIND_NEAREST_TEST): mac/tests/SPDFMacFindNearestTests.mm mac/SPDFMacFindNearest.mm mac/SPDFMacFindNearest.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac mac/tests/SPDFMacFindNearestTests.mm mac/SPDFMacFindNearest.mm -framework Cocoa -o "$(MAC_FIND_NEAREST_TEST)"

mac-find-nearest-tests: $(MAC_FIND_NEAREST_TEST)
	"$(MAC_FIND_NEAREST_TEST)"

$(MAC_UPDATER_TEST): mac/SPDFUpdaterTests.mm mac/SPDFUpdater.mm mac/SPDFUpdaterDownloadBounds.mm mac/SPDFUpdaterRelease.mm mac/SPDFMacFileExplorerPreference.mm mac/SPDFMacSupport.mm mac/SPDFMacToolbarSegments.mm mac/SPDFUpdater.h mac/SPDFUpdaterDownloadBounds.h mac/SPDFUpdaterRelease.h mac/SPDFMacFileExplorerPreference.h mac/SPDFMacSupport.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac mac/SPDFUpdaterTests.mm mac/SPDFUpdater.mm mac/SPDFUpdaterDownloadBounds.mm mac/SPDFUpdaterRelease.mm mac/SPDFMacFileExplorerPreference.mm mac/SPDFMacSupport.mm mac/SPDFMacToolbarSegments.mm -framework Cocoa -framework Security -framework UniformTypeIdentifiers -o "$(MAC_UPDATER_TEST)"

mac-updater-tests: $(MAC_UPDATER_TEST)
	"$(MAC_UPDATER_TEST)"

release-pipeline-tests:
	release/release-common-tests.sh
	release/release-workflow-tests.sh

print-release-config:
	@printf '%s\n' "$(MAC_TEAM_ID)|$(MAC_BUNDLE_ID)|$(MAC_ARCH)|$(MACOSX_DEPLOYMENT_TARGET)|$(PORTABLE_OPTFLAGS)"

mac-markdown-tests:
	mac/tests/markdown/run-tests.sh
	mac/tests/run-markdown-integration-tests.sh

# The runtime check links the core objects built here, in $(BUILD), so a scratch BUILD gets a clean build of its own.
linux-password-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	linux/gtk4/tests/password_source_test.sh
	linux/gtk4/tests/run_password_runtime_tests.sh "$(BUILD)" "$(MUPDF_BUILD)"

file-size-ratchet-tests:
	../tools/test-file-size-ratchet.sh
	../tools/check-file-sizes.sh --root ..

icon-tests:
	../gfx/verify-shenzhen-pdf-icons.sh

$(MAC_PROPERTIES_FORMAT_TEST): mac/tests/SPDFMacPropertiesFormatTests.mm mac/SPDFMacPropertiesFormat.mm mac/SPDFMacPropertiesFormat.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac mac/tests/SPDFMacPropertiesFormatTests.mm mac/SPDFMacPropertiesFormat.mm -framework Foundation -o "$(MAC_PROPERTIES_FORMAT_TEST)"

mac-properties-format-tests: $(MAC_PROPERTIES_FORMAT_TEST)
	"$(MAC_PROPERTIES_FORMAT_TEST)"

$(MAC_TRANSLATION_FILTER_TEST): mac/tests/SPDFTranslationChineseFilterTests.mm $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFTranslationChineseFilterTests.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Foundation -lm -o "$(MAC_TRANSLATION_FILTER_TEST)"

mac-translation-filter-tests: $(MAC_TRANSLATION_FILTER_TEST)
	"$(MAC_TRANSLATION_FILTER_TEST)"

$(MAC_TRANSLATION_COPY_TEST): mac/tests/SPDFTranslationCopyTests.mm $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFTranslationCopyTests.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Foundation -lm -o "$(MAC_TRANSLATION_COPY_TEST)"

mac-translation-copy-tests: $(MAC_TRANSLATION_COPY_TEST)
	"$(MAC_TRANSLATION_COPY_TEST)"

$(MAC_CURSOR_REGION_TEST): mac/tests/SPDFMacCursorRegionsTests.mm mac/SPDFMacCursorRegions.mm mac/SPDFMacCursorRegions.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac mac/tests/SPDFMacCursorRegionsTests.mm mac/SPDFMacCursorRegions.mm -framework Foundation -o "$(MAC_CURSOR_REGION_TEST)"

mac-cursor-region-tests: $(MAC_CURSOR_REGION_TEST)
	"$(MAC_CURSOR_REGION_TEST)"

$(MAC_TAB_LIFECYCLE_TEST): mac/tests/SPDFMacTabLifecycleTests.mm mac/SPDFMacTabLifecycle.mm mac/SPDFMacTabLifecycle.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacTabLifecycleTests.mm mac/SPDFMacTabLifecycle.mm -framework Foundation -o "$(MAC_TAB_LIFECYCLE_TEST)"

mac-tab-lifecycle-tests: $(MAC_TAB_LIFECYCLE_TEST)
	"$(MAC_TAB_LIFECYCLE_TEST)"

# It links the core and recolor objects, so it builds them: a fresh BUILD has neither.
$(MAC_TAB_STATE_TEST): mac/tests/SPDFMacTabStateTests.mm mac/SPDFMacTabGroups.mm mac/SPDFMacModels.mm \
	mac/SPDFMacModels.h $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacTabStateTests.mm mac/SPDFMacTabGroups.mm mac/SPDFMacModels.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -lm -o "$(MAC_TAB_STATE_TEST)"

mac-tab-state-tests: $(MAC_TAB_STATE_TEST)
	"$(MAC_TAB_STATE_TEST)"

$(MAC_SIDEBAR_OUTLINE_TEST): mac/tests/SPDFMacSidebarOutlineTests.mm mac/SPDFMacSidebarOutline.mm mac/SPDFMacSidebarOutline.h mac/SPDFMacSidebarModeControl.mm mac/SPDFMacSidebarNavigation.mm mac/SPDFMacSidebarModeControl.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacSidebarOutlineTests.mm mac/SPDFMacSidebarOutline.mm mac/SPDFMacSidebarModeControl.mm mac/SPDFMacSidebarNavigation.mm -framework Cocoa -o "$(MAC_SIDEBAR_OUTLINE_TEST)"

mac-sidebar-outline-tests: $(MAC_SIDEBAR_OUTLINE_TEST)
	"$(MAC_SIDEBAR_OUTLINE_TEST)"

$(MAC_PAGE_WHEEL_TEST): mac/tests/SPDFMacPageWheelTests.mm mac/SPDFMacPageWheel.mm mac/SPDFMacPageWheel.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacPageWheelTests.mm mac/SPDFMacPageWheel.mm -framework Cocoa -o "$(MAC_PAGE_WHEEL_TEST)"

mac-page-wheel-tests: $(MAC_PAGE_WHEEL_TEST)
	"$(MAC_PAGE_WHEEL_TEST)"

$(MAC_FILE_EXPLORER_TEST): mac/tests/SPDFMacFileExplorerPreferenceTests.mm mac/SPDFMacFileExplorerPreference.mm mac/SPDFMacFileExplorerPreference.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacFileExplorerPreferenceTests.mm mac/SPDFMacFileExplorerPreference.mm -framework Cocoa -o "$(MAC_FILE_EXPLORER_TEST)"

mac-file-explorer-tests: $(MAC_FILE_EXPLORER_TEST)
	"$(MAC_FILE_EXPLORER_TEST)"

$(MAC_SELECTION_CLICK_TEST): mac/tests/SPDFMacSelectionClickTests.mm mac/SPDFMacDocumentView.mm mac/SPDFMacEmptyDocumentView.mm mac/SPDFMacDocumentView.h mac/SPDFMacPageRendering.mm mac/SPDFMacPageRendering.h mac/SPDFMacSelectionClick.mm mac/SPDFMacSelectionClick.h mac/SPDFMacDelayedLinkActivation.mm mac/SPDFMacDelayedLinkActivation.h mac/SPDFMacCursorRegions.mm mac/SPDFMacCursorRegions.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacSelectionClickTests.mm mac/SPDFMacDocumentView.mm mac/SPDFMacEmptyDocumentView.mm mac/SPDFMacPageRendering.mm mac/SPDFMacSelectionClick.mm mac/SPDFMacDelayedLinkActivation.mm mac/SPDFMacCursorRegions.mm -framework Cocoa -o "$(MAC_SELECTION_CLICK_TEST)"

mac-selection-click-tests: $(MAC_SELECTION_CLICK_TEST)
	"$(MAC_SELECTION_CLICK_TEST)"

$(MAC_SELECTION_ADAPTER_TEST): mac/tests/SPDFMacSelectionAdapterTests.mm mac/SPDFMacSelectionAdapter.mm mac/SPDFMacSelectionAdapter.h mac/SPDFMacSelectionClick.h core/shenzhen_pdf_core.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore mac/tests/SPDFMacSelectionAdapterTests.mm mac/SPDFMacSelectionAdapter.mm -framework Cocoa -o "$(MAC_SELECTION_ADAPTER_TEST)"

mac-selection-adapter-tests: $(MAC_SELECTION_ADAPTER_TEST)
	"$(MAC_SELECTION_ADAPTER_TEST)"

$(MAC_LAUNCH_WORK_POLICY_TEST): mac/tests/launch/SPDFMacLaunchWorkPolicyTests.mm mac/SPDFMacInactivePreload.mm mac/SPDFMacInactivePreload.h mac/SPDFMacLaunchWorkPolicy.mm mac/SPDFMacLaunchWorkPolicy.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/launch/SPDFMacLaunchWorkPolicyTests.mm mac/SPDFMacInactivePreload.mm mac/SPDFMacLaunchWorkPolicy.mm -framework Cocoa -o "$(MAC_LAUNCH_WORK_POLICY_TEST)"

mac-launch-work-policy-tests: $(MAC_LAUNCH_WORK_POLICY_TEST)
	"$(MAC_LAUNCH_WORK_POLICY_TEST)"

$(MAC_STATE_YAML_TEST): mac/tests/SPDFStateYamlTests.mm $(YAML_OBJ) | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Icore mac/tests/SPDFStateYamlTests.mm "$(YAML_OBJ)" -framework Foundation -o "$(MAC_STATE_YAML_TEST)"

mac-state-yaml-tests: $(MAC_STATE_YAML_TEST)
	"$(MAC_STATE_YAML_TEST)"

# Last opened and last viewed (mac/SPDFMacDocumentActivity.h). The real-app check is mac/tests/activity-e2e.
$(MAC_DOCUMENT_ACTIVITY_TEST): mac/tests/SPDFMacDocumentActivityTests.mm mac/SPDFMacDocumentActivity.mm \
		mac/SPDFMacDocumentActivityValues.mm mac/SPDFMacDocumentActivity.h $(YAML_OBJ) | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore \
		mac/tests/SPDFMacDocumentActivityTests.mm mac/SPDFMacDocumentActivity.mm mac/SPDFMacDocumentActivityValues.mm \
		"$(YAML_OBJ)" -framework Foundation -framework CoreServices -o "$(MAC_DOCUMENT_ACTIVITY_TEST)"

mac-document-activity-tests: $(MAC_DOCUMENT_ACTIVITY_TEST)
	"$(MAC_DOCUMENT_ACTIVITY_TEST)"

$(MAC_APP_FLAGS_FILE): FORCE
	@mkdir -p "$(@D)"
	@printf '%s\n' '$(MAC_APP_COMPILE_FLAGS)' | cmp -s - "$@" || printf '%s\n' '$(MAC_APP_COMPILE_FLAGS)' > "$@"
.PHONY: FORCE
FORCE:

-include $(MAC_APP_OBJS:.o=.d)
$(MAC_APP_OBJ_DIR)/%.o: %.mm $(MAC_APP_FLAGS_FILE) Makefile
	@mkdir -p "$(@D)"
	clang++ $(MAC_APP_COMPILE_FLAGS) -MMD -MP -c "$<" -o "$@"

$(MAC_BIN): $(MAC_APP_OBJS) core/spdf_document_export.h $(MAC_COLLECTION_BIN) mupdf-libs $(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MAC_SRCS) $(MAC_HDRS) $(MAC_ICON_SRCS) $(MAC_COLLECTION_SRCS) mac/companion/main.mm mac/companion/sources.mk mac/Info.plist mac/CollectionCompanion-Info.plist mac/Assets.xcassets/Contents.json mac/Assets.xcassets/AppIcon.appiconset/Contents.json
	rm -rf "$(MAC_APP)"
	mkdir -p "$(MAC_APP)/Contents/MacOS" "$(MAC_APP)/Contents/Resources" "$(DIST)"
	cp "mac/Info.plist" "$(MAC_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(MAC_BUNDLE_ID)" "$(MAC_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(MAC_VERSION)" "$(MAC_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(MAC_BUILD)" "$(MAC_APP)/Contents/Info.plist"
	$(if $(MAC_RELEASE_TAG),/usr/libexec/PlistBuddy -c "Set :SZFReleaseTag $(MAC_RELEASE_TAG)" "$(MAC_APP)/Contents/Info.plist")
	rm -rf "$(BUILD)/ShenzhenPDF.iconset"
	mkdir -p "$(BUILD)/ShenzhenPDF.iconset"
	cp ../gfx/ShenzhenPDF-16x16x32.png "$(BUILD)/ShenzhenPDF.iconset/icon_16x16.png"
	cp ../gfx/ShenzhenPDF-32x32x32.png "$(BUILD)/ShenzhenPDF.iconset/icon_16x16@2x.png"
	cp ../gfx/ShenzhenPDF-32x32x32.png "$(BUILD)/ShenzhenPDF.iconset/icon_32x32.png"
	cp ../gfx/ShenzhenPDF-64x64x32.png "$(BUILD)/ShenzhenPDF.iconset/icon_32x32@2x.png"
	cp ../gfx/ShenzhenPDF-128x128x32.png "$(BUILD)/ShenzhenPDF.iconset/icon_128x128.png"
	cp ../gfx/ShenzhenPDF-256x256x32.png "$(BUILD)/ShenzhenPDF.iconset/icon_128x128@2x.png"
	cp ../gfx/ShenzhenPDF-256x256x32.png "$(BUILD)/ShenzhenPDF.iconset/icon_256x256.png"
	cp ../gfx/ShenzhenPDF-512x512x32.png "$(BUILD)/ShenzhenPDF.iconset/icon_256x256@2x.png"
	cp ../gfx/ShenzhenPDF-512x512x32.png "$(BUILD)/ShenzhenPDF.iconset/icon_512x512.png"
	cp ../gfx/ShenzhenPDF-1024x1024x32.png "$(BUILD)/ShenzhenPDF.iconset/icon_512x512@2x.png"
	rm -rf "$(BUILD)/Assets.xcassets"
	mkdir -p "$(BUILD)/Assets.xcassets/AppIcon.appiconset"
	cp mac/Assets.xcassets/Contents.json "$(BUILD)/Assets.xcassets/"
	cp mac/Assets.xcassets/AppIcon.appiconset/Contents.json "$(BUILD)/Assets.xcassets/AppIcon.appiconset/"
	cp "$(BUILD)/ShenzhenPDF.iconset"/*.png "$(BUILD)/Assets.xcassets/AppIcon.appiconset/"
	# actool leaves its ibtoold agent running for two minutes after it returns, holding every descriptor it inherited.
	# It gets neither make's output nor make's job slots (descriptors 3 to 9), or the build would wait for it.
	if xcrun --find actool >/dev/null 2>&1; then \
		( exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; xcrun actool "$(BUILD)/Assets.xcassets" --compile "$(MAC_APP)/Contents/Resources" --platform macosx --minimum-deployment-target "$(MACOSX_DEPLOYMENT_TARGET)" --app-icon AppIcon --output-partial-info-plist "$(BUILD)/actool-partial.plist" > "$(BUILD)/actool.log" 2>&1 ) || \
			{ cat "$(BUILD)/actool.log" >&2; exit 1; }; \
	else \
		echo "warning: actool not found; using .icns app icon fallback"; \
	fi
	iconutil -c icns "$(BUILD)/ShenzhenPDF.iconset" -o "$(MAC_APP)/Contents/Resources/AppIcon.icns"
	clang++ $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc \
		$(MAC_APP_OBJS) $(CORE_OBJS) "$(YAML_OBJ)" $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MAC_FRIENDS_LINK) \
		$(MUPDF_LIBS) -framework Cocoa -framework QuartzCore -framework PDFKit -framework \
		UniformTypeIdentifiers -framework CoreServices -framework Security -framework LocalAuthentication \
		-framework ImageIO $(MAC_FRIENDS_FRAMEWORKS) -lm -Wl,-dead_strip -Wl,-x -o "$(MAC_BIN)"
	@if otool -L "$(MAC_BIN)" | grep -Eq 'libcrypto|/opt/homebrew|/usr/local'; then \
		echo "unexpected mutable runtime dependency in $(MAC_BIN)" >&2; \
		otool -L "$(MAC_BIN)" >&2; \
		exit 1; \
	fi
	mkdir -p "$(MAC_COLLECTION_APP)/Contents/MacOS" "$(MAC_COLLECTION_APP)/Contents/Resources"
	cp "$(MAC_COLLECTION_BIN)" "$(MAC_COLLECTION_APP)/Contents/MacOS/ShenzhenPDFCollection"
	cp mac/CollectionCompanion-Info.plist "$(MAC_COLLECTION_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(MAC_BUNDLE_ID).collection" "$(MAC_COLLECTION_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(MAC_VERSION)" "$(MAC_COLLECTION_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(MAC_BUILD)" "$(MAC_COLLECTION_APP)/Contents/Info.plist"
	cp "$(MAC_APP)/Contents/Resources/AppIcon.icns" "$(MAC_COLLECTION_APP)/Contents/Resources/AppIcon.icns"
	$(MAC_FRIENDS_EMBED)
	$(MAC_PYTHON_SANDBOX_EMBED)
	xattr -cr "$(MAC_APP)"
	$(subst $(MAC_APP),$(MAC_COLLECTION_APP),$(MAC_CODESIGN_APP))
	$(subst $(MAC_APP),$(MAC_FRIENDS_HELPER_APP),$(MAC_CODESIGN_APP))
	$(subst $(MAC_APP),$(MAC_PYTHON_SANDBOX_HELPER),$(MAC_CODESIGN_APP))
	$(MAC_CODESIGN_APP)
	$(MAC_FRIENDS_BUNDLE_CHECK)
	$(MAC_PYTHON_SANDBOX_CHECK)

dmg: mac-app
	mac/make-installer-dmg.sh "$(MAC_APP)" "$(MAC_DMG)" "Shenzhen PDF"
	$(MAC_CODESIGN_DMG)

notarize: dmg
	@if [ "$(MAC_SIGN_IDENTITY)" = "-" ]; then \
		echo "MAC_SIGN_IDENTITY must be a Developer ID Application certificate for public macOS releases." >&2; \
		exit 2; \
	fi
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "NOTARY_PROFILE must name an xcrun notarytool keychain profile." >&2; \
		echo "Create one with: xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team> --password <app-password>" >&2; \
		exit 2; \
	fi
	release/notarize-mac-dmg.sh "$(MAC_DMG)" "$(NOTARY_PROFILE)" "$(NOTARY_RESULT)"

staple: notarize
	xcrun stapler staple "$(MAC_DMG)"
	xcrun stapler validate "$(MAC_DMG)"

verify-mac-release: staple
	release/verify-mac-artifact.sh --dmg "$(MAC_DMG)" --version "$(MAC_VERSION)" --build "$(MAC_BUILD)" --bundle-id "$(MAC_BUNDLE_ID)" --team-id "$(MAC_TEAM_ID)" --min-os "$(MACOSX_DEPLOYMENT_TARGET)"

release-dmg:
	@test "$(SPDF_RELEASE_MODE)" = "1" || (echo "release-dmg must be invoked through build-mac-release.sh" >&2; exit 2)
	$(MAKE) release-dmg-artifact

ifeq ($(SPDF_RELEASE_MODE),1)
release-dmg-artifact: verify-mac-release
else
release-dmg-artifact:
	@echo "release-dmg-artifact requires SPDF_RELEASE_MODE=1" >&2
	@exit 2
endif

verify-mac-unsigned: dmg
	release/verify-mac-artifact.sh --unsigned --dmg "$(MAC_DMG)" --version "$(MAC_VERSION)" --build "$(MAC_BUILD)" --bundle-id "$(MAC_BUNDLE_ID)" --min-os "$(MACOSX_DEPLOYMENT_TARGET)"

# Every compiled binary the *-tests targets execute. A release sweep builds
# this first with -j, then runs the suites sequentially, so the compiling is
# spread over all cores while the test log stays in a deterministic order.
# Running the *-tests targets themselves under -j would interleave their
# output: the make shipped with macOS is 3.81, which has no --output-sync.
TEST_BINARIES := $(CORE_OUTLINE_TEST) $(CORE_PASSWORD_TEST) $(CORE_RECOLOR_TEST) \
	$(CORE_RENDER_THEME_TEST) $(CORE_SELECTION_TEST) $(CORE_CJK_SELECTION_TEST) \
	$(MAC_WINDOW_SHORTCUT_TEST) $(MAC_WINDOW_CHROME_TEST) $(MAC_PASSWORD_TEST) \
	$(MAC_MINIMAP_WINDOW_TEST) $(MAC_TAB_STRIP_GEOMETRY_TEST) \
	$(MAC_TAB_STRIP_INTERACTION_TEST) $(MAC_TAB_STRIP_STYLE_TEST) \
	$(MAC_READING_THEME_CHROME_TEST) \
	$(MAC_PALETTE_RESULTS_TEST) $(MAC_FIND_NEAREST_TEST) $(MAC_UPDATER_TEST) \
	$(MAC_PROPERTIES_FORMAT_TEST) $(MAC_TRANSLATION_FILTER_TEST) \
	$(MAC_TRANSLATION_COPY_TEST) $(MAC_CURSOR_REGION_TEST) \
	$(MAC_TAB_LIFECYCLE_TEST) $(MAC_FILE_EXPLORER_TEST) \
	$(MAC_SELECTION_CLICK_TEST) $(MAC_SELECTION_ADAPTER_TEST) \
	$(MAC_LAUNCH_WORK_POLICY_TEST) $(MAC_STATE_YAML_TEST) $(MAC_DOCUMENT_ACTIVITY_TEST)
# The GTK test binaries are appended further down, once their sources are
# globbed; the test-binaries rule itself lives at the end of this file so its
# prerequisite list is expanded after that.

$(MAC_RELEASE_NOTES_PREVIEW): release/SPDFReleaseNotesPreview.mm mac/SPDFUpdaterRelease.mm mac/SPDFUpdater.h mac/SPDFUpdaterRelease.h | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac release/SPDFReleaseNotesPreview.mm mac/SPDFUpdaterRelease.mm -framework Cocoa -o "$(MAC_RELEASE_NOTES_PREVIEW)"

release-notes-preview: $(MAC_RELEASE_NOTES_PREVIEW)
	@test -n "$(NOTES_FILE)" || (echo "NOTES_FILE is required" >&2; exit 2)
	"$(MAC_RELEASE_NOTES_PREVIEW)" "$(NOTES_FILE)" "$(MAC_VERSION)-$(MAC_BUILD)"

print-mac-signing-identities:
	@security find-identity -v -p codesigning | grep "Developer ID Application" || true

install: mac-app
	rm -rf "/Applications/ShenzhenPDF.app"
	ditto "$(MAC_APP)" "/Applications/ShenzhenPDF.app"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/ShenzhenPDF.app"

LINUX_GTK4_SRCS := $(sort $(wildcard linux/gtk4/*.c))

linux-gtk4: mupdf-libs | $(BUILD)
	$(CC) $(PORTABLE_OPTFLAGS) -Wall -Icore -Ilinux/gtk4 -I$(MUPDF_DIR)/include $$(pkg-config --cflags gtk4 libadwaita-1) "$(CORE_SRC)" "$(CORE_SELECTION_SRC)" "$(CORE_SELECTION_SUPPORT_SRC)" "$(CORE_RECOLOR_SRC)" "$(YAML_SRC)" $(LINUX_GTK4_SRCS) $(MUPDF_LIBS) $$(pkg-config --libs gtk4 libadwaita-1 openssl) -lm -o "$(BUILD)/ShenzhenPDF-gtk4"

LINUX_GTK4_TEST_SRCS := $(sort $(wildcard linux/gtk4/tests/*_test.c))
LINUX_GTK4_TEST_BINS := $(patsubst linux/gtk4/tests/%.c,$(BUILD)/%,$(LINUX_GTK4_TEST_SRCS))
# The recipe these replaced rebuilt every binary on every invocation, so the
# prerequisite net is deliberately wide: any core/ or linux/gtk4/ header moving
# rebuilds all 26. Correctness first; they are ~0.4s each and now build in
# parallel under `make -j test-binaries`.
LINUX_GTK4_TEST_DEPS := $(YAML_SRC) $(sort $(wildcard core/*.h) $(wildcard linux/gtk4/*.h)) Makefile

$(LINUX_GTK4_TEST_BINS): $(BUILD)/%: linux/gtk4/tests/%.c $(LINUX_GTK4_TEST_DEPS) | $(BUILD)
	$(CC) $(PORTABLE_TEST_OPTFLAGS) -Wall -Icore -Ilinux/gtk4 $$(pkg-config --cflags glib-2.0 openssl) $< "$(YAML_SRC)" $$(pkg-config --libs glib-2.0 openssl) -lm -o "$@"

TEST_BINARIES += $(LINUX_GTK4_TEST_BINS)

linux-gtk4-tests: $(LINUX_GTK4_TEST_BINS)
	@set -e; for bin in $(LINUX_GTK4_TEST_BINS); do "$$bin"; done

# Deliberately not named *-tests: spdf_discover_test_targets() scans this file
# for that suffix, and this target runs nothing.
test-binaries: $(TEST_BINARIES)

clean:
	rm -rf "$(BUILD)" "$(MAC_APP)" "$(MAC_DMG)"

MAC_COLLECTION_PARSER_SRCS := mac/markdown/SPDFMarkdownParser.mm mac/markdown/SPDFMarkdownModel.mm mac/markdown/SPDFMarkdownHTML.mm mac/markdown/SPDFMarkdownHTMLBlocks.mm mac/markdown/SPDFMarkdownResources.mm
MAC_COLLECTION_PARSER_LIBS := $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS)
.PHONY: mac-collection-store-tests mac-collection-asset-tests mac-collection-compare-tests mac-previous-tab-tests mac-viewport-checkpoint-tests
mac-collection-store-tests: $(MAC_COLLECTION_PARSER_LIBS) | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation -Imac mac/tests/SPDFMacCollectionStoreTests.mm mac/SPDFMacCollectionStore*.mm mac/SPDFMacSearchFileCache.mm $(MAC_COLLECTION_PARSER_SRCS) $(MAC_COLLECTION_PARSER_LIBS) -framework Cocoa -framework PDFKit -framework ImageIO -o "$(BUILD)/SPDFMacCollectionStoreTests"
	"$(BUILD)/SPDFMacCollectionStoreTests"
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation -Imac mac/tests/SPDFMacCollectionIntegrityTests.mm mac/SPDFMacReadOnlyCopy.mm mac/SPDFMacCollectionStore*.mm mac/SPDFMacSearchFileCache.mm $(MAC_COLLECTION_PARSER_SRCS) $(MAC_COLLECTION_PARSER_LIBS) -framework Cocoa -framework PDFKit -framework ImageIO -o "$(BUILD)/SPDFMacCollectionIntegrityTests"
	"$(BUILD)/SPDFMacCollectionIntegrityTests"
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation -Imac mac/tests/SPDFMacCollectionCleanupTests.mm mac/SPDFMacCollectionStore*.mm mac/SPDFMacSearchFileCache.mm $(MAC_COLLECTION_PARSER_SRCS) $(MAC_COLLECTION_PARSER_LIBS) -framework Cocoa -framework PDFKit -framework ImageIO -o "$(BUILD)/SPDFMacCollectionCleanupTests"
	"$(BUILD)/SPDFMacCollectionCleanupTests"

.PHONY: mac-collection-search-tests
mac-collection-search-tests: $(MAC_COLLECTION_PARSER_LIBS) | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation -Imac mac/tests/SPDFMacCollectionContextSearchTests.mm mac/SPDFMacCollectionStore*.mm mac/SPDFMacSearchFileCache.mm $(MAC_COLLECTION_PARSER_SRCS) $(MAC_COLLECTION_PARSER_LIBS) -framework Cocoa -framework CoreText -framework PDFKit -framework ImageIO -o "$(BUILD)/SPDFMacCollectionContextSearchTests"
	"$(BUILD)/SPDFMacCollectionContextSearchTests"

mac-collection-asset-tests: $(MAC_COLLECTION_PARSER_LIBS) | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation -Imac mac/tests/SPDFMacCollectionAssetTests.mm mac/SPDFMacCollectionStore*.mm mac/SPDFMacSearchFileCache.mm $(MAC_COLLECTION_PARSER_SRCS) $(MAC_COLLECTION_PARSER_LIBS) -framework Cocoa -framework PDFKit -framework ImageIO -o "$(BUILD)/SPDFMacCollectionAssetTests"
	"$(BUILD)/SPDFMacCollectionAssetTests"

mac-collection-compare-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacCollectionCompareTests.mm mac/SPDFMacCollectionCompareEngine.mm -framework Cocoa -framework PDFKit -o "$(BUILD)/SPDFMacCollectionCompareTests"
	"$(BUILD)/SPDFMacCollectionCompareTests"

mac-previous-tab-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacPreviousTabTests.mm mac/SPDFMacPreviousTab.mm mac/SPDFMacModels.mm mac/SPDFMacTabGroups.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -lm -o "$(BUILD)/SPDFMacPreviousTabTests"
	"$(BUILD)/SPDFMacPreviousTabTests"

mac-viewport-checkpoint-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacViewportCheckpointTests.mm mac/SPDFMacViewportCheckpoint.mm -framework Cocoa -o "$(BUILD)/SPDFMacViewportCheckpointTests"
	"$(BUILD)/SPDFMacViewportCheckpointTests"

.PHONY: mac-search-file-cache-tests
mac-search-file-cache-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -DSPDF_SEARCH_CACHE_TESTING=1 -Imac mac/tests/SPDFMacSearchFileCacheTests.mm mac/tests/SPDFMacSearchFileCachePeer.mm mac/SPDFMacSearchFileCache.mm -framework Foundation -o "$(BUILD)/SPDFMacSearchFileCacheTests"
	"$(BUILD)/SPDFMacSearchFileCacheTests"

.PHONY: mac-collection-palette-tests
mac-collection-palette-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac \
		mac/tests/SPDFMacCollectionPaletteTests.mm mac/SPDFMacCollectionPaletteModel.mm \
		mac/SPDFMacPaletteDocumentNames.mm mac/SPDFMacSearchFileCache.mm -framework Cocoa \
		-o "$(BUILD)/SPDFMacCollectionPaletteTests"
	"$(BUILD)/SPDFMacCollectionPaletteTests"

.PHONY: mac-collection-reader-navigation-tests
mac-collection-reader-navigation-tests: $(MAC_COLLECTION_PARSER_LIBS) | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacCollectionReaderNavigationTests.mm mac/SPDFMacCollectionReaderNavigation.mm mac/SPDFMacGroupActionButton.mm mac/SPDFMacCollectionEditableIntegration.mm mac/SPDFMacTabGroups.mm mac/SPDFMacCollectionStyle.mm mac/SPDFMacCollectionStore*.mm mac/SPDFMacSearchFileCache.mm $(MAC_COLLECTION_PARSER_SRCS) $(MAC_COLLECTION_PARSER_LIBS) -framework Cocoa -framework PDFKit -framework ImageIO -o "$(BUILD)/SPDFMacCollectionReaderNavigationTests"
	"$(BUILD)/SPDFMacCollectionReaderNavigationTests"

.PHONY: mac-collection-companion-tests
mac-collection-companion-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacCollectionCompanionTests.mm mac/SPDFMacCollectionPipe.mm -framework Foundation -o "$(BUILD)/SPDFMacCollectionCompanionTests"
	"$(BUILD)/SPDFMacCollectionCompanionTests"

.PHONY: mac-collection-credentials-tests
mac-collection-credentials-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacCollectionCredentialsTests.mm mac/SPDFMacCollectionCredentials.mm mac/SPDFMacPassword.mm mac/SPDFMacPasswordCredentials.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -framework Security -framework LocalAuthentication -lm -o "$(BUILD)/SPDFMacCollectionCredentialsTests"
	"$(BUILD)/SPDFMacCollectionCredentialsTests"

.PHONY: mac-collection-password-open-tests
mac-collection-password-open-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(MAC_COLLECTION_PARSER_LIBS) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacCollectionPasswordOpenTests.mm mac/SPDFMacCollectionCredentials.mm mac/SPDFMacCollectionCredentialIntegration.mm mac/SPDFMacPassword.mm mac/SPDFMacPasswordCredentials.mm mac/SPDFMacCollectionStore*.mm mac/SPDFMacSearchFileCache.mm $(MAC_COLLECTION_PARSER_SRCS) $(MAC_COLLECTION_PARSER_LIBS) "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -framework PDFKit -framework ImageIO -framework Security -framework LocalAuthentication -lm -o "$(BUILD)/SPDFMacCollectionPasswordOpenTests"
	"$(BUILD)/SPDFMacCollectionPasswordOpenTests"

.PHONY: mac-agent-group-tests
mac-agent-group-tests: $(YAML_OBJ) $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacAgentGroupTests.mm mac/SPDFMacAgentSavedSession.mm "$(YAML_OBJ)" mac/SPDFMacAgentGroups.mm mac/SPDFMacAgentValidation.mm mac/SPDFMacModels.mm mac/SPDFMacTabGroups.mm mac/SPDFMacTabGroupIntegration.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -lm -o "$(BUILD)/SPDFMacAgentGroupTests"
	"$(BUILD)/SPDFMacAgentGroupTests"

.PHONY: mac-panel-search-rendering-tests
mac-panel-search-rendering-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacPanelSearchRenderingTests.mm mac/SPDFMacPanelSearchField.mm -framework Cocoa -framework QuartzCore -o "$(BUILD)/SPDFMacPanelSearchRenderingTests"
	"$(BUILD)/SPDFMacPanelSearchRenderingTests"

.PHONY: mac-icon-rendering-tests
mac-icon-rendering-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore mac/tests/SPDFMacIconRenderingTests.mm mac/SPDFMacGroupActionButton.mm mac/SPDFMacSidebarModeControl.mm mac/SPDFMacSidebarNavigation.mm mac/SPDFMacSupport.mm mac/SPDFMacToolbarSegments.mm -framework Cocoa -framework QuartzCore -framework UniformTypeIdentifiers -o "$(BUILD)/SPDFMacIconRenderingTests"
	"$(BUILD)/SPDFMacIconRenderingTests"

.PHONY: mac-sidebar-navigation-tests
mac-sidebar-navigation-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacSidebarNavigationTests.mm mac/SPDFMacSidebarModeControl.mm mac/SPDFMacSidebarNavigation.mm -framework Cocoa -o "$(BUILD)/SPDFMacSidebarNavigationTests"
	"$(BUILD)/SPDFMacSidebarNavigationTests"

.PHONY: mac-group-management-tests
mac-group-management-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacGroupManagementTests.mm mac/SPDFMacGroupManagement.mm mac/SPDFMacGroupActionButton.mm mac/SPDFMacPanelSearchField.mm mac/SPDFMacGroupManagementTable.mm mac/SPDFMacTabGroupNamePrompt.mm mac/SPDFMacSidebarModeControl.mm mac/SPDFMacSidebarNavigation.mm mac/SPDFMacTabGroups.mm -framework Cocoa -o "$(BUILD)/SPDFMacGroupManagementTests"
	"$(BUILD)/SPDFMacGroupManagementTests"

.PHONY: mac-sidebar-workspace-tests
mac-sidebar-workspace-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(YAML_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacSidebarWorkspaceTests.mm mac/SPDFMacSidebarWorkspace.mm mac/SPDFMacGroupManagement.mm mac/SPDFMacGroupActionButton.mm mac/SPDFMacPanelSearchField.mm mac/SPDFMacGroupManagementTable.mm mac/SPDFMacTabGroupNamePrompt.mm mac/SPDFMacSidebarModeControl.mm mac/SPDFMacSidebarNavigation.mm mac/SPDFMacModels.mm mac/SPDFMacTabGroups.mm mac/SPDFMacTabGroupIntegration.mm "$(YAML_OBJ)" "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -lm -o "$(BUILD)/SPDFMacSidebarWorkspaceTests"
	"$(BUILD)/SPDFMacSidebarWorkspaceTests"

.PHONY: mac-tab-group-performance
.PHONY: mac-collection-thumbnail-delivery-tests
mac-collection-thumbnail-delivery-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacCollectionThumbnailDeliveryTests.mm -framework Cocoa -o "$(BUILD)/SPDFMacCollectionThumbnailDeliveryTests"
	"$(BUILD)/SPDFMacCollectionThumbnailDeliveryTests"

mac-tab-group-performance: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -O2 -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacTabGroupPerformance.mm mac/SPDFMacTabGroups.mm -framework Cocoa -o "$(BUILD)/SPDFMacTabGroupPerformance"
	"$(BUILD)/SPDFMacTabGroupPerformance" --verify

# The companion's sources are reader sources compiled with the same flags, so it links the reader's objects.
MAC_COLLECTION_OBJS = $(patsubst %.mm,$(MAC_APP_OBJ_DIR)/%.o,mac/companion/main.mm $(MAC_COLLECTION_SRCS))
-include $(MAC_APP_OBJ_DIR)/mac/companion/main.d
$(MAC_COLLECTION_BIN): $(MAC_COLLECTION_OBJS) mac/companion/sources.mk $(YAML_OBJ) $(CORE_RECOLOR_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) | $(BUILD)
	clang++ $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(MAC_COLLECTION_OBJS) "$(YAML_OBJ)" $(CORE_RECOLOR_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MAC_COLLECTION_FRAMEWORKS) -Wl,-dead_strip -Wl,-x -o "$(MAC_COLLECTION_BIN)"

.PHONY: mac-collection-companion-link-tests
mac-collection-companion-link-tests: $(MAC_COLLECTION_SRCS) $(YAML_OBJ) $(CORE_RECOLOR_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) | $(BUILD)
	clang++ $(PORTABLE_TEST_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacCollectionCompanionLinkTests.mm $(MAC_COLLECTION_SRCS) "$(YAML_OBJ)" $(CORE_RECOLOR_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MAC_COLLECTION_FRAMEWORKS) -Wl,-dead_strip -Wl,-x -o "$(BUILD)/SPDFMacCollectionCompanionLinkTests"
	"$(BUILD)/SPDFMacCollectionCompanionLinkTests"

.PHONY: mac-workspace-panel-tests
mac-workspace-panel-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacWorkspacePanelTests.mm mac/SPDFMacWorkspacePanels.mm -framework Cocoa -o "$(BUILD)/SPDFMacWorkspacePanelTests"
	"$(BUILD)/SPDFMacWorkspacePanelTests"

.PHONY: mac-sidebar-presentation-tests
mac-sidebar-presentation-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacSidebarPresentationTests.mm mac/SPDFMacSidebarPresentation.mm mac/SPDFMacCollectionStyle.mm -framework Cocoa -o "$(BUILD)/SPDFMacSidebarPresentationTests"
	"$(BUILD)/SPDFMacSidebarPresentationTests"

.PHONY: mac-document-format-tests
mac-document-format-tests: mupdf-libs $(CORE_OBJ) $(CORE_RECOLOR_OBJ)
	@mkdir -p "$(BUILD)"
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacDocumentFormatsTests.mm mac/SPDFMacSupport.mm mac/SPDFMacToolbarSegments.mm "$(CORE_OBJ)" "$(CORE_RECOLOR_OBJ)" $(MUPDF_LIBS) -framework Cocoa -framework UniformTypeIdentifiers -framework PDFKit -framework ImageIO -lm -o "$(BUILD)/SPDFMacDocumentFormatsTests"
	@fixture_dir=$$(mktemp -d); trap 'rm -rf "$$fixture_dir"' EXIT; \
	python3 mac/tests/make-format-fixtures.py "$$fixture_dir" && "$(BUILD)/SPDFMacDocumentFormatsTests" "$$fixture_dir" "$(abspath ..)"

.PHONY: mac-find-interaction-tests
mac-find-interaction-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacFindInteractionTests.mm mac/SPDFMacFindInteraction.mm mac/SPDFMacSidebarModeControl.mm mac/SPDFMacSidebarNavigation.mm -framework Cocoa -o "$(BUILD)/SPDFMacFindInteractionTests"
	"$(BUILD)/SPDFMacFindInteractionTests"

.PHONY: mac-find-context-tests
mac-find-context-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore mac/tests/SPDFMacFindContextTests.mm mac/SPDFMacFindContext.mm -framework Cocoa -o "$(BUILD)/SPDFMacFindContextTests"
	"$(BUILD)/SPDFMacFindContextTests"

.PHONY: mac-image-properties-tests
mac-image-properties-tests: $(BUILD)/SPDFMacImagePropertiesTests
	"$<"

$(BUILD)/SPDFMacImagePropertiesTests: mac/tests/SPDFMacImagePropertiesTests.mm mac/SPDFMacImageProperties.mm mac/SPDFMacImageProperties.h $(CORE_IMAGE_PROPERTIES_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore mac/tests/SPDFMacImagePropertiesTests.mm mac/SPDFMacImageProperties.mm $(CORE_IMAGE_PROPERTIES_OBJ) $(MUPDF_LIBS) -framework Foundation -framework ImageIO -framework CoreGraphics -lm -o "$@"

.PHONY: mac-properties-model-tests
mac-properties-model-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(CORE_IMAGE_PROPERTIES_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacPropertiesModelTests.mm mac/SPDFMacPropertiesModel.mm mac/SPDFMacPropertiesPanel.mm mac/SPDFMacPropertiesFormat.mm mac/SPDFMacImageProperties.mm mac/SPDFMacPassword.mm mac/SPDFMacPasswordCredentials.mm $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(CORE_IMAGE_PROPERTIES_OBJ) $(MUPDF_LIBS) -framework Cocoa -framework ImageIO -lm -o "$(BUILD)/SPDFMacPropertiesModelTests"
	"$(BUILD)/SPDFMacPropertiesModelTests" "$(abspath ..)"

.PHONY: mac-group-name-prompt-tests
mac-group-name-prompt-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacGroupNamePromptTests.mm mac/SPDFMacTabGroupNamePrompt.mm -framework Cocoa -o "$(BUILD)/SPDFMacGroupNamePromptTests"
	"$(BUILD)/SPDFMacGroupNamePromptTests"

.PHONY: mac-document-tool-input-tests
mac-document-tool-input-tests: core/spdf_document_export.h mupdf-libs $(CORE_OBJ) $(CORE_RECOLOR_OBJ) | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacDocumentToolInputTests.mm mac/SPDFMacDocumentToolInput.mm mac/SPDFMacTranslationPolicy.mm $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(MUPDF_LIBS) -framework Cocoa -framework ImageIO -framework PDFKit -lm -o "$(BUILD)/SPDFMacDocumentToolInputTests"
	@fixture_dir=$$(mktemp -d); trap 'rm -rf "$$fixture_dir"' EXIT; \
	python3 mac/tests/make-format-fixtures.py "$$fixture_dir" && "$(BUILD)/SPDFMacDocumentToolInputTests" "$$fixture_dir" "$(abspath ..)"

.PHONY: mac-shortcut-help-tests
mac-shortcut-help-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-incomplete-implementation -Wno-protocol -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacShortcutHelpTests.mm mac/ShenzhenMacDelegate+ShortcutHelp.mm mac/SPDFMacShortcutHelpStyle.mm mac/SPDFKeycapLabel.mm -framework Cocoa -o "$(BUILD)/SPDFMacShortcutHelpTests"
	"$(BUILD)/SPDFMacShortcutHelpTests"

.PHONY: mac-image-save-tests
mac-image-save-tests: core/spdf_document_export.h mupdf-libs $(CORE_OBJ) $(CORE_RECOLOR_OBJ) | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacImageSaveTests.mm mac/SPDFMacImageSave.mm $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(MUPDF_LIBS) -framework Cocoa -framework ImageIO -framework PDFKit -lm -o "$(BUILD)/SPDFMacImageSaveTests"
	"$(BUILD)/SPDFMacImageSaveTests" "$(abspath ..)"

.PHONY: mac-clipboard-image-tests
mac-clipboard-image-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacClipboardImageTests.mm mac/SPDFMacClipboardImage.mm -framework Cocoa -framework ImageIO -o "$(BUILD)/SPDFMacClipboardImageTests"
	"$(BUILD)/SPDFMacClipboardImageTests"

.PHONY: mac-clipboard-routing-tests
mac-clipboard-routing-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-incomplete-implementation -Wno-protocol -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacClipboardRoutingTests.mm mac/SPDFMacClipboardIntegration.mm mac/SPDFMacClipboardImage.mm -framework Cocoa -framework ImageIO -o "$(BUILD)/SPDFMacClipboardRoutingTests"
	"$(BUILD)/SPDFMacClipboardRoutingTests"

.PHONY: mac-pasted-image-state-tests
mac-pasted-image-state-tests: mupdf-libs $(CORE_OBJ) $(CORE_RECOLOR_OBJ) | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-incomplete-implementation -Wno-protocol -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacPastedImageStateTests.mm mac/SPDFMacImageSaveIntegration.mm mac/SPDFMacImageSave.mm mac/SPDFMacDocumentToolInput.mm mac/SPDFMacModels.mm mac/SPDFMacTabGroups.mm $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(MUPDF_LIBS) -framework Cocoa -framework UniformTypeIdentifiers -lm -o "$(BUILD)/SPDFMacPastedImageStateTests"
	"$(BUILD)/SPDFMacPastedImageStateTests"

.PHONY: mac-unsaved-image-close-tests
mac-unsaved-image-close-tests: mupdf-libs $(CORE_OBJ) $(CORE_RECOLOR_OBJ) | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-incomplete-implementation -Wno-protocol -Wno-objc-protocol-method-implementation -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacUnsavedImageCloseTests.mm mac/SPDFMacUnsavedImageClose.mm mac/SPDFMacTabGroupIntegration.mm mac/SPDFMacModels.mm mac/SPDFMacTabGroups.mm $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(MUPDF_LIBS) -framework Cocoa -lm -o "$(BUILD)/SPDFMacUnsavedImageCloseTests"
	"$(BUILD)/SPDFMacUnsavedImageCloseTests"

.PHONY: mac-page-pdf-copy-tests
mac-page-pdf-copy-tests: core/spdf_document_export.h mupdf-libs $(CORE_OBJ) $(CORE_RECOLOR_OBJ) | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacPagePDFCopyTests.mm mac/SPDFMacPagePDFCopy.mm $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(MUPDF_LIBS) -framework Cocoa -framework ImageIO -framework PDFKit -lm -o "$(BUILD)/SPDFMacPagePDFCopyTests"
	"$(BUILD)/SPDFMacPagePDFCopyTests" "$(abspath ..)"

.PHONY: mac-collection-refresh-host-tests
mac-collection-refresh-host-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-incomplete-implementation -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacCollectionRefreshHostTests.mm mac/SPDFMacCollectionCompanionHost.mm mac/SPDFMacCollectionPipe.mm -framework Cocoa -o "$(BUILD)/SPDFMacCollectionRefreshHostTests"
	"$(BUILD)/SPDFMacCollectionRefreshHostTests"

.PHONY: mac-image-rotation-tests
mac-image-rotation-tests: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacImageRotationTests.mm mac/SPDFMacImageRotation.mm mac/SPDFMacImageRotationPixels.mm mac/SPDFMacImageSave.mm $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(MUPDF_LIBS) -framework Cocoa -framework ImageIO -lm -o "$(BUILD)/SPDFMacImageRotationTests"
	"$(BUILD)/SPDFMacImageRotationTests"

.PHONY: mac-image-rotation-integration-tests
mac-image-rotation-integration-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-incomplete-implementation -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacImageRotationIntegrationTests.mm mac/SPDFMacImageRotationIntegration.mm -framework Cocoa -o "$(BUILD)/SPDFMacImageRotationIntegrationTests"
	"$(BUILD)/SPDFMacImageRotationIntegrationTests"

.PHONY: mac-document-rename-tests
mac-document-rename-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacDocumentRenameTests.mm -framework Foundation -o "$(BUILD)/SPDFMacDocumentRenameTests"
	"$(BUILD)/SPDFMacDocumentRenameTests"

.PHONY: mac-ai-transport-tests mac-ai-chat-tests mac-ai-tool-seam-tests mac-unified-settings-tests
# The chat session and the tool seam it runs on (mac/SPDFMacAIToolProvider.h).
MAC_AI_SESSION_SRCS := mac/SPDFMacAIChatSession.mm mac/SPDFMacAIAnswerCard.mm mac/SPDFMacAIChatVision.mm \
	mac/SPDFMacAIChatStore.mm mac/SPDFMacAIChatStoreRequestOnly.mm \
	mac/SPDFMacAITransport.mm mac/SPDFMacAICitations.mm mac/SPDFMacAIToolRegistry.mm \
	mac/SPDFMacAIRequestContext.mm mac/SPDFMacAIChatActivity.mm mac/SPDFMacAIChatSessionSummaries.mm \
	mac/SPDFMacAIChatBudget.mm mac/SPDFMacAIChatSessionCalls.mm mac/SPDFMacAIToolArguments.mm \
	mac/SPDFMacAIChatSessionRecovery.mm mac/SPDFMacAIChatProgress.mm
mac-ai-transport-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacAITransportTests.mm mac/SPDFMacAITransport.mm mac/SPDFMacAICredentials.mm mac/SPDFMacAISettings.mm mac/SPDFMacAIOpenRouterAuth.mm mac/SPDFMacAISignInReturnWatch.mm -framework AppKit -framework Security -framework LocalAuthentication -o "$(BUILD)/SPDFMacAITransportTests"
	"$(BUILD)/SPDFMacAITransportTests"
mac-ai-chat-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac \
		mac/tests/SPDFMacAIChatSessionTests.mm $(MAC_AI_SESSION_SRCS) -framework Cocoa -framework ImageIO -o \
		"$(BUILD)/SPDFMacAIChatSessionTests"
	"$(BUILD)/SPDFMacAIChatSessionTests"
mac-ai-tool-seam-tests: | $(BUILD)
	rm -f "$(BUILD)/SPDFMacAIToolSeamTests"
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacAIToolSeamTests.mm \
		$(MAC_AI_SESSION_SRCS) mac/SPDFMacAISettings.mm -framework Cocoa -framework ImageIO \
		-o "$(BUILD)/SPDFMacAIToolSeamTests"
	"$(BUILD)/SPDFMacAIToolSeamTests"
# The Settings window as its tests link it: the controller and the pages it builds.
MAC_SETTINGS_WINDOW_SRCS := mac/SPDFMacUnifiedSettings.mm mac/SPDFMacAICapabilitiesSettings.mm \
	mac/SPDFMacSearchablePicker.mm mac/SPDFMacCollectionStyle.mm mac/SPDFMacGroupActionButton.mm \
	mac/friends/SPDFMacFriendsSettingsPage.mm mac/friends/SPDFMacFriendsSettingsPane.mm
mac-unified-settings-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac \
		mac/tests/SPDFMacUnifiedSettingsTests.mm $(MAC_SETTINGS_WINDOW_SRCS) -framework Cocoa -o \
		"$(BUILD)/SPDFMacUnifiedSettingsTests"
	"$(BUILD)/SPDFMacUnifiedSettingsTests"
# The AI page's capabilities section with the settings it saves. The reader's two category files need the whole
# coordinator to link, so they are compiled for syntax only.
.PHONY: mac-ai-capabilities-settings-tests
mac-ai-capabilities-settings-tests: | $(BUILD)
	rm -f "$(BUILD)/SPDFMacAICapabilitiesSettingsTests"
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -fsyntax-only -Imac -Icore \
		-I$(MUPDF_DIR)/include mac/SPDFMacAICapabilitiesSettingsIntegration.mm mac/SPDFMacAISettingsIntegration.mm
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac \
		mac/tests/SPDFMacAICapabilitiesSettingsTests.mm $(MAC_SETTINGS_WINDOW_SRCS) mac/SPDFMacAISettings.mm \
		mac/SPDFMacAITransport.mm -framework Cocoa -o "$(BUILD)/SPDFMacAICapabilitiesSettingsTests"
	"$(BUILD)/SPDFMacAICapabilitiesSettingsTests" "$(abspath .)"
.PHONY: mac-ai-model-tests
mac-ai-model-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacAIModelCatalogTests.mm mac/SPDFMacAIModelCatalog.mm -framework Foundation -o "$(BUILD)/SPDFMacAIModelCatalogTests"
	"$(BUILD)/SPDFMacAIModelCatalogTests"

# Registered here so release discovery includes the production-linked AI suites. Discovery
# (release/release-common.sh spdf_discover_test_targets) reads only this file, so each suite's name is a line here.
include mac/tests/ai-reader-tests.mk
include mac/tests/ai-document-job-tests.mk
include mac/tests/ai-web-tests.mk
include mac/tests/ai-subagents-tests.mk
.PHONY: mac-ai-reader-tests mac-ai-document-job-tests mac-chat-markdown-tests mac-ai-web-tests mac-ai-subagents-tests
mac-ai-reader-tests: mac-ai-reader-acceptance
# Markdown in AI chat and Friends messages (mac/tests/chat-markdown-tests.mk, included by ai-reader-tests.mk).
mac-chat-markdown-tests: mac-chat-markdown-acceptance
mac-ai-document-job-tests: mac-ai-document-job-acceptance
# The assistant's web search and pages, and run_subagents' parallel read-only tasks.
mac-ai-web-tests: mac-ai-web-acceptance
mac-ai-subagents-tests: mac-ai-subagents-acceptance
# The assistant's Python sandbox helper, embedded and signed by mac-app above, and run_python's suites.
include mac/python-sandbox/python-sandbox.mk
.PHONY: mac-ai-python-tests
mac-ai-python-tests: mac-ai-python-suite
$(MAC_BIN): $(MAC_PYTHON_SANDBOX_BIN)

include mac/tests/translation-tests.mk
include friends/friends.mk
# The host adapter's suite runs with the Friends suites, so the release sweep's friends-tests covers it.
include mac/friends/friends-host-adapter.mk
# The dropdown driven end to end, clicks and keys against real helpers (mac/friends/tests/ui-e2e/friends-ui-e2e.mk).
include mac/friends/tests/ui-e2e/friends-ui-e2e.mk
friends-tests: friends-suite mac-friends-host-adapter-tests friends-ui-e2e
	$(if $(FRIENDS_UI_E2E_VARIANTS)$(FRIENDS_UI_E2E_FLOWS),@:,$(call spdf_test_stamp,friends-tests))

# Shenzhen Friends in ShenzhenPDF.app (friends/README.md § Integration the lead owns). Read after friends.mk, so the
# Friends variables are set here and prerequisite lists get a second expansion.
#
# The app links the views, the client library, cJSON and the avatars set, never the picture pipeline or libsodium:
# those stay in the helper, so a hostile image is only ever decoded there. The host adapter is compiled on its own
# with -Ifriends, so no reader source sees the Friends include path; reader files reach it only through
# friends/SPDFMacFriendsIntegration.h and friends/SPDFMacFriendsSettingsPage.h, which need -Imac alone.
MAC_FRIENDS_ADAPTER_SRCS := $(sort $(wildcard mac/friends/SPDFMacFriends*.mm))
MAC_FRIENDS_ADAPTER_HDRS := $(sort $(wildcard mac/friends/*.h))
MAC_FRIENDS_ADAPTER_OBJS := $(patsubst mac/friends/%.mm,$(BUILD)/friends-app/%.o,$(MAC_FRIENDS_ADAPTER_SRCS))
MAC_FRIENDS_LINK := $(MAC_FRIENDS_ADAPTER_OBJS) $(FRIENDS_VIEWS_OBJS) $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) \
	$(FRIENDS_AVATARS_SET_OBJS)
MAC_FRIENDS_FRAMEWORKS := $(FRIENDS_VIEWS_LIBS)

$(BUILD)/friends-app/%.o: mac/friends/%.mm $(MAC_FRIENDS_ADAPTER_HDRS) $(MAC_HDRS) $(FRIENDS_VIEWS_HDRS) Makefile
	@mkdir -p "$(@D)"
	clang++ $(PORTABLE_OPTFLAGS) $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac -Icore -I$(MUPDF_DIR)/include \
		-Ifriends -Imac/friends -c "$<" -o "$@"

# The helper bundle (friends/service/helper/helper.mk) goes in Contents/Helpers/, where the adapter's
# SPDFMacFriendsHelperExecutablePath looks, and is signed on its own line before the outer bundle, like the Collection
# companion. Its version keys are set again here from this build's MAC_VERSION and MAC_BUILD, because helper.mk's
# bundle is only rebuilt when a file changes: CFBundleShortVersionString is the app's version, and CFBundleVersion
# and SZFriendsBuildNumber are helper.mk's YYMMDDBB build number. The views send CFBundleVersion and the running
# helper compares it with its own SZFriendsBuildNumber to decide on a handover (PROTOCOL.md § Lifecycle), so the two
# must be the same number, and one that only increases from release to release (MAC_BUILD alone restarts at 1).
#
# The animal set ships once, in the app's Resources/Friends/animals/, where the views' +[SZFriendsAnimalSet
# bundledSet] looks; the embedded helper drops its own copy and finds the app's (friends/avatars/SZFriendsAnimalSet.m).
# The standalone helper bundle keeps its copy for the helper's own tests.
MAC_FRIENDS_HELPER_APP := $(MAC_APP)/Contents/Helpers/$(FRIENDS_HELPER_APP_NAME).app
MAC_FRIENDS_HELPER_PLIST = "$(MAC_FRIENDS_HELPER_APP)/Contents/Info.plist"
MAC_FRIENDS_RESOURCES := $(MAC_APP)/Contents/Resources/Friends
MAC_FRIENDS_ANIMALS := friends/avatars/animals
MAC_FRIENDS_ANIMAL_SVGS := $(sort $(wildcard $(MAC_FRIENDS_ANIMALS)/svg/*.svg))
MAC_FRIENDS_ANIMAL_PDFS := $(sort $(wildcard $(MAC_FRIENDS_ANIMALS)/pdf/*.pdf))
MAC_FRIENDS_ACKNOWLEDGEMENTS := friends/ACKNOWLEDGEMENTS.txt
FRIENDS_HELPER_RESOURCES += $(MAC_FRIENDS_ACKNOWLEDGEMENTS)=Acknowledgements.txt

define MAC_FRIENDS_EMBED
mkdir -p "$(MAC_FRIENDS_RESOURCES)/animals/svg" "$(MAC_FRIENDS_RESOURCES)/animals/pdf"
cp $(MAC_FRIENDS_ANIMALS)/manifest.json "$(MAC_FRIENDS_RESOURCES)/animals/"
cp $(MAC_FRIENDS_ANIMAL_SVGS) "$(MAC_FRIENDS_RESOURCES)/animals/svg/"
cp $(MAC_FRIENDS_ANIMAL_PDFS) "$(MAC_FRIENDS_RESOURCES)/animals/pdf/"
cp $(MAC_FRIENDS_ACKNOWLEDGEMENTS) "$(MAC_FRIENDS_RESOURCES)/Acknowledgements.txt"
cp -R "$(FRIENDS_HELPER_APP)" "$(MAC_APP)/Contents/Helpers/"
rm -rf "$(MAC_FRIENDS_HELPER_APP)/Contents/Resources/Friends"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(MAC_VERSION)" $(MAC_FRIENDS_HELPER_PLIST)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(FRIENDS_HELPER_BUILD_NUMBER)" $(MAC_FRIENDS_HELPER_PLIST)
/usr/libexec/PlistBuddy -c "Set :SZFriendsBuildNumber $(FRIENDS_HELPER_BUILD_NUMBER)" $(MAC_FRIENDS_HELPER_PLIST)
endef

# Run at the end of every app build, and on its own against dist/ by mac-friends-bundle-check: what the release
# depends on and a stale or partial build could get wrong.
define MAC_FRIENDS_BUNDLE_CHECK
codesign --verify --strict --verbose=2 "$(MAC_FRIENDS_HELPER_APP)"
codesign --verify --deep --strict --verbose=2 "$(MAC_APP)"
test -x "$(MAC_FRIENDS_HELPER_APP)/Contents/MacOS/$(FRIENDS_HELPER_APP_NAME)"
test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $(MAC_FRIENDS_HELPER_PLIST))" = "$(MAC_VERSION)"
build=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $(MAC_FRIENDS_HELPER_PLIST)); \
	case "$$build" in ''|*[!0-9]*) echo "Friends helper CFBundleVersion is not an integer: $$build" >&2; exit 1;; esac; \
	test "$$build" = "$$(/usr/libexec/PlistBuddy -c 'Print :SZFriendsBuildNumber' $(MAC_FRIENDS_HELPER_PLIST))"
test ! -e "$(MAC_FRIENDS_HELPER_APP)/Contents/Resources/Friends"
cmp $(MAC_FRIENDS_ANIMALS)/manifest.json "$(MAC_FRIENDS_RESOURCES)/animals/manifest.json"
test "$$(ls -A "$(MAC_FRIENDS_RESOURCES)/animals")" = "$$(printf 'manifest.json\npdf\nsvg')"
test "$$(ls -A "$(MAC_FRIENDS_RESOURCES)/animals/svg")" = "$$(printf '%s\n' $(notdir $(MAC_FRIENDS_ANIMAL_SVGS)))"
test "$$(ls -A "$(MAC_FRIENDS_RESOURCES)/animals/pdf")" = "$$(printf '%s\n' $(notdir $(MAC_FRIENDS_ANIMAL_PDFS)))"
cmp $(MAC_FRIENDS_ACKNOWLEDGEMENTS) "$(MAC_FRIENDS_RESOURCES)/Acknowledgements.txt"
cmp $(MAC_FRIENDS_ACKNOWLEDGEMENTS) "$(MAC_FRIENDS_HELPER_APP)/Contents/Resources/Acknowledgements.txt"
nm -gU "$(MAC_BIN)" | grep -qF '_OBJC_CLASS_$$_SZFriendsDropdownController'
release/verify-mac-artifact.sh --friends-usage-keys "$(MAC_APP)"
endef

.PHONY: mac-friends-bundle-check
mac-friends-bundle-check:
	$(MAC_FRIENDS_BUNDLE_CHECK)
	@echo "mac-friends-bundle-check passed"

# The acknowledgements must carry every line of each license and the word list's own attribution, so a dependency
# upgrade that changes a copyright line, or a word list that changes its word count, fails the app build until
# ACKNOWLEDGEMENTS.txt follows. Comment decoration (libsodium's LICENSE is a C comment) and wrapping are ignored.
# Mbed TLS is not listed: its LICENSE also holds the GPL-2.0 text, which Friends does not take it under, so only its
# Apache-2.0 part is in the acknowledgements.
MAC_FRIENDS_LICENSES := ../ext/libsodium/LICENSE ../ext/cjson/LICENSE ../ext/libdatachannel/LICENSE \
	../ext/libjuice/LICENSE ../ext/usrsctp/LICENSE.md ../ext/plog/LICENSE ../ext/miniupnpc/LICENSE
MAC_FRIENDS_NOTICES_STAMP := $(BUILD)/friends-app/acknowledgements.stamp
$(MAC_FRIENDS_NOTICES_STAMP): $(MAC_FRIENDS_ACKNOWLEDGEMENTS) $(MAC_FRIENDS_LICENSES) $(FRIENDS_IDENTITY_WORDS) Makefile
	@mkdir -p "$(@D)"
	@for license in $(MAC_FRIENDS_LICENSES); do \
		sed -E -e 's#^[[:space:]]*(/\*|\*/|\*)?[[:space:]]*##' -e 's#[[:space:]]*$$##' "$$license" | grep -v '^$$' | \
		while IFS= read -r line; do grep -qF -- "$$line" $(MAC_FRIENDS_ACKNOWLEDGEMENTS) || \
			{ echo "$(MAC_FRIENDS_ACKNOWLEDGEMENTS) lacks this line of $$license: $$line" >&2; exit 1; }; \
		done || exit 1; \
	done
	@test -f "$(FRIENDS_IDENTITY_WORDS)"
	@attribution=$$(sed -n '/^# Friends ID words are a selection/,/^# Changes:/s/^# //p' "$(FRIENDS_IDENTITY_WORDS)" | \
		tr -s '[:space:]' ' '); test -n "$$attribution" && tr -s '[:space:]' ' ' < $(MAC_FRIENDS_ACKNOWLEDGEMENTS) | \
		grep -qF -- "$${attribution% }" || \
		{ echo "$(MAC_FRIENDS_ACKNOWLEDGEMENTS) lacks the word list's attribution: $$attribution" >&2; exit 1; }
	@touch "$@"

$(MAC_BIN): $(MAC_FRIENDS_LINK) $(MAC_FRIENDS_ADAPTER_HDRS) $(FRIENDS_HELPER_BUNDLE_STAMP) \
	$(MAC_FRIENDS_ANIMALS)/manifest.json $(MAC_FRIENDS_ANIMAL_SVGS) $(MAC_FRIENDS_ANIMAL_PDFS) $(MAC_FRIENDS_NOTICES_STAMP)

# The reader calls the host adapter, so the binaries that link the whole reader (mac/tests/workspace-probe.mk and
# mac/tests/ai-reader-tests.mk) link Friends too. Their link recipes read these lists when they run, after this
# append; their prerequisite lists were read before Friends was, hence the rule below. Their frameworks already cover
# the views' (Cocoa, ImageIO, UniformTypeIdentifiers, and QuartzCore, which re-exports CoreImage).
MAC_WORKSPACE_PROBE_OBJS += $(MAC_FRIENDS_LINK)
MAC_README_PROBE_OBJS += $(MAC_FRIENDS_LINK)
MAC_AI_README_OBJS += $(MAC_FRIENDS_LINK)
MAC_AI_SOURCE_CARD_OBJS += $(MAC_FRIENDS_LINK)
AI_READER_BASE_OBJS += $(MAC_FRIENDS_LINK)
$(MAC_WORKSPACE_PROBE) $(MAC_README_PROBE) $(MAC_AI_README_PROBE) $(MAC_AI_SOURCE_CARD_PROBE) $(AI_CONTEXT_TEST) \
	$(AI_ANALYSIS_TEST): \
	$(MAC_FRIENDS_LINK)

# Registered here so release discovery includes the production-linked minimap suite.
include mac/tests/minimap-fill-tests.mk
.PHONY: mac-minimap-fill-tests
mac-minimap-fill-tests: mac-minimap-fill-acceptance

# Registered here so release discovery includes the production-linked page-load suite.
include mac/tests/page-load-tests.mk
.PHONY: mac-page-load-tests
mac-page-load-tests: mac-page-load-acceptance

# Registered here so release discovery includes the production-linked page-display suite.
include mac/tests/page-display-tests.mk
.PHONY: mac-page-display-tests
mac-page-display-tests: mac-page-display-acceptance

# Registered here so release discovery includes the launch performance gate (this tree against the previous release).
include mac/tests/launch/launch-performance-tests.mk
.PHONY: mac-launch-performance-tests
mac-launch-performance-tests: mac-launch-performance-gate
	$(if $(LAUNCH_PERF_ROUNDS),@:,$(call spdf_test_stamp,mac-launch-performance-tests))
