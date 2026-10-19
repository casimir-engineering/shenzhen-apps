/* Pure-logic tests for spdf_translate.c (glib only, no GTK/core — the GTK
 * half is compiled out via SPDF_TRANSLATE_TESTING): the 19-language table,
 * output-filename derivation, whitespace collapsing, page-boundary batch
 * assembly with the Mac line budget, batch scope labels, and per-batch output
 * mapping (short output padded with " ", extra lines folded into the last
 * line — 78072bf55). */
#define SPDF_TRANSLATE_TESTING 1

#include "../spdf_translate.c"

static void test_language_table(void) {
    int count = 0;
    const SpdfTranslationLanguage* languages = spdf_translation_languages(&count);

    g_assert_cmpint(count, ==, 19);
    g_assert_cmpstr(languages[0].code, ==, "zh");
    g_assert_cmpstr(languages[0].name, ==, "Chinese (Simplified)");
    g_assert_cmpstr(languages[1].code, ==, "en");
    g_assert_cmpstr(languages[count - 1].code, ==, "cs");

    g_assert_cmpint(spdf_translation_language_index("zh"), ==, 0);
    g_assert_cmpint(spdf_translation_language_index("cs"), ==, 18);
    g_assert_cmpint(spdf_translation_language_index("xx"), ==, -1);
    g_assert_cmpint(spdf_translation_language_index(NULL), ==, -1);
}

static void test_output_filename(void) {
    char* english = spdf_translate_output_path("/docs/datasheet.pdf", "en");
    char* german = spdf_translate_output_path("/docs/datasheet.pdf", "de");
    char* fallback = spdf_translate_output_path("/docs/datasheet.pdf", NULL);
    char* no_ext = spdf_translate_output_path("/docs/datasheet", "fr");

    /* GTK3 translation_suffix_for_target_language: en → "english",
     * empty → "translated", anything else → the code itself. */
    g_assert_cmpstr(spdf_translate_suffix_for_language("en"), ==, "english");
    g_assert_cmpstr(spdf_translate_suffix_for_language(""), ==, "translated");
    g_assert_cmpstr(spdf_translate_suffix_for_language(NULL), ==, "translated");
    g_assert_cmpstr(spdf_translate_suffix_for_language("ja"), ==, "ja");

    g_assert_cmpstr(english, ==, "/docs/datasheet_english.pdf");
    g_assert_cmpstr(german, ==, "/docs/datasheet_de.pdf");
    g_assert_cmpstr(fallback, ==, "/docs/datasheet_translated.pdf");
    g_assert_cmpstr(no_ext, ==, "/docs/datasheet_fr.pdf");
    g_assert_null(spdf_translate_output_path(NULL, "en"));
    g_free(english);
    g_free(german);
    g_free(fallback);
    g_free(no_ext);
}

static void test_temp_path(void) {
    char* tmp = spdf_translate_temp_path("/docs/a.pdf", 77);
    g_assert_cmpstr(tmp, ==, "/docs/.a.pdf.translate-77.pdf");
    g_free(tmp);
}

static void test_collapse_whitespace(void) {
    char* collapsed = spdf_translate_collapse_whitespace("  Chapter\t1:\n\n  Overview \r\n");
    char* untouched = spdf_translate_collapse_whitespace("already clean");
    char* empty = spdf_translate_collapse_whitespace("   \n\t ");
    char* null_text = spdf_translate_collapse_whitespace(NULL);

    g_assert_cmpstr(collapsed, ==, "Chapter 1: Overview");
    g_assert_cmpstr(untouched, ==, "already clean");
    g_assert_cmpstr(empty, ==, "");
    g_assert_cmpstr(null_text, ==, "");
    g_free(collapsed);
    g_free(untouched);
    g_free(empty);
    g_free(null_text);
}

/* items helper: n entries of {kind, page} pairs. */
static void fill_items(SpdfTranslateBatchItem* items, const int* kinds, const int* pages, int count) {
    for (int i = 0; i < count; ++i) {
        items[i].kind = kinds[i];
        items[i].page = pages[i];
    }
}

static void test_batch_end(void) {
    /* Three pages of 2/3/2 lines, budget 5: pages 0+1 batch together (5
     * lines), page 2 forms the next batch. */
    SpdfTranslateBatchItem items[7];
    const int kinds[7] = {0, 0, 0, 0, 0, 0, 0};
    const int pages[7] = {0, 0, 1, 1, 1, 2, 2};

    fill_items(items, kinds, pages, 7);
    g_assert_cmpint(spdf_translate_batch_end(items, 7, 0, 5), ==, 5);
    g_assert_cmpint(spdf_translate_batch_end(items, 7, 5, 5), ==, 7);

    /* A single page larger than the budget still forms one whole batch
     * (batches end on page boundaries; Mac batching). */
    {
        SpdfTranslateBatchItem big[4];
        const int one_kinds[4] = {0, 0, 0, 0};
        const int one_pages[4] = {3, 3, 3, 3};
        fill_items(big, one_kinds, one_pages, 4);
        g_assert_cmpint(spdf_translate_batch_end(big, 4, 0, 2), ==, 4);
    }

    /* Degenerate inputs. */
    g_assert_cmpint(spdf_translate_batch_end(NULL, 7, 0, 5), ==, 7);
    g_assert_cmpint(spdf_translate_batch_end(items, 7, 7, 5), ==, 7);
}

static void test_batch_scope(void) {
    /* Body pages only. */
    SpdfTranslateBatchItem items[6];
    const int kinds[6] = {0, 0, 0, 1, 1, 2};
    const int pages[6] = {2, 3, 4, 10, 10, 11};
    char* scope;

    fill_items(items, kinds, pages, 6);
    scope = spdf_translate_batch_scope(items, 6, 0, 1);
    g_assert_cmpstr(scope, ==, "page 3");
    g_free(scope);

    scope = spdf_translate_batch_scope(items, 6, 0, 3);
    g_assert_cmpstr(scope, ==, "pages 3-5");
    g_free(scope);

    /* Chapters only, comments only, and combinations (78072bf55 labels). */
    scope = spdf_translate_batch_scope(items, 6, 3, 5);
    g_assert_cmpstr(scope, ==, "chapter titles");
    g_free(scope);

    scope = spdf_translate_batch_scope(items, 6, 5, 6);
    g_assert_cmpstr(scope, ==, "comments");
    g_free(scope);

    scope = spdf_translate_batch_scope(items, 6, 3, 6);
    g_assert_cmpstr(scope, ==, "chapters and comments");
    g_free(scope);

    scope = spdf_translate_batch_scope(items, 6, 2, 6);
    g_assert_cmpstr(scope, ==, "page 5 and chapters and comments");
    g_free(scope);

    /* Empty range falls back to "text". */
    scope = spdf_translate_batch_scope(items, 6, 0, 0);
    g_assert_cmpstr(scope, ==, "text");
    g_free(scope);
}

static void test_apply_batch_output(void) {
    char* result[4] = {NULL, NULL, NULL, NULL};

    /* One-to-one mapping. */
    spdf_translate_apply_batch_output(result, 0, 3, "one\ntwo\nthree");
    g_assert_cmpstr(result[0], ==, "one");
    g_assert_cmpstr(result[1], ==, "two");
    g_assert_cmpstr(result[2], ==, "three");
    g_assert_null(result[3]);

    /* Short output: missing/empty lines become " " so overlays stay aligned. */
    spdf_translate_apply_batch_output(result, 0, 3, "only\n\n");
    g_assert_cmpstr(result[0], ==, "only");
    g_assert_cmpstr(result[1], ==, " ");
    g_assert_cmpstr(result[2], ==, " ");

    /* Extra output lines fold into the batch's last line, space-joined and
     * newline-free (78072bf55). */
    spdf_translate_apply_batch_output(result, 1, 3, "a\nb\nextra1\nextra2");
    g_assert_cmpstr(result[1], ==, "a");
    g_assert_cmpstr(result[2], ==, "b extra1 extra2");

    for (int i = 0; i < 4; ++i) g_free(result[i]);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/translate/language_table", test_language_table);
    g_test_add_func("/translate/output_filename", test_output_filename);
    g_test_add_func("/translate/temp_path", test_temp_path);
    g_test_add_func("/translate/collapse_whitespace", test_collapse_whitespace);
    g_test_add_func("/translate/batch_end", test_batch_end);
    g_test_add_func("/translate/batch_scope", test_batch_scope);
    g_test_add_func("/translate/apply_batch_output", test_apply_batch_output);
    return g_test_run();
}
