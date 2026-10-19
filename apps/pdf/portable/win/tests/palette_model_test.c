/* palette_model_test.c — spdf_win_palette_model.{h,c}: what Ctrl+K shows for a
 * query, with no window.
 *
 * The rows come from three places -- the menu table, the favorites store and
 * the recents store -- and the tests here fill the two stores through their own
 * APIs in a scratch state directory (never %APPDATA%\ShenzhenPDF) and hand the
 * model a fake tab list. What is pinned: the section order (mac
 * refreshPaletteResults), the selected tab's exclusion, the '>' commands-only
 * prefix, the "fav" keyword, the shadowing of an open document's document
 * favorite, hidden disabled commands, the check mark on a toggled command, the
 * accelerator text coming from the same table row as the menu, and the
 * selection's movement over status rows.
 */
/* spdf-test-sources: portable/win/src/spdf_win_palette_model.c portable/win/src/spdf_win_recents.c portable/win/src/spdf_win_favorites.c portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/win/src/spdf_win_watcher.cpp portable/win/src/spdf_win_watcher_shadow.cpp portable/core/spdf_yaml.c portable/core/spdf_win_compat.c */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif

#include "spdf_win_favorites.h"
#include "spdf_win_palette_model.h"
#include "spdf_win_paths.h"
#include "spdf_win_recents.h"
#include "spdf_win_state.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_STR(got, want)                                                                                           \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(got) || strcmp((got), (want)) != 0) {                                                                    \
            printf("FAIL %s:%d: \"%s\" != \"%s\"\n", __FILE__, __LINE__, (got) ? (got) : "(null)", (want));            \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static const SpdfWinPaletteOpenDoc k_docs[] = {
    {"C:\\docs\\Manual.pdf", "Manual"},
    {"C:\\docs\\Sheet.pdf", "Sheet"},
    {"C:\\other\\Notes.pdf", "Notes"},
};

static int count_kind(const SpdfWinPaletteModel* m, int kind) {
    int i, n = 0;
    for (i = 0; i < spdf_win_palette_model_row_count(m); ++i)
        if (spdf_win_palette_model_row(m, i)->kind == kind) n++;
    return n;
}

static int first_of_kind(const SpdfWinPaletteModel* m, int kind) {
    int i;
    for (i = 0; i < spdf_win_palette_model_row_count(m); ++i)
        if (spdf_win_palette_model_row(m, i)->kind == kind) return i;
    return -1;
}

static int has_command(const SpdfWinPaletteModel* m, int command) {
    int i;
    for (i = 0; i < spdf_win_palette_model_row_count(m); ++i) {
        const SpdfWinPaletteRow* r = spdf_win_palette_model_row(m, i);
        if (r->kind == SPDF_WIN_PALETTE_ROW_COMMAND && r->command == command) return 1;
    }
    return 0;
}

static void test_menu_text(void) {
    char out[64];
    CHECK(spdf_win_palette_menu_text(L"&Open...", out, sizeof(out)));
    CHECK_STR(out, "Open...");
    CHECK(spdf_win_palette_menu_text(L"Save && &Quit", out, sizeof(out)));
    CHECK_STR(out, "Save & Quit");
    CHECK(spdf_win_palette_menu_text(NULL, out, sizeof(out)));
    CHECK_STR(out, "");
}

static void test_empty_query_lists_everything_in_section_order(void) {
    SpdfWinPaletteModel* m = spdf_win_palette_model_create();
    int i, last_section = -1, headers = 0, n;
    CHECK(m != NULL);
    spdf_win_palette_model_set_documents(m, k_docs, 3, 0);
    spdf_win_palette_model_set_query(m, "");
    n = spdf_win_palette_model_row_count(m);
    /* Two open documents (the selected one is left out), every menu command
     * but the palette itself and the Open Recent anchor, the favorites and
     * the recents. */
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_OPEN_DOC) == 2);
    /* Two of the three favorites: Notes is open and listed, so its DOCUMENT
     * favorite is shadowed; Manual is selected (not listed), so both of its
     * favorites show. */
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_FAVORITE) == 2);
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_RECENT) == 2);
    CHECK(!has_command(m, SPDF_WIN_CMD_PALETTE));
    CHECK(!has_command(m, SPDF_WIN_CMD_OPEN_RECENT));
    CHECK(has_command(m, SPDF_WIN_CMD_OPEN));
    CHECK(has_command(m, SPDF_WIN_CMD_ZOOM_IN));
    for (i = 0; i < n; ++i) {
        const SpdfWinPaletteRow* r = spdf_win_palette_model_row(m, i);
        CHECK(r->section >= last_section);
        if (spdf_win_palette_model_section_starts(m, i)) headers++;
        last_section = r->section;
    }
    CHECK(headers == 4);
    CHECK(spdf_win_palette_model_section_starts(m, 0));
    CHECK_STR(spdf_win_palette_model_row(m, 0)->title, "Sheet");
    CHECK(spdf_win_palette_model_row(m, 0)->doc == 1);
    CHECK_STR(spdf_win_palette_model_row(m, 1)->title, "Notes");
    /* No state given: everything enabled, nothing ticked. */
    CHECK(has_command(m, SPDF_WIN_CMD_PRINT));
    /* The accelerator and title come from the menu row. */
    for (i = 0; i < n; ++i) {
        const SpdfWinPaletteRow* r = spdf_win_palette_model_row(m, i);
        if (r->kind == SPDF_WIN_PALETTE_ROW_COMMAND && r->command == SPDF_WIN_CMD_OPEN) {
            CHECK_STR(r->title, "Open...");
            CHECK_STR(r->accel, "Ctrl+O");
            CHECK_STR(r->subtitle, "File \xE2\x96\xB8 Open...");
        }
    }
    CHECK(spdf_win_palette_model_selected(m) == 0);
    spdf_win_palette_model_destroy(m);
}

static void test_commands_only_prefix(void) {
    SpdfWinPaletteModel* m = spdf_win_palette_model_create();
    spdf_win_palette_model_set_documents(m, k_docs, 3, 0);
    spdf_win_palette_model_set_query(m, ">");
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_OPEN_DOC) == 0);
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_FAVORITE) == 0);
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_RECENT) == 0);
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_COMMAND) > 10);
    spdf_win_palette_model_set_query(m, ">  zoom in");
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_COMMAND) >= 1);
    CHECK(spdf_win_palette_model_row(m, 0)->command == SPDF_WIN_CMD_ZOOM_IN);
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_OPEN_DOC) == 0);
    spdf_win_palette_model_set_query(m, "> nothing matches this");
    CHECK(spdf_win_palette_model_row_count(m) == 1);
    CHECK(spdf_win_palette_model_row(m, 0)->kind == SPDF_WIN_PALETTE_ROW_STATUS);
    CHECK(spdf_win_palette_model_selected(m) == -1);
    CHECK(!spdf_win_palette_model_section_starts(m, 0));
    spdf_win_palette_model_destroy(m);
}

static void test_menu_state_hides_disabled_and_ticks_toggled(void) {
    SpdfWinPaletteModel* m = spdf_win_palette_model_create();
    SpdfWinMenuState st;
    int i;
    memset(&st, 0, sizeof(st));
    st.has_document = 0;
    st.sidebar_visible = 1;
    spdf_win_palette_model_set_menu_state(m, &st);
    spdf_win_palette_model_set_query(m, ">");
    CHECK(!has_command(m, SPDF_WIN_CMD_PRINT));     /* needs a document */
    CHECK(!has_command(m, SPDF_WIN_CMD_ZOOM_IN));
    CHECK(has_command(m, SPDF_WIN_CMD_OPEN));       /* the way out of the empty state */
    CHECK(has_command(m, SPDF_WIN_CMD_TOGGLE_SIDEBAR));
    for (i = 0; i < spdf_win_palette_model_row_count(m); ++i) {
        const SpdfWinPaletteRow* r = spdf_win_palette_model_row(m, i);
        if (r->command == SPDF_WIN_CMD_TOGGLE_SIDEBAR) CHECK(r->toggled);
        if (r->command == SPDF_WIN_CMD_TOGGLE_MINIMAP) CHECK(!r->toggled);
        if (r->command == SPDF_WIN_CMD_OPEN) CHECK(!r->toggled);
    }
    spdf_win_palette_model_destroy(m);
}

static void test_favorites_shadowing_and_fav_keyword(void) {
    SpdfWinPaletteModel* m = spdf_win_palette_model_create();
    int i, fav;
    spdf_win_palette_model_set_documents(m, k_docs, 3, 2); /* Notes selected; Manual and Sheet listed */
    spdf_win_palette_model_set_query(m, "");
    /* The document favorite of Manual (open, listed) is shadowed; its page
     * favorite and the Notes document favorite stay (Notes is selected, hence
     * NOT in the open section, hence not shadowed). */
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_FAVORITE) == 2);
    for (i = 0; i < spdf_win_palette_model_row_count(m); ++i) {
        const SpdfWinPaletteRow* r = spdf_win_palette_model_row(m, i);
        if (r->kind != SPDF_WIN_PALETTE_ROW_FAVORITE) continue;
        CHECK(!(r->page == -1 && strcmp(r->path, "C:\\docs\\Manual.pdf") == 0));
    }
    /* "fav" reveals all three, unfiltered and unshadowed. */
    spdf_win_palette_model_set_query(m, "fav");
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_FAVORITE) == 3);
    /* A page favorite row carries its target page and a "p.N · path" subtitle. */
    fav = first_of_kind(m, SPDF_WIN_PALETTE_ROW_FAVORITE);
    CHECK(fav >= 0);
    for (i = fav; i < spdf_win_palette_model_row_count(m); ++i) {
        const SpdfWinPaletteRow* r = spdf_win_palette_model_row(m, i);
        if (r->kind == SPDF_WIN_PALETTE_ROW_FAVORITE && r->page == 4) {
            CHECK_STR(r->title, "Manual p.5");
            CHECK_STR(r->subtitle, "p.5 \xC2\xB7 C:\\docs\\Manual.pdf");
        }
    }
    /* A query matches a favorite by name, title, path or label. */
    spdf_win_palette_model_set_query(m, "hardware");
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_FAVORITE) == 1);
    CHECK_STR(spdf_win_palette_model_row(m, first_of_kind(m, SPDF_WIN_PALETTE_ROW_FAVORITE))->path, "C:\\other\\Notes.pdf");
    spdf_win_palette_model_destroy(m);
}

static void test_recents_and_open_docs_filter(void) {
    SpdfWinPaletteModel* m = spdf_win_palette_model_create();
    spdf_win_palette_model_set_documents(m, k_docs, 3, -1);
    spdf_win_palette_model_set_query(m, "sheet");
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_OPEN_DOC) == 1);
    CHECK_STR(spdf_win_palette_model_row(m, 0)->title, "Sheet");
    CHECK(spdf_win_palette_model_row(m, 0)->doc == 1);
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_RECENT) == 1); /* C:\recent\Sheet-old.pdf */
    spdf_win_palette_model_set_query(m, "old");
    CHECK(count_kind(m, SPDF_WIN_PALETTE_ROW_RECENT) == 1);
    {
        const SpdfWinPaletteRow* r = spdf_win_palette_model_row(m, first_of_kind(m, SPDF_WIN_PALETTE_ROW_RECENT));
        CHECK_STR(r->title, "Sheet-old.pdf");
        CHECK_STR(r->subtitle, "C:\\recent\\Sheet-old.pdf");
    }
    spdf_win_palette_model_destroy(m);
}

static void test_selection_moves_over_status_and_clamps(void) {
    SpdfWinPaletteModel* m = spdf_win_palette_model_create();
    int n;
    spdf_win_palette_model_set_documents(m, k_docs, 3, 0);
    spdf_win_palette_model_set_query(m, "");
    n = spdf_win_palette_model_row_count(m);
    CHECK(spdf_win_palette_model_selected(m) == 0);
    spdf_win_palette_model_move(m, -1);
    CHECK(spdf_win_palette_model_selected(m) == 0); /* stops at the top */
    spdf_win_palette_model_move(m, 1);
    CHECK(spdf_win_palette_model_selected(m) == 1);
    spdf_win_palette_model_select(m, n - 1);
    CHECK(spdf_win_palette_model_selected(m) == n - 1);
    spdf_win_palette_model_move(m, 1);
    CHECK(spdf_win_palette_model_selected(m) == n - 1); /* and at the bottom */
    spdf_win_palette_model_select(m, 99999);
    CHECK(spdf_win_palette_model_selected(m) == n - 1);
    spdf_win_palette_model_set_query(m, "> zzzz no such command");
    CHECK(spdf_win_palette_model_selected(m) == -1);
    spdf_win_palette_model_move(m, 1);
    CHECK(spdf_win_palette_model_selected(m) == -1); /* a status row is never selected */
    spdf_win_palette_model_select(m, 0);
    CHECK(spdf_win_palette_model_selected(m) == -1);
    spdf_win_palette_model_destroy(m);
    spdf_win_palette_model_destroy(NULL);
}

int main(int argc, char** argv) {
    char scratch[SPDF_WIN_PATH_MAX], dir[SPDF_WIN_PATH_MAX];
    const char* base = argc > 1 ? argv[1] : NULL;
    if (!base || !*base) base = getenv("TEMP");
    if (!base || !*base) base = getenv("TMPDIR");
    if (!base || !*base) base = ".";
    if (!spdf_win_path_join(base, "spdf_palette_model_test", scratch, sizeof(scratch))) return 1;
    if (!spdf_win_path_join(scratch, "state", dir, sizeof(dir))) return 1;
    if (!spdf_win_paths_ensure_dir(dir)) return 1;
    spdf_win_paths_set_state_dir_override(dir);
    spdf_win_state_write_json(SPDF_WIN_STATE_DOCUMENTS, "{}");
    spdf_win_state_write_json(SPDF_WIN_STATE_FAVORITES, "[]");
    spdf_win_state_write_json(SPDF_WIN_STATE_SETTINGS, "{}");
    spdf_win_recents_reset();
    spdf_win_favorites_reset();

    /* The stores: two recents, three favorites (a page and a document favorite
     * of the open Manual, and a labelled document favorite of Notes). */
    spdf_win_recents_note_opened("C:\\recent\\Sheet-old.pdf", NULL);
    spdf_win_recents_note_opened("C:\\recent\\Paper.pdf", "Paper");
    CHECK(spdf_win_favorites_toggle_page("C:\\docs\\Manual.pdf", "Manual", 4) == 1);
    CHECK(spdf_win_favorites_toggle_document("C:\\docs\\Manual.pdf", "Manual") == 1);
    {
        SpdfWinFavorite f;
        memset(&f, 0, sizeof(f));
        strcpy(f.type, "document");
        strcpy(f.path, "C:\\other\\Notes.pdf");
        strcpy(f.title, "Notes");
        strcpy(f.name, "Notes");
        strcpy(f.labels, "[\"hardware\"]");
        CHECK(spdf_win_favorites_add(&f) >= 0);
    }

    test_menu_text();
    test_empty_query_lists_everything_in_section_order();
    test_commands_only_prefix();
    test_menu_state_hides_disabled_and_ticks_toggled();
    test_favorites_shadowing_and_fav_keyword();
    test_recents_and_open_docs_filter();
    test_selection_moves_over_status_and_clamps();

    spdf_win_paths_set_state_dir_override(NULL);
    printf("palette_model_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
