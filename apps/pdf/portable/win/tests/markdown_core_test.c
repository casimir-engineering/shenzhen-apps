/* markdown_core_test.c -- runs the core's Markdown converter suite under the
 * Windows harness.
 *
 * The suite itself is portable/core/tests/SPDFCoreMarkdownTests.c, written in
 * the shape of the other core suites so run-tests-native.sh can list it in
 * CORE_SUITES (one line, owned by the shell track -- see the Markdown track's
 * report). Until that line lands, this shim is how the suite runs here: the
 * harness discovers every *_test.c in this directory on its own, and the
 * include below makes the suite's main() this binary's main(). Same
 * arrangement as spdf_win_tabs_app.h -- one translation unit, no copy.
 *
 * Pure C: no MuPDF, so it links on a machine that has never built it.
 */
/* spdf-test-sources: portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c portable/core/spdf_markdown_fences.c ext/md4c/md4c.c */
#include "../../core/tests/SPDFCoreMarkdownTests.c"
