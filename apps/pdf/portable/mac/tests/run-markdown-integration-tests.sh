#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd)
PORTABLE="$REPO/portable"
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/spdf-markdown-ui-tests.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT INT TERM

CC=$(xcrun --find clang)
CXX=$(xcrun --find clang++)
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
SANITIZER_FLAGS=${SPDF_MARKDOWN_SANITIZER_FLAGS:-}

# shellcheck disable=SC1091
. "$SCRIPT_DIR/compile-jobs.sh"

# Intentional word splitting: SANITIZER_FLAGS is a caller-supplied flag list.
# shellcheck disable=SC2086
spdf_job "$CC" -isysroot "$SDKROOT" -std=c11 -O0 -g -Wall -Wextra -Werror \
    $SANITIZER_FLAGS -I"$REPO/ext/md4c" -c "$REPO/ext/md4c/md4c.c" -o "$BUILD_DIR/md4c.o"

# The shared dark-reading recolor, used by the Markdown page drawing to darken
# a document's embedded images the way a PDF's are darkened in the render tail.
# shellcheck disable=SC2086
spdf_job "$CC" -isysroot "$SDKROOT" -std=c11 -O0 -g -Wall -Wextra -Werror \
    $SANITIZER_FLAGS -I"$PORTABLE/core" -c "$PORTABLE/core/spdf_recolor.c" -o "$BUILD_DIR/spdf_recolor.o"

# Vendored Gumbo HTML5 parser backing the sanitizing HTML-island whitelist.
# Third-party sources compile without -Werror.
GUMBO_OBJS=""
for GUMBO_SRC in "$REPO/ext/gumbo-parser/src"/*.c; do
    GUMBO_OBJ="$BUILD_DIR/gumbo-$(basename "$GUMBO_SRC" .c).o"
    # shellcheck disable=SC2086
    spdf_job "$CC" -isysroot "$SDKROOT" -std=c99 -O0 -g $SANITIZER_FLAGS \
        -I"$REPO/ext/gumbo-parser/src" -c "$GUMBO_SRC" -o "$GUMBO_OBJ"
    GUMBO_OBJS="$GUMBO_OBJS $GUMBO_OBJ"
done

FOUNDATION_SOURCES="
$PORTABLE/mac/markdown/SPDFMarkdownModel.mm
$PORTABLE/mac/markdown/SPDFMarkdownAuthoring.mm
$PORTABLE/mac/markdown/SPDFMarkdownLayoutReport.mm
$PORTABLE/mac/markdown/SPDFMarkdownMathTypesetter.mm
$PORTABLE/mac/markdown/SPDFMarkdownParser.mm
$PORTABLE/mac/markdown/SPDFMarkdownHTML.mm
$PORTABLE/mac/markdown/SPDFMarkdownHTMLBlocks.mm
$PORTABLE/mac/markdown/SPDFMarkdownResources.mm
$PORTABLE/mac/markdown/SPDFMarkdownLanguage.mm
$PORTABLE/mac/markdown/SPDFMarkdownHighlighter.mm
$PORTABLE/mac/markdown/SPDFMarkdownLexerSupport.mm
$PORTABLE/mac/markdown/SPDFMarkdownLexersCFamily.mm
$PORTABLE/mac/markdown/SPDFMarkdownLexersScripting.mm
$PORTABLE/mac/markdown/SPDFMarkdownLexersMarkup.mm
$PORTABLE/mac/markdown/SPDFMarkdownLexersData.mm
$PORTABLE/mac/markdown/SPDFMarkdownRenderer.mm
$PORTABLE/mac/markdown/SPDFMarkdownBlockRenderer.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagram.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramModel.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramCanvas.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramFlowchartParser.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramStyle.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramSequenceParser.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramStructParsers.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramChartParsers.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramLayout.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramBand.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramGraphEdges.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramGraphShapes.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramSequenceShapes.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramChartShapes.mm
$PORTABLE/mac/markdown/SPDFMarkdownDiagramBlock.mm
$PORTABLE/mac/markdown/SPDFMarkdownInlineRenderer.mm
$PORTABLE/mac/markdown/SPDFMarkdownDecorations.mm
$PORTABLE/mac/markdown/SPDFMarkdownTheme.mm
$PORTABLE/mac/markdown/SPDFMarkdownTableDecorations.mm
$PORTABLE/mac/markdown/SPDFMarkdownTableLayout.mm
$PORTABLE/mac/markdown/SPDFMarkdownImageRowBand.mm
$PORTABLE/mac/markdown/SPDFMarkdownPaginator.mm
$PORTABLE/mac/markdown/SPDFMarkdownPlanLocationIndex.mm
$PORTABLE/mac/markdown/SPDFMarkdownPaginatorDrawing.mm
$PORTABLE/mac/markdown/SPDFMarkdownImageRecolor.mm
$PORTABLE/mac/markdown/SPDFMarkdownAsync.mm
$PORTABLE/mac/markdown/SPDFMarkdownDocument.mm
"
COLLECTION_STORE_SOURCES=$(printf '%s\n' "$PORTABLE"/mac/SPDFMacCollectionStore*.mm)

UI_SOURCES="
$PORTABLE/mac/SPDFMacCollectionWindow.mm
$PORTABLE/mac/SPDFMacCollectionManagerWindow.mm
$PORTABLE/mac/SPDFMacCollectionStyle.mm
$PORTABLE/mac/SPDFMacPaletteAppearance.mm
$PORTABLE/mac/SPDFMacSidebarPresentation.mm
$PORTABLE/mac/SPDFMacCollectionWindowActions.mm
$PORTABLE/mac/SPDFMacCollectionWindowThumbnails.mm
$PORTABLE/mac/SPDFMacCollectionThumbnailLoader.mm
$PORTABLE/mac/SPDFMacTabPreviewCache.mm
$PORTABLE/mac/SPDFMacCollectionWindowLayout.mm
$PORTABLE/mac/SPDFMacCollectionWindowSettings.mm
$PORTABLE/mac/SPDFMacCollectionWindowState.mm
$PORTABLE/mac/SPDFMacCollectionWindowSearch.mm
$PORTABLE/mac/SPDFMacCollectionWindowHistory.mm
$PORTABLE/mac/SPDFMacCollectionUsage.mm
$PORTABLE/mac/SPDFMacCollectionHistory.mm
$PORTABLE/mac/SPDFMacSidebarModeControl.mm
$PORTABLE/mac/SPDFMacSidebarNavigation.mm
$PORTABLE/mac/SPDFMacFileExplorerPreference.mm
$PORTABLE/mac/SPDFMacCollectionSavePanel.mm
$PORTABLE/mac/SPDFMacCollectionCompareViews.mm
$PORTABLE/mac/SPDFMacCollectionCompareWindow.mm
$PORTABLE/mac/SPDFMacCollectionCompareLatest.mm
$PORTABLE/mac/SPDFMacCollectionLocate.mm
$COLLECTION_STORE_SOURCES
$PORTABLE/mac/SPDFMacSearchFileCache.mm
$PORTABLE/mac/SPDFMacCollectionCompareEngine.mm
$PORTABLE/mac/SPDFMacCollectionCompareLoad.mm
$PORTABLE/mac/SPDFMacCollectionPaletteModel.mm
$PORTABLE/mac/SPDFMacPaletteDocumentNames.mm
$PORTABLE/mac/tests/SPDFMacMarkdownScrollViewTestSupport.mm
$PORTABLE/mac/SPDFMacMarkdownCache.mm
$PORTABLE/mac/SPDFMacMarkdownKeyboardPolicy.mm
$PORTABLE/mac/SPDFMacMarkdownRouting.mm
$PORTABLE/mac/SPDFMacMarkdownView.mm
$PORTABLE/mac/SPDFMacCursorRegions.mm
$PORTABLE/mac/SPDFMacFindNearest.mm
$PORTABLE/mac/SPDFMacMarkdownPanController.mm
$PORTABLE/mac/SPDFMacMarkdownPageCanvas.mm
$PORTABLE/mac/SPDFMacMarkdownPageCanvas+Copy.mm
$PORTABLE/mac/SPDFMacMarkdownPageCanvas+Cursor.mm
$PORTABLE/mac/SPDFMacMarkdownPageCanvas+Focus.mm
$PORTABLE/mac/SPDFMacMarkdownPageCanvas+Decorations.mm
$PORTABLE/mac/SPDFMacMarkdownPageCanvas+Navigation.mm
$PORTABLE/mac/SPDFMacMarkdownPageCanvas+Pan.mm
$PORTABLE/mac/SPDFMacMarkdownPageCanvas+Search.mm
$PORTABLE/mac/SPDFMacMarkdownPagedView.mm
$PORTABLE/mac/SPDFMacMarkdownPagedView+Fit.mm
$PORTABLE/mac/SPDFMacMarkdownClipView.mm
$PORTABLE/mac/SPDFMacMarkdownCopyText.mm
$PORTABLE/mac/SPDFMacRenderedPage.mm
$PORTABLE/mac/SPDFMacMarkdownMinimapModel.mm
$PORTABLE/mac/SPDFMacMarkdownSidebarModel.mm
$PORTABLE/mac/SPDFMacMarkdownLanguagePicker.mm
$PORTABLE/mac/SPDFMacMarkdownPrinting.mm
$PORTABLE/mac/SPDFMacMarkdownSession.mm
$PORTABLE/mac/SPDFMacMarkdownSession+Appearance.mm
$PORTABLE/mac/SPDFMacMarkdownSession+Export.mm
$PORTABLE/mac/SPDFMacMarkdownSession+Interaction.mm
$PORTABLE/mac/SPDFMacMarkdownSession+Paper.mm
$PORTABLE/mac/SPDFMacMarkdownSession+Reload.mm
$PORTABLE/mac/SPDFMacMarkdownSession+RemoteImages.mm
$PORTABLE/mac/SPDFMacMarkdownSession+Search.mm
$PORTABLE/mac/SPDFMacMarkdownSession+SearchResults.mm
$PORTABLE/mac/SPDFMacProgressiveSearch.mm
$PORTABLE/mac/SPDFMacMarkdownSession+ViewSwap.mm
$PORTABLE/mac/SPDFMacMarkdownSessionImageLoader.mm
"

TESTS="
SPDFMacPaletteAppearanceTests
SPDFMacSidebarPresentationTests
SPDFMacCollectionCompareLatestTests
SPDFMacCollectionComparePresentationTests
SPDFMacCollectionWindowTests
SPDFMacCollectionStyleTests
SPDFMacCollectionMarkdownIndexTests
SPDFMacCollectionCompareLoadTests
SPDFMacCollectionContextSearchMarkdownTests
SPDFMacCollectionHistorySidebarTests
SPDFMacMarkdownKeyboardPolicyTests
SPDFMacMarkdownRoutingTests
SPDFMacMarkdownPagedViewTests
SPDFMacMarkdownPanTests
SPDFMacMarkdownCopyTextTests
SPDFMacMarkdownLinkHitTests
SPDFMacMarkdownCopySelectionTests
SPDFMacMarkdownMinimapModelTests
SPDFMacMarkdownSidebarModelTests
SPDFMacMarkdownSessionTests
SPDFMacMarkdownSessionFindTests
SPDFMacMarkdownRemoteImageSessionTests
SPDFMacMarkdownLanguagePickerTests
SPDFMacMarkdownCodeControlsTests
SPDFMacMarkdownPrintingTests
SPDFMacMarkdownOrientationTests
SPDFMacMarkdownNavigationReadinessTests
"

# Match production ARC lifetime optimization; unoptimized outlets can mask weak-reference bugs.
CXXFLAGS="-isysroot $SDKROOT -std=c++17 -fobjc-arc -O2 -g -Wall -Wextra -Werror -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation $SANITIZER_FLAGS \
-I$PORTABLE/core -I$PORTABLE/mac -I$PORTABLE/mac/markdown"

# The foundation and UI sources are identical for every test binary, so compile
# each ONE object once and link it into all of them. Passing the whole list to
# every link rebuilt the same ~67 translation units for each of the 11 suites.
SHARED_OBJS=""
for SRC in $FOUNDATION_SOURCES $UI_SOURCES; do
    OBJ="$BUILD_DIR/shared-$(basename "$SRC" .mm).o"
    SHARED_OBJS="$SHARED_OBJS $OBJ"
    # shellcheck disable=SC2086
    spdf_job "$CXX" $CXXFLAGS -c "$SRC" -o "$OBJ"
done
for TEST in $TESTS; do
    # shellcheck disable=SC2086
    spdf_job "$CXX" $CXXFLAGS -c "$SCRIPT_DIR/$TEST.mm" -o "$BUILD_DIR/test-$TEST.o"
done
spdf_join

# Link all of the binaries before running any of them: each link pulls in the
# same ~100 objects, and interleaving link-then-run left the machine idle on
# one linker at a time. The suites still RUN one at a time, in list order, so
# the output stays deterministic and a failure is attributable.
for TEST in $TESTS
do
    # Intentional word splitting: the object lists are shell-safe build paths.
    # shellcheck disable=SC2086
    spdf_job "$CXX" -isysroot "$SDKROOT" $SANITIZER_FLAGS \
        $SHARED_OBJS "$BUILD_DIR/test-$TEST.o" "$BUILD_DIR/md4c.o" "$BUILD_DIR/spdf_recolor.o" $GUMBO_OBJS \
        -framework Foundation -framework AppKit -framework CoreText -framework PDFKit -framework ImageIO \
        -framework UniformTypeIdentifiers -framework QuartzCore -o "$BUILD_DIR/$TEST"
done
spdf_join

for TEST in $TESTS
do
    "$BUILD_DIR/$TEST"
done
