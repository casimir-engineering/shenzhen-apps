#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../../../.." && pwd)
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/spdf-markdown-tests.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT INT TERM

CC=$(xcrun --find clang)
CXX=$(xcrun --find clang++)
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
SANITIZER_FLAGS=${SPDF_MARKDOWN_SANITIZER_FLAGS:-}
# Diagram layout is guarded by a 50 ms wall-clock deadline in production. Racing
# that clock made these suites fail intermittently (3 of 5 runs on an idle
# machine, different assertions each time), so give layout room here and let the
# tests assert geometry deterministically. Overridable for a deliberate
# deadline test.
export SPDF_DIAGRAM_LAYOUT_DEADLINE=${SPDF_DIAGRAM_LAYOUT_DEADLINE:-5}

# shellcheck disable=SC1091
. "$SCRIPT_DIR/../compile-jobs.sh"

# Intentional word splitting: SANITIZER_FLAGS is a caller-supplied compiler flag list.
# shellcheck disable=SC2086
spdf_job "$CC" -isysroot "$SDKROOT" -std=c11 -O0 -g -Wall -Wextra -Werror \
    $SANITIZER_FLAGS \
    -I"$ROOT/ext/md4c" \
    -c "$ROOT/ext/md4c/md4c.c" \
    -o "$BUILD_DIR/md4c.o"

# The portable recolor module, so SPDFMarkdownRendererTests can assert that the
# core's dark endpoints still equal SPDFMarkdownTheme's. It is freestanding C
# with no mupdf dependency, which is why it can be linked here at all.
# shellcheck disable=SC2086
spdf_job "$CC" -isysroot "$SDKROOT" -std=c11 -O0 -g -Wall -Wextra -Werror \
    $SANITIZER_FLAGS \
    -I"$ROOT/portable/core" \
    -c "$ROOT/portable/core/spdf_recolor.c" \
    -o "$BUILD_DIR/spdf_recolor.o"

# Vendored Gumbo HTML5 parser backing the sanitizing HTML-island whitelist.
# Third-party sources compile without -Werror.
GUMBO_OBJS=""
for GUMBO_SRC in "$ROOT/ext/gumbo-parser/src"/*.c; do
    GUMBO_OBJ="$BUILD_DIR/gumbo-$(basename "$GUMBO_SRC" .c).o"
    # shellcheck disable=SC2086
    spdf_job "$CC" -isysroot "$SDKROOT" -std=c99 -O0 -g \
        $SANITIZER_FLAGS \
        -I"$ROOT/ext/gumbo-parser/src" \
        -c "$GUMBO_SRC" -o "$GUMBO_OBJ"
    GUMBO_OBJS="$GUMBO_OBJS $GUMBO_OBJ"
done

SOURCES="
$ROOT/portable/mac/markdown/SPDFMarkdownModel.mm
$ROOT/portable/mac/markdown/SPDFMarkdownAuthoring.mm
$ROOT/portable/mac/markdown/SPDFMarkdownLayoutReport.mm
$ROOT/portable/mac/markdown/SPDFMarkdownMathTypesetter.mm
$ROOT/portable/mac/markdown/SPDFMarkdownParser.mm
$ROOT/portable/mac/markdown/SPDFMarkdownHTML.mm
$ROOT/portable/mac/markdown/SPDFMarkdownHTMLBlocks.mm
$ROOT/portable/mac/markdown/SPDFMarkdownResources.mm
$ROOT/portable/mac/markdown/SPDFMarkdownLanguage.mm
$ROOT/portable/mac/markdown/SPDFMarkdownHighlighter.mm
$ROOT/portable/mac/markdown/SPDFMarkdownLexerSupport.mm
$ROOT/portable/mac/markdown/SPDFMarkdownLexersCFamily.mm
$ROOT/portable/mac/markdown/SPDFMarkdownLexersScripting.mm
$ROOT/portable/mac/markdown/SPDFMarkdownLexersMarkup.mm
$ROOT/portable/mac/markdown/SPDFMarkdownLexersData.mm
$ROOT/portable/mac/markdown/SPDFMarkdownRenderer.mm
$ROOT/portable/mac/markdown/SPDFMarkdownBlockRenderer.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagram.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramModel.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramCanvas.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramFlowchartParser.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramStyle.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramSequenceParser.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramStructParsers.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramChartParsers.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramLayout.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramBand.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramGraphEdges.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramGraphShapes.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramSequenceShapes.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramChartShapes.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDiagramBlock.mm
$ROOT/portable/mac/markdown/SPDFMarkdownInlineRenderer.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDecorations.mm
$ROOT/portable/mac/markdown/SPDFMarkdownTheme.mm
$ROOT/portable/mac/markdown/SPDFMarkdownTableDecorations.mm
$ROOT/portable/mac/markdown/SPDFMarkdownTableLayout.mm
$ROOT/portable/mac/markdown/SPDFMarkdownImageRowBand.mm
$ROOT/portable/mac/markdown/SPDFMarkdownPaginator.mm
$ROOT/portable/mac/markdown/SPDFMarkdownPaginatorDrawing.mm
$ROOT/portable/mac/markdown/SPDFMarkdownImageRecolor.mm
$ROOT/portable/mac/markdown/SPDFMarkdownAsync.mm
$ROOT/portable/mac/markdown/SPDFMarkdownDocument.mm
"

TESTS=""
for TEST in \
    SPDFMarkdownParserTests \
    SPDFTextDocumentTests \
    SPDFMarkdownHTMLTests \
    SPDFMarkdownInlineFormattingTests \
    SPDFMarkdownMathTests \
    SPDFMarkdownLanguageTests \
    SPDFMarkdownRendererTests \
    SPDFMarkdownImageFigureTests \
    SPDFMarkdownPageBudgetTests \
    SPDFMarkdownImageRecolorTests \
    SPDFMarkdownDiagramTests \
    SPDFMarkdownDiagramLayoutTests \
    SPDFMarkdownDiagramEdgeRoutingTests \
    SPDFMarkdownDiagramNodeTextTests \
    SPDFMarkdownDiagramStyleTests \
    SPDFMarkdownDiagramLabelMarkupTests \
    SPDFMarkdownRemoteImageTests \
    SPDFMarkdownPaginatorTests \
    SPDFMarkdownPageFooterTests \
    SPDFMarkdownTableLayoutTests \
    SPDFMarkdownAsyncTests \
    SPDFMarkdownPDFAdapterTests \
    SPDFMarkdownAuthoringTests \
    SPDFMarkdownPerformanceTests
do
    TESTS="$TESTS $TEST"
done

CXXFLAGS="-isysroot $SDKROOT -std=c++17 -fobjc-arc -O0 -g -Wall -Wextra -Werror $SANITIZER_FLAGS \
-I$ROOT/portable/mac/markdown -I$ROOT/portable/core"

# The shared sources are identical for every test binary, so compile each ONE
# object once and link it into all of them. Compiling the whole list per test
# rebuilt the same ~30 translation units for each of the ~14 suites.
SHARED_OBJS=""
for SRC in $SOURCES; do
    OBJ="$BUILD_DIR/shared-$(basename "$SRC" .mm).o"
    SHARED_OBJS="$SHARED_OBJS $OBJ"
    # shellcheck disable=SC2086
    spdf_job "$CXX" $CXXFLAGS -c "$SRC" -o "$OBJ"
done
for SRC in $TESTS; do
    # shellcheck disable=SC2086
    spdf_job "$CXX" $CXXFLAGS -c "$SCRIPT_DIR/$SRC.mm" -o "$BUILD_DIR/test-$SRC.o"
done
spdf_join

# Link all of the binaries before running any of them: each link pulls in the
# same ~70 objects, and interleaving link-then-run left the machine idle on one
# linker at a time. The suites still RUN one at a time, in list order, so the
# output stays deterministic and a failure is attributable.
for TEST in $TESTS
do
    # Intentional word splitting: the object lists are shell-safe build paths.
    # shellcheck disable=SC2086
    spdf_job "$CXX" -isysroot "$SDKROOT" $SANITIZER_FLAGS \
        $SHARED_OBJS "$BUILD_DIR/test-$TEST.o" "$BUILD_DIR/md4c.o" "$BUILD_DIR/spdf_recolor.o" $GUMBO_OBJS \
        -framework Foundation -framework AppKit -framework CoreText -framework PDFKit \
        -o "$BUILD_DIR/$TEST"
done
spdf_join

for TEST in $TESTS
do
    "$BUILD_DIR/$TEST"
done
