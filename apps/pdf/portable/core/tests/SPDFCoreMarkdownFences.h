/* SPDFCoreMarkdownFences.h -- the four-fence fixture both Markdown suites use.
 *
 * SPDFCoreMarkdownTests.c checks what the converter EMITS for these four
 * fences; SPDFCoreMarkdownCodeTests.c checks what spdf_markdown_scan_fences()
 * SEES in the same four, and that the ordinals agree. The agreement is the
 * whole basis of the in-page code controls, so the two suites have to be
 * looking at the same document -- which is what this header guarantees, rather
 * than two copies of a string literal that could drift apart.
 *
 * Fence 0 is a known language, 1 an unknown one, 2 a diagram fence, 3 bare.
 */
#ifndef SPDF_CORE_MARKDOWN_FENCES_H
#define SPDF_CORE_MARKDOWN_FENCES_H

#define SPDF_MD_TEST_FOUR_FENCES                                      \
    "```c\nint x = 0; // hi\n```\n\n"                                 \
    "```nosuchlang\nint y;\n```\n\n"                                  \
    "```mermaid\ngraph TD\n```\n\n"                                   \
    "```\nplain <b>\n```\n"

#endif /* SPDF_CORE_MARKDOWN_FENCES_H */
