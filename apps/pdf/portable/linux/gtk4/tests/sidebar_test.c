/* Pure sidebar-logic tests (spdf_sidebar_internal.h). glib-only; build via
 * `make -C portable linux-gtk4-tests`.
 *
 * Covers: outline level normalization + tree edges (child_count/child_at)
 * with a pre-order flatten round-trip (the GtkTreeListModel row order must
 * equal the outline's document order), current-chapter attribution for a
 * page (Mac chapterTitleForPage), chapter-grouping of streamed search
 * matches (Mac rebuildSearchSidebarItems divider rule, incl. the append-only
 * batching invariant), divider titles, and the Pango snippet markup with the
 * query bolded. */

#include <glib.h>

#include "spdf_sidebar_internal.h"

/* ---------------------------------------------------------------------- */

static void test_normalize_levels(void) {
    /* First item is forced to the root level; jumps deeper than one level
     * are pulled up; negatives clamp to 0; descents are kept as-is. */
    int levels[] = {2, 3, 1, 5, 2, -1, 1};
    const int expected[] = {0, 1, 1, 2, 2, 0, 1};

    spdf_sidebar_outline_normalize_levels(levels, G_N_ELEMENTS(levels));
    for (gsize i = 0; i < G_N_ELEMENTS(levels); ++i) g_assert_cmpint(levels[i], ==, expected[i]);

    spdf_sidebar_outline_normalize_levels(NULL, 3); /* no crash */
    spdf_sidebar_outline_normalize_levels(levels, 0);
}

/* Recursive pre-order walk over the child accessors. */
static void flatten_walk(const int* levels, int count, int parent, GArray* out) {
    int children = spdf_sidebar_outline_child_count(levels, count, parent);
    for (int nth = 0; nth < children; ++nth) {
        int child = spdf_sidebar_outline_child_at(levels, count, parent, nth);
        g_assert_cmpint(child, >=, 0);
        g_array_append_val(out, child);
        flatten_walk(levels, count, child, out);
    }
}

static void assert_flatten_roundtrip(int* levels, int count) {
    GArray* order = g_array_new(FALSE, FALSE, sizeof(int));

    spdf_sidebar_outline_normalize_levels(levels, count);
    flatten_walk(levels, count, -1, order);
    g_assert_cmpuint(order->len, ==, (guint)count); /* every node exactly once... */
    for (int i = 0; i < count; ++i) g_assert_cmpint(g_array_index(order, int, i), ==, i); /* ...in document order */
    g_array_free(order, TRUE);
}

static void test_outline_tree_flattening(void) {
    /* Well-formed outline: 2 roots, nested subsections. */
    int simple[] = {0, 1, 1, 2, 1, 0, 1};
    /* Malformed: starts deep, skips levels both ways. */
    int messy[] = {3, 0, 4, 4, 9, 1, 0, 2, 2, 1};
    /* Flat outline (no nesting at all). */
    int flat[] = {0, 0, 0, 0};
    /* Strictly descending chain. */
    int chain[] = {0, 1, 2, 3, 4};

    assert_flatten_roundtrip(simple, G_N_ELEMENTS(simple));
    assert_flatten_roundtrip(messy, G_N_ELEMENTS(messy));
    assert_flatten_roundtrip(flat, G_N_ELEMENTS(flat));
    assert_flatten_roundtrip(chain, G_N_ELEMENTS(chain));

    /* Spot-check the edges on the simple shape after normalization. */
    spdf_sidebar_outline_normalize_levels(simple, G_N_ELEMENTS(simple));
    g_assert_cmpint(spdf_sidebar_outline_child_count(simple, G_N_ELEMENTS(simple), -1), ==, 2); /* roots 0, 5 */
    g_assert_cmpint(spdf_sidebar_outline_child_at(simple, G_N_ELEMENTS(simple), -1, 1), ==, 5);
    g_assert_cmpint(spdf_sidebar_outline_child_count(simple, G_N_ELEMENTS(simple), 0), ==, 3); /* 1, 2, 4 */
    g_assert_cmpint(spdf_sidebar_outline_child_at(simple, G_N_ELEMENTS(simple), 0, 2), ==, 4);
    g_assert_cmpint(spdf_sidebar_outline_child_count(simple, G_N_ELEMENTS(simple), 2), ==, 1); /* 3 */
    g_assert_cmpint(spdf_sidebar_outline_child_at(simple, G_N_ELEMENTS(simple), 2, 0), ==, 3);
    g_assert_cmpint(spdf_sidebar_outline_child_count(simple, G_N_ELEMENTS(simple), 3), ==, 0);
    g_assert_cmpint(spdf_sidebar_outline_child_at(simple, G_N_ELEMENTS(simple), 0, 3), ==, -1); /* out of range */

    g_assert_cmpint(spdf_sidebar_outline_child_count(NULL, 4, -1), ==, 0);
}

static void test_index_for_page(void) {
    /* pages/levels in pre-order (Mac chapterTitleForPage semantics). */
    const int pages[] = {2, 2, 5, 9, 9};
    const int levels[] = {0, 1, 1, 0, 1};

    g_assert_cmpint(spdf_sidebar_outline_index_for_page(pages, levels, 5, 0), ==, -1); /* before first chapter */
    g_assert_cmpint(spdf_sidebar_outline_index_for_page(pages, levels, 5, 2), ==, 1);  /* same-page tie: deeper wins */
    g_assert_cmpint(spdf_sidebar_outline_index_for_page(pages, levels, 5, 4), ==, 1);  /* carried over */
    g_assert_cmpint(spdf_sidebar_outline_index_for_page(pages, levels, 5, 5), ==, 2);
    g_assert_cmpint(spdf_sidebar_outline_index_for_page(pages, levels, 5, 7), ==, 2);
    g_assert_cmpint(spdf_sidebar_outline_index_for_page(pages, levels, 5, 100), ==, 4);
    g_assert_cmpint(spdf_sidebar_outline_index_for_page(pages, levels, 0, 3), ==, -1); /* empty outline */
    g_assert_cmpint(spdf_sidebar_outline_index_for_page(NULL, NULL, 5, 3), ==, -1);

    /* Entries with page -1 (no destination) never win. */
    {
        const int p2[] = {-1, 3};
        const int l2[] = {0, 1};
        g_assert_cmpint(spdf_sidebar_outline_index_for_page(p2, l2, 2, 1), ==, -1);
        g_assert_cmpint(spdf_sidebar_outline_index_for_page(p2, l2, 2, 4), ==, 1);
    }

    /* Same page, same level: the later entry in document order wins (Mac
     * keeps iterating on >=). */
    {
        const int p3[] = {4, 4};
        const int l3[] = {1, 1};
        g_assert_cmpint(spdf_sidebar_outline_index_for_page(p3, l3, 2, 6), ==, 1);
    }
}

/* ---------------------------------------------------------------------- */

static void assert_row(GArray* rows, guint i, gboolean is_header, int value) {
    const SpdfSidebarGroupRow* row;
    g_assert_cmpuint(rows->len, >, i);
    row = &g_array_index(rows, SpdfSidebarGroupRow, i);
    g_assert_cmpint(row->is_header, ==, is_header);
    g_assert_cmpint(row->value, ==, value);
}

static void test_search_grouping(void) {
    GArray* rows = g_array_new(FALSE, FALSE, sizeof(SpdfSidebarGroupRow));
    int prev = SPDF_SIDEBAR_NO_CHAPTER;
    /* Matches in document order with their chapter attribution: one before
     * the first chapter, three in chapter 0, one back-reference to chapter 0
     * after chapter 2 (repeated title case), two in chapter 2. */
    const int chapters[] = {-1, 0, 0, 0, 2, 2, 0};

    for (int i = 0; i < (int)G_N_ELEMENTS(chapters); ++i)
        spdf_sidebar_group_append(rows, &prev, chapters[i], TRUE, i);

    g_assert_cmpuint(rows->len, ==, G_N_ELEMENTS(chapters) + 4); /* 4 dividers */
    assert_row(rows, 0, TRUE, -1); /* "Document" divider before the first chapter */
    assert_row(rows, 1, FALSE, 0);
    assert_row(rows, 2, TRUE, 0);
    assert_row(rows, 3, FALSE, 1);
    assert_row(rows, 4, FALSE, 2);
    assert_row(rows, 5, FALSE, 3);
    assert_row(rows, 6, TRUE, 2);
    assert_row(rows, 7, FALSE, 4);
    assert_row(rows, 8, FALSE, 5);
    assert_row(rows, 9, TRUE, 0); /* chapter 0 re-entered: divider repeats */
    assert_row(rows, 10, FALSE, 6);

    /* Append-only batching invariant: feeding the same sequence in two
     * batches through the same prev state yields the same rows. */
    {
        GArray* batched = g_array_new(FALSE, FALSE, sizeof(SpdfSidebarGroupRow));
        int prev2 = SPDF_SIDEBAR_NO_CHAPTER;
        for (int i = 0; i < 3; ++i) spdf_sidebar_group_append(batched, &prev2, chapters[i], TRUE, i);
        for (int i = 3; i < (int)G_N_ELEMENTS(chapters); ++i)
            spdf_sidebar_group_append(batched, &prev2, chapters[i], TRUE, i);
        g_assert_cmpuint(batched->len, ==, rows->len);
        for (guint i = 0; i < rows->len; ++i) {
            const SpdfSidebarGroupRow* a = &g_array_index(rows, SpdfSidebarGroupRow, i);
            const SpdfSidebarGroupRow* b = &g_array_index(batched, SpdfSidebarGroupRow, i);
            g_assert_cmpint(a->is_header, ==, b->is_header);
            g_assert_cmpint(a->value, ==, b->value);
        }
        g_array_free(batched, TRUE);
    }
    g_array_free(rows, TRUE);

    /* No outline: never any dividers (Mac chapterTitleForMatchOnPage returns
     * "" without an outline, so no findDivider rows are added). */
    rows = g_array_new(FALSE, FALSE, sizeof(SpdfSidebarGroupRow));
    prev = SPDF_SIDEBAR_NO_CHAPTER;
    for (int i = 0; i < 4; ++i) spdf_sidebar_group_append(rows, &prev, -1, FALSE, i);
    g_assert_cmpuint(rows->len, ==, 4);
    for (guint i = 0; i < rows->len; ++i) assert_row(rows, i, FALSE, (int)i);
    g_array_free(rows, TRUE);
}

static void test_chapter_title(void) {
    const char* titles[] = {"Intro", "", NULL};

    g_assert_cmpstr(spdf_sidebar_chapter_title(titles, 3, 0), ==, "Intro");
    g_assert_cmpstr(spdf_sidebar_chapter_title(titles, 3, 1), ==, "Untitled");
    g_assert_cmpstr(spdf_sidebar_chapter_title(titles, 3, 2), ==, "Untitled");
    g_assert_cmpstr(spdf_sidebar_chapter_title(titles, 3, -1), ==, "Document"); /* before first chapter */
    g_assert_cmpstr(spdf_sidebar_chapter_title(titles, 3, 7), ==, "Document");  /* out of range */
    g_assert_cmpstr(spdf_sidebar_chapter_title(titles, 0, 0), ==, "");          /* no outline: no divider */
    g_assert_cmpstr(spdf_sidebar_chapter_title(NULL, 3, 0), ==, "Document");
}

/* ---------------------------------------------------------------------- */

static void expect_markup(const char* snippet, const char* query, const char* expected) {
    char* markup = spdf_sidebar_snippet_markup(snippet, query);
    g_assert_cmpstr(markup, ==, expected);
    g_free(markup);
}

static void test_snippet_markup(void) {
    /* First case-insensitive occurrence is bolded. */
    expect_markup("USB routing on the camera flex", "usb", "<b>USB</b> routing on the camera flex");
    expect_markup("impedance and Impedance", "impedance", "<b>impedance</b> and Impedance");
    /* Escaping applies everywhere, including inside the bold run. */
    expect_markup("a < b & c", "b & c", "a &lt; <b>b &amp; c</b>");
    expect_markup("R12 <10k> pull-up", "<10k>", "R12 <b>&lt;10k&gt;</b> pull-up");
    /* Query missing (e.g. a regex pattern): plain escaped snippet. */
    expect_markup("no match here", "absent", "no match here");
    expect_markup("a < b", "x.*y", "a &lt; b");
    /* Empty/NULL inputs degrade to the escaped snippet. */
    expect_markup("plain", "", "plain");
    expect_markup("plain", NULL, "plain");
    expect_markup("", "q", "");
    expect_markup(NULL, "q", "");
    /* Multi-byte snippet text before the match keeps byte offsets straight. */
    expect_markup("深圳 pdf viewer", "PDF", "深圳 <b>pdf</b> viewer");
    /* Query longer than the snippet: no bolding, no crash. */
    expect_markup("ab", "abc", "ab");
}

static void expect_window(const char* line, const char* query, const char* expected) {
    char* window = spdf_sidebar_snippet_window(line, query);
    g_assert_cmpstr(window, ==, expected);
    g_free(window);
}

/* Port of Mac paletteSnippetRangeInLine: 2 words before the match through 2
 * words after — the sidebar result rows must NOT show the whole line (line
 * numbers / leading labels get cut away). */
static void test_snippet_window(void) {
    /* Match in the middle: 2 words kept each side. */
    expect_window("Line 12: the quick brown fox inspects connector J12 on page 3", "brown",
                  "the quick brown fox inspects");
    /* Case-insensitive match. */
    expect_window("Line 12: the quick BROWN fox inspects connector J12", "brown", "the quick BROWN fox inspects");
    /* Match near the start: window clamps at the line head. */
    expect_window("the quick brown fox", "the", "the quick brown");
    /* Match near the end: window clamps at the line tail. */
    expect_window("the quick brown fox", "fox", "quick brown fox");
    /* Multi-word query spans words; the window wraps the whole span. */
    expect_window("one two three four five six seven eight", "four five", "two three four five six seven");
    /* Query not literally present (regex): the whole (trimmed) line stays. */
    expect_window("  the whole line stays  ", "f.x", "the whole line stays");
    /* Multi-byte text around the match. */
    expect_window("深圳 阻抗 pdf viewer 大 好", "pdf", "深圳 阻抗 pdf viewer 大");
    /* Degenerate inputs. */
    expect_window("", "q", "");
    expect_window(NULL, "q", "");
    expect_window("plain", "", "plain");
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/sidebar/outline/normalize-levels", test_normalize_levels);
    g_test_add_func("/sidebar/outline/tree-flattening", test_outline_tree_flattening);
    g_test_add_func("/sidebar/outline/index-for-page", test_index_for_page);
    g_test_add_func("/sidebar/search/grouping", test_search_grouping);
    g_test_add_func("/sidebar/search/chapter-title", test_chapter_title);
    g_test_add_func("/sidebar/search/snippet-markup", test_snippet_markup);
    g_test_add_func("/sidebar/search/snippet-window", test_snippet_window);
    return g_test_run();
}
