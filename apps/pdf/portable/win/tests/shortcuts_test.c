/* shortcuts_test.c — the F1 sheet is a FUNCTION OF THE MENU TABLE, and this
 * pins the function.
 *
 * What would go wrong without it, and is checked here:
 *   - a menu row with a printed accelerator that the sheet does not list, or
 *     lists twice (the sheet has exactly one row per drawn, keyed menu item);
 *   - a mnemonic or an ellipsis leaking into a title ("&Open..." must read
 *     "Open"), or a literal && losing its ampersand;
 *   - the accelerator-only spellings (Ctrl+Tab, the keypad keys) vanishing
 *     from the sheet or being listed as separate items;
 *   - the groups arriving out of menu order, or a group the menu does not have;
 *   - a Reading appendix row that names a key the table has since claimed as
 *     an accelerator, which would make the sheet lie about what the key does.
 *
 * Header-only under test, like menu_test.c: no window, no message pump.
 */
#include "spdf_win_shortcuts.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                      \
    do {                                                                                 \
        ++g_checks;                                                                      \
        if (!(cond)) {                                                                   \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);             \
            ++g_failures;                                                                \
        }                                                                                \
    } while (0)

static const SpdfWinShortcutRow* row_for(const SpdfWinShortcutRow* rows, int n, int command) {
    int i;
    for (i = 0; i < n; ++i)
        if (rows[i].command == command) return &rows[i];
    return NULL;
}

static void test_clean_title(void) {
    wchar_t out[64];
    CHECK(spdf_win_shortcuts_clean_title(L"&Open...", out, 64) == 4 && wcscmp(out, L"Open") == 0);
    CHECK(spdf_win_shortcuts_clean_title(L"Open in New &Tab...", out, 64) > 0 && wcscmp(out, L"Open in New Tab") == 0);
    CHECK(spdf_win_shortcuts_clean_title(L"Make &Default PDF Reader", out, 64) > 0 &&
          wcscmp(out, L"Make Default PDF Reader") == 0);
    CHECK(spdf_win_shortcuts_clean_title(L"Fish && Chips", out, 64) > 0 && wcscmp(out, L"Fish & Chips") == 0);
    CHECK(spdf_win_shortcuts_clean_title(L"&Go To", out, 64) == 5 && wcscmp(out, L"Go To") == 0);
    CHECK(spdf_win_shortcuts_clean_title(L"", out, 64) == 0 && out[0] == L'\0');
    CHECK(spdf_win_shortcuts_clean_title(NULL, out, 64) == 0 && out[0] == L'\0');
    CHECK(spdf_win_shortcuts_clean_title(L"&Open...", out, 3) == 2 && wcscmp(out, L"Op") == 0); /* truncates */
}

static void test_rows_follow_the_table(void) {
    SpdfWinShortcutRow rows[SPDF_WIN_SHORTCUT_MAX_ROWS];
    int n = spdf_win_shortcuts_build(rows, SPDF_WIN_SHORTCUT_MAX_ROWS);
    int table_n = 0;
    const SpdfWinMenuItem* table = spdf_win_menu_table(&table_n);
    int i, j, keyed = 0, last_menu = 0;
    size_t reading = sizeof(k_spdf_win_shortcuts_reading) / sizeof(k_spdf_win_shortcuts_reading[0]);

    CHECK(n > 0);
    /* Exactly one sheet row per drawn, keyed menu row, in menu order. */
    for (i = 0; i < table_n; ++i) {
        const SpdfWinMenuItem* it = &table[i];
        const SpdfWinShortcutRow* r;
        int seen = 0;
        if (it->menu == SPDF_WIN_MENU_NONE || it->command == SPDF_WIN_CMD_NONE || !it->accel) continue;
        ++keyed;
        for (j = 0; j < n; ++j)
            if (rows[j].command == it->command) ++seen;
        CHECK(seen == 1);
        r = row_for(rows, n, it->command);
        CHECK(r && r->group == spdf_win_menu_title(it->menu));
        CHECK(r && wcschr(r->title, L'&') == NULL);
        CHECK(r && r->title[wcslen(r->title) - 1] != L'.');
        CHECK(r && wcsncmp(r->accel, it->accel, wcslen(it->accel)) == 0); /* the printed accel comes first */
    }
    CHECK(n == keyed + (int)reading);
    /* Unkeyed items are not shortcuts. */
    CHECK(row_for(rows, n, SPDF_WIN_CMD_SAVE_PAGE_AS) == NULL);
    CHECK(row_for(rows, n, SPDF_WIN_CMD_ABOUT) == NULL);
    CHECK(row_for(rows, n, SPDF_WIN_CMD_SET_DEFAULT_READER) == NULL);
    /* Menu order: File, Go To, Zoom, View, Edit, then Reading. */
    for (i = 0; i < n; ++i) {
        int menu = 0;
        if (rows[i].command == SPDF_WIN_CMD_NONE) {
            CHECK(wcscmp(rows[i].group, L"Reading") == 0);
            CHECK(i >= keyed); /* the appendix comes last */
            continue;
        }
        for (menu = 1; menu < SPDF_WIN_MENU_COUNT; ++menu)
            if (spdf_win_menu_title(menu) == rows[i].group) break;
        CHECK(menu < SPDF_WIN_MENU_COUNT);
        CHECK(menu >= last_menu);
        last_menu = menu;
    }
}

static void test_alternate_spellings_fold_in(void) {
    SpdfWinShortcutRow rows[SPDF_WIN_SHORTCUT_MAX_ROWS];
    int n = spdf_win_shortcuts_build(rows, SPDF_WIN_SHORTCUT_MAX_ROWS);
    const SpdfWinShortcutRow* next_tab = row_for(rows, n, SPDF_WIN_CMD_NEXT_TAB);
    const SpdfWinShortcutRow* prev_tab = row_for(rows, n, SPDF_WIN_CMD_PREV_TAB);
    const SpdfWinShortcutRow* zoom_in = row_for(rows, n, SPDF_WIN_CMD_ZOOM_IN);
    const SpdfWinShortcutRow* zoom_out = row_for(rows, n, SPDF_WIN_CMD_ZOOM_OUT);
    const SpdfWinShortcutRow* find = row_for(rows, n, SPDF_WIN_CMD_FIND);

    CHECK(next_tab && wcscmp(next_tab->accel, L"Ctrl+PgDn or Ctrl+Tab") == 0);
    CHECK(prev_tab && wcscmp(prev_tab->accel, L"Ctrl+PgUp or Ctrl+Shift+Tab") == 0);
    /* Zoom In has THREE table rows: the drawn Ctrl++, the keypad Ctrl+Num +,
     * and Ctrl+Shift+= which IS Ctrl++ on a US layout and must not be listed
     * as a second spelling. */
    CHECK(zoom_in && wcscmp(zoom_in->accel, L"Ctrl++ or Ctrl+Num +") == 0);
    CHECK(zoom_out && wcscmp(zoom_out->accel, L"Ctrl+- or Ctrl+Num -") == 0);
    /* A command with one spelling has one spelling. */
    CHECK(find && wcscmp(find->accel, L"Ctrl+F") == 0);
    CHECK(wcscmp(rows[0].group, L"&File") == 0 && rows[0].command == SPDF_WIN_CMD_OPEN);
    {
        wchar_t group[32];
        spdf_win_shortcuts_group_name(&rows[0], group, 32);
        CHECK(wcscmp(group, L"File") == 0);
    }
}

static void test_reading_appendix_does_not_collide(void) {
    size_t i;
    for (i = 0; i < sizeof(k_spdf_win_shortcuts_reading) / sizeof(k_spdf_win_shortcuts_reading[0]); ++i) {
        const SpdfWinShortcutFixed* f = &k_spdf_win_shortcuts_reading[i];
        CHECK(f->title && *f->title && f->accel && *f->accel);
        if (!f->key) continue;
        /* If the table ever binds this key with these modifiers, the appendix
         * row lies about it and must go. */
        CHECK(spdf_win_menu_command_for_key(f->key, f->mods) == SPDF_WIN_CMD_NONE);
    }
}

static void test_capacity(void) {
    SpdfWinShortcutRow rows[4];
    CHECK(spdf_win_shortcuts_build(rows, 4) == 4);
    CHECK(spdf_win_shortcuts_build(rows, 0) == 0);
    CHECK(spdf_win_shortcuts_build(NULL, 4) == 0);
    CHECK(spdf_win_shortcuts_build(rows, 1) == 1 && rows[0].command == SPDF_WIN_CMD_OPEN);
}

int main(void) {
    test_clean_title();
    test_rows_follow_the_table();
    test_alternate_spellings_fold_in();
    test_reading_appendix_does_not_collide();
    test_capacity();
    printf("shortcuts_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
