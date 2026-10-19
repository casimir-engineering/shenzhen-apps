/* recents_test.c — spdf_win_recents.{h,c} and spdf_win_favorites.{h,c} against
 * the real shared codec, in a scratch state directory.
 *
 * WHAT IS BEING PROVED. Not that the two stores can remember things -- that
 * they put on disk what portable/linux/gtk4/spdf_state.c and the mac app put
 * there: the same members in the same (sorted) order, through the same YAML
 * codec, so a documents.yaml or favorites.yaml synced from a Mac reads back
 * here and a file written here reads back there. The fixtures below are the
 * JSON those writers produce, and the round trip is asserted byte for byte
 * through spdf_yaml_from_json(). The MRU rules (dedupe by folded path, cap 10,
 * MRU first, settings.yaml's list honoured in its order) are the mac's
 * rememberRecentlyOpenedPath and GTK's spdf_state_add_recent.
 *
 * Everything runs against a temp directory via spdf_win_paths_set_state_dir_
 * override -- never against %APPDATA%\ShenzhenPDF, which the user's running
 * instance is using right now.
 */
/* spdf-test-sources: portable/win/src/spdf_win_recents.c portable/win/src/spdf_win_favorites.c portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/win/src/spdf_win_watcher.cpp portable/win/src/spdf_win_watcher_shadow.cpp portable/core/spdf_yaml.c portable/core/spdf_win_compat.c */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif

#include "spdf_win_favorites.h"
#include "spdf_win_paths.h"
#include "spdf_win_recents.h"
#include "spdf_win_state.h"
#include "spdf_win_watcher.h" /* spdf_win_watcher_is_shadow_path, the refusal both stores make */
#include "spdf_yaml.h"

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

static void check_str(const char* got, const char* want, const char* what) {
    ++g_checks;
    if (!got || strcmp(got, want) != 0) {
        printf("FAIL %s\n  got  %s\n  want %s\n", what, got ? got : "(null)", want);
        ++g_failures;
    }
}

static char* read_whole(const char* name) {
    char path[SPDF_WIN_PATH_MAX], native[SPDF_WIN_PATH_MAX];
    FILE* f;
    long n;
    char* out;
    if (!spdf_win_paths_state_file(name, path, sizeof(path)) || !spdf_win_path_to_native(path, native, sizeof(native)))
        return NULL;
#if defined(_WIN32)
    /* The scratch directory has a non-ASCII leaf on purpose; the narrow CRT
     * cannot open it, which is the very reason the module uses CreateFileW. */
    {
        spdf_wchar* wide = spdf_win_utf16_dup_from_utf8(native);
        f = wide ? _wfopen(wide, L"rb") : NULL;
        free(wide);
    }
#else
    f = fopen(native, "rb");
#endif
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    out = (char*)malloc((size_t)n + 1);
    if (out && fread(out, 1, (size_t)n, f) != (size_t)n) {
        free(out);
        out = NULL;
    }
    if (out) out[n] = '\0';
    fclose(f);
    return out;
}

/* The file must be exactly what the shared codec emits for `json`. */
static void check_file_is_codec_output(const char* name, const char* json) {
    char header[256];
    char* want = spdf_yaml_from_json(json, spdf_state_header_for_file(name, header, sizeof(header)));
    char* got = read_whole(name);
    CHECK(want != NULL);
    if (want) check_str(got, want, name);
    free(want);
    free(got);
}

/* --- recents ------------------------------------------------------------ */

static void test_mru_rules(void) {
    spdf_win_recents_reset();
    CHECK(spdf_win_recents_count() == 0);
    spdf_win_recents_note_opened("C:\\docs\\a.pdf", "a");
    spdf_win_recents_note_opened("C:\\docs\\b.pdf", NULL);
    spdf_win_recents_note_opened("C:\\docs\\c.pdf", "c");
    CHECK(spdf_win_recents_count() == 3);
    check_str(spdf_win_recents_path(0), "C:\\docs\\c.pdf", "MRU first");
    /* Re-opening moves to the front; the same file spelled another way is the
     * same entry (mac stringByStandardizingPath dedupe; Windows folds case). */
    spdf_win_recents_note_opened("c:/DOCS/a.pdf", "a");
    CHECK(spdf_win_recents_count() == 3);
    check_str(spdf_win_recents_path(0), "c:/DOCS/a.pdf", "reopen moves to front");
    check_str(spdf_win_recents_path(1), "C:\\docs\\c.pdf", "the rest shift down");
    CHECK(spdf_win_recents_path(3) == NULL);
    CHECK(spdf_win_recents_path(-1) == NULL);
    /* Cap: 10, oldest falls off. */
    {
        int i;
        char path[64];
        for (i = 0; i < 12; ++i) {
            snprintf(path, sizeof(path), "C:\\many\\%02d.pdf", i);
            spdf_win_recents_note_opened(path, NULL);
        }
        CHECK(spdf_win_recents_count() == SPDF_WIN_RECENTS_MAX);
        check_str(spdf_win_recents_path(0), "C:\\many\\11.pdf", "newest survives the cap");
        check_str(spdf_win_recents_path(9), "C:\\many\\02.pdf", "oldest kept is the tenth");
    }
    spdf_win_recents_remove("C:\\MANY\\11.pdf");
    CHECK(spdf_win_recents_count() == 9);
    check_str(spdf_win_recents_path(0), "C:\\many\\10.pdf", "remove drops the entry");
    spdf_win_recents_note_opened("", "x"); /* ignored */
    spdf_win_recents_note_opened(NULL, "x");
    CHECK(spdf_win_recents_count() == 9);
}

static void test_closed_ring(void) {
    char out[SPDF_WIN_RECENTS_PATH_MAX];
    int i;
    spdf_win_recents_reset();
    CHECK(!spdf_win_recents_pop_closed(out, sizeof(out)));
    spdf_win_recents_note_closed("C:\\x\\1.pdf");
    spdf_win_recents_note_closed("C:\\x\\2.pdf");
    CHECK(spdf_win_recents_closed_count() == 2);
    CHECK(spdf_win_recents_pop_closed(out, sizeof(out)));
    check_str(out, "C:\\x\\2.pdf", "most recently closed pops first (Ctrl+Shift+T)");
    CHECK(spdf_win_recents_pop_closed(out, sizeof(out)));
    check_str(out, "C:\\x\\1.pdf", "then the one before");
    CHECK(!spdf_win_recents_pop_closed(out, sizeof(out)));
    for (i = 0; i < 15; ++i) {
        char p[32];
        snprintf(p, sizeof(p), "C:\\x\\%d.pdf", i);
        spdf_win_recents_note_closed(p);
    }
    CHECK(spdf_win_recents_closed_count() == SPDF_WIN_RECENTS_CLOSED_MAX);
    CHECK(spdf_win_recents_pop_closed(out, sizeof(out)));
    check_str(out, "C:\\x\\14.pdf", "ring keeps the newest ten");
}

/* documents.yaml: what is written is what spdf_state.c documents_to_json /
 * the mac writer produce -- sorted keys, the five members -- and a foreign
 * member (the mac geometry cache) survives a rewrite. */
static void test_documents_file_matches_the_shared_writers(void) {
    char* json;
    SpdfWinDocRecord rec;
    spdf_win_recents_reset();
    spdf_win_state_write_json(SPDF_WIN_STATE_DOCUMENTS,
                              "{\"C:\\\\docs\\\\Old.pdf\":{\"geometryPageCount\":1,\"pageGeometry\":[612.0,792.0],"
                              "\"path\":\"C:\\\\docs\\\\Old.pdf\",\"showMinimap\":false,\"showSidebar\":true,"
                              "\"title\":\"Old\",\"updatedAt\":100}}");
    spdf_win_recents_reset();
    /* The stored record is the seed of the MRU list. */
    CHECK(spdf_win_recents_count() == 1);
    check_str(spdf_win_recents_path(0), "C:\\docs\\Old.pdf", "documents.yaml seeds the MRU list");
    CHECK(spdf_win_recents_document_lookup("c:\\DOCS\\old.pdf", &rec));
    CHECK(rec.has_show_minimap && !rec.show_minimap && rec.show_sidebar);
    check_str(rec.title, "Old", "title read back");
    spdf_win_recents_document_update("C:\\docs\\New.pdf", "New", 1, 1);
    json = spdf_win_recents_documents_json();
    CHECK(json != NULL);
    if (json) {
        /* Sorted by key; the foreign members kept, in sorted position; the
         * updatedAt stamp is "now" so it is matched loosely. */
        const char* want_prefix =
            "{\"C:\\\\docs\\\\New.pdf\":{\"path\":\"C:\\\\docs\\\\New.pdf\",\"showMinimap\":true,\"showSidebar\":true,"
            "\"title\":\"New\",\"updatedAt\":";
        CHECK(strncmp(json, want_prefix, strlen(want_prefix)) == 0);
        CHECK(strstr(json, "\"C:\\\\docs\\\\Old.pdf\":{\"geometryPageCount\":1,\"pageGeometry\":[612.0,792.0],\"path\":"
                           "\"C:\\\\docs\\\\Old.pdf\",\"showMinimap\":false,\"showSidebar\":true,\"title\":\"Old\","
                           "\"updatedAt\":100}}") != NULL);
        check_file_is_codec_output(SPDF_WIN_STATE_DOCUMENTS, json);
        free(json);
    }
    /* Newest stamp wins the MRU order after a reload. */
    spdf_win_recents_reset();
    CHECK(spdf_win_recents_count() == 2);
    check_str(spdf_win_recents_path(0), "C:\\docs\\New.pdf", "newest updatedAt first after reload");
}

/* settings.yaml's "recentlyOpened" -- written by the mac or GTK app -- is
 * honoured in its own order ahead of the local stamps, and the merge helper
 * hands the settings writer the key in sorted position. */
static void test_settings_list_seeds_and_merges(void) {
    char* merged;
    spdf_win_recents_reset();
    spdf_win_state_write_json(SPDF_WIN_STATE_SETTINGS,
                              "{\"fitMode\":4,\"recentlyOpened\":[\"C:\\\\mac\\\\first.pdf\",\"C:\\\\mac\\\\second.pdf\","
                              "\"C:\\\\docs\\\\New.pdf\"],\"zoom\":1.0}");
    spdf_win_recents_reset();
    CHECK(spdf_win_recents_count() == 4); /* three from settings + Old.pdf from documents.yaml */
    check_str(spdf_win_recents_path(0), "C:\\mac\\first.pdf", "settings order first");
    check_str(spdf_win_recents_path(2), "C:\\docs\\New.pdf", "a path in both lists once");
    check_str(spdf_win_recents_path(3), "C:\\docs\\Old.pdf", "documents.yaml fills in behind");

    merged = spdf_win_recents_merge_recently_opened("{\"fitMode\":4,\"recentlyOpened\":[\"stale\"],\"zoom\":1.0}");
    check_str(merged,
              "{\"fitMode\":4,\"recentlyOpened\":[\"C:\\\\mac\\\\first.pdf\",\"C:\\\\mac\\\\second.pdf\",\"C:\\\\docs\\\\New.pdf\","
              "\"C:\\\\docs\\\\Old.pdf\"],\"zoom\":1.0}",
              "merge replaces the key in place");
    free(merged);
    merged = spdf_win_recents_merge_recently_opened("{\"autoUpdateEnabled\":true,\"zoom\":1.0}");
    CHECK(merged && strncmp(merged, "{\"autoUpdateEnabled\":true,\"recentlyOpened\":[", 44) == 0);
    CHECK(merged && strstr(merged, "],\"zoom\":1.0}") != NULL);
    free(merged);
    merged = spdf_win_recents_merge_recently_opened("{}");
    CHECK(merged && strncmp(merged, "{\"recentlyOpened\":[", 19) == 0);
    free(merged);
    merged = spdf_win_recents_merge_recently_opened(NULL);
    CHECK(merged && strncmp(merged, "{\"recentlyOpened\":[", 19) == 0);
    free(merged);
    CHECK(spdf_win_recents_merge_recently_opened("[1,2]") == NULL);
}

/* --- favorites ---------------------------------------------------------- */

static void test_favorites_toggle_dedupe_and_file(void) {
    const SpdfWinFavorite* f;
    char* json;
    spdf_win_favorites_reset();
    CHECK(spdf_win_favorites_count() == 0);
    CHECK(spdf_win_favorites_toggle_page("C:\\docs\\Manual.pdf", "Manual", 2) == 1);
    CHECK(spdf_win_favorites_toggle_document("C:\\docs\\Manual.pdf", "Manual") == 1);
    CHECK(spdf_win_favorites_count() == 2);
    f = spdf_win_favorites_at(0);
    CHECK(f != NULL);
    if (f) {
        check_str(f->type, "page", "first is the page favorite");
        check_str(f->name, "Manual p.3", "default name is the mac prompt's default, 1-based");
        CHECK(f->page == 2);
        CHECK(f->created > 0);
    }
    /* Same page spelled differently: a toggle REMOVES it. */
    CHECK(spdf_win_favorites_toggle_page("c:/docs/manual.pdf", NULL, 2) == 0);
    CHECK(spdf_win_favorites_count() == 1);
    CHECK(spdf_win_favorites_find("document", "C:\\docs\\Manual.pdf", 0) == 0);
    CHECK(spdf_win_favorites_find("page", "C:\\docs\\Manual.pdf", 2) == -1);
    /* Another page of the same document is a distinct favorite. */
    CHECK(spdf_win_favorites_toggle_page("C:\\docs\\Manual.pdf", "Manual", 5) == 1);
    CHECK(spdf_win_favorites_count() == 2);
    /* Adding an existing document favorite replaces rather than duplicates. */
    {
        SpdfWinFavorite dup;
        memset(&dup, 0, sizeof(dup));
        strcpy(dup.type, "document");
        strcpy(dup.path, "C:\\DOCS\\manual.pdf");
        strcpy(dup.title, "Manual (renamed)");
        strcpy(dup.name, "Manual (renamed)");
        strcpy(dup.labels, "[\"work\",\"hw\"]");
        dup.created = 1700000000;
        CHECK(spdf_win_favorites_add(&dup) == 1);
        CHECK(spdf_win_favorites_count() == 2);
    }
    json = spdf_win_favorites_json();
    CHECK(json != NULL);
    if (json) {
        /* spdf_state.c favorites_to_json member order: created, labels, name,
         * page, path, title, type. The page favorite's created is "now". */
        CHECK(strncmp(json, "[{\"created\":", 12) == 0);
        CHECK(strstr(json, ",\"labels\":[],\"name\":\"Manual p.6\",\"page\":5,\"path\":\"C:\\\\docs\\\\Manual.pdf\","
                           "\"title\":\"Manual\",\"type\":\"page\"},") != NULL);
        CHECK(strstr(json, "{\"created\":1700000000,\"labels\":[\"work\",\"hw\"],\"name\":\"Manual (renamed)\",\"page\":0,"
                           "\"path\":\"C:\\\\DOCS\\\\manual.pdf\",\"title\":\"Manual (renamed)\",\"type\":\"document\"}]") !=
              NULL);
        check_file_is_codec_output(SPDF_WIN_STATE_FAVORITES, json);
        free(json);
    }
    /* Reload from disk: everything survives, labels included. */
    spdf_win_favorites_reset();
    CHECK(spdf_win_favorites_count() == 2);
    f = spdf_win_favorites_at(1);
    if (f) check_str(f->labels, "[\"work\",\"hw\"]", "labels round-trip through the codec");
    CHECK(spdf_win_favorites_remove(0));
    CHECK(spdf_win_favorites_count() == 1);
    CHECK(!spdf_win_favorites_remove(5));
    CHECK(spdf_win_favorites_toggle_page(NULL, NULL, 0) == -1);
    CHECK(spdf_win_favorites_toggle_page("C:\\x.pdf", NULL, -1) == -1);
}

/* The GTK3 legacy wrapper shape, which the GTK4 reader also accepts. */
static void test_favorites_reads_legacy_wrapper(void) {
    const SpdfWinFavorite* f;
    spdf_win_favorites_reset();
    spdf_win_state_write_json(SPDF_WIN_STATE_FAVORITES,
                              "{\"favorites\":[{\"path\":\"C:\\\\old\\\\g3.pdf\",\"title\":\"G3\",\"page\":4,\"document\":false},"
                              "{\"path\":\"C:\\\\old\\\\doc.pdf\",\"title\":\"Doc\",\"document\":true}]}");
    spdf_win_favorites_reset();
    CHECK(spdf_win_favorites_count() == 2);
    f = spdf_win_favorites_at(0);
    if (f) {
        check_str(f->type, "page", "legacy page");
        CHECK(f->page == 3); /* 1-based in the GTK3 file */
        check_str(f->name, "G3", "legacy name is the title");
    }
    f = spdf_win_favorites_at(1);
    if (f) check_str(f->type, "document", "legacy document flag");
}

/* NEITHER STORE ACCEPTS A READ-ONLY SHADOW COPY.
 *
 * spdf_win_recents.h has claimed "shadow copies ... are ignored" since it was
 * written, and neither store checked -- so every read-only document a reader
 * opened put a `%APPDATA%\ShenzhenPDF\ReadOnlyCopies\ro-<hex>.pdf` entry at the
 * top of Open Recent, and Ctrl+D could bookmark one. Those files are deleted by
 * the next launch's orphan sweep, so both were offers of a path that would be
 * gone.
 *
 * The path is CONSTRUCTED rather than copied from a run: the shape is the
 * contract (spdf_win_watcher_logic.h -- directly in the copies directory,
 * "ro-", 32 hex digits, an extension) and nothing has to exist on disk for the
 * predicate to answer. Two near-misses are checked alongside, because a test
 * that only fed it a shadow path would pass just as well against a store that
 * refused everything under the state directory. */
static void test_shadow_copies_are_refused_by_both_stores(void) {
    char copies[SPDF_WIN_PATH_MAX], shadow[SPDF_WIN_PATH_MAX], state[SPDF_WIN_PATH_MAX];
    char nearly[SPDF_WIN_PATH_MAX];
    SpdfWinFavorite f;
    int before;

    CHECK(spdf_win_paths_state_dir(state, sizeof(state)) != 0);
    CHECK(spdf_win_path_join(state, "ReadOnlyCopies", copies, sizeof(copies)) != 0);
    CHECK(spdf_win_path_join(copies, "ro-0123456789abcdef0123456789abcdef.pdf", shadow, sizeof(shadow)) != 0);
    /* FIRST, that the predicate says yes about this path. Without this line the
     * three refusal assertions below would all pass against a predicate that
     * answered 0 for everything -- which is exactly what a state-directory
     * override the watcher did not see would produce. */
    CHECK(spdf_win_watcher_is_shadow_path(shadow) == 1);

    spdf_win_state_write_json(SPDF_WIN_STATE_DOCUMENTS, "{}");
    spdf_win_state_write_json(SPDF_WIN_STATE_SETTINGS, "{}");
    spdf_win_recents_reset();
    before = spdf_win_recents_count();
    spdf_win_recents_note_opened(shadow, "Read-only copy");
    CHECK(spdf_win_recents_count() == before);
    CHECK(spdf_win_recents_document_lookup(shadow, NULL) == 0);

    memset(&f, 0, sizeof(f));
    strcpy(f.type, "document");
    strcpy(f.path, "x");
    if (spdf_win_path_join(copies, "ro-0123456789abcdef0123456789abcdef.pdf", f.path, sizeof(f.path)))
        CHECK(spdf_win_favorites_add(&f) == -1);

    /* The SOURCE still goes in -- the refusal is about the copy, not about
     * read-only documents. */
    spdf_win_recents_note_opened("C:\\docs\\report.pdf", "Report");
    CHECK(spdf_win_recents_count() == before + 1);

    /* Near misses: the right directory with the wrong name, and the right name
     * one directory too deep. Both are ordinary documents. */
    if (spdf_win_path_join(copies, "notes.pdf", nearly, sizeof(nearly))) {
        spdf_win_recents_note_opened(nearly, NULL);
        CHECK(spdf_win_recents_count() == before + 2);
    }
    if (spdf_win_path_join(copies, "sub\\ro-0123456789abcdef0123456789abcdef.pdf", nearly, sizeof(nearly))) {
        spdf_win_recents_note_opened(nearly, NULL);
        CHECK(spdf_win_recents_count() == before + 3);
    }
}

int main(int argc, char** argv) {
    char scratch[SPDF_WIN_PATH_MAX], dir[SPDF_WIN_PATH_MAX];
    const char* base = argc > 1 ? argv[1] : NULL;
    if (!base || !*base) base = getenv("TEMP");
    if (!base || !*base) base = getenv("TMPDIR");
    if (!base || !*base) base = ".";
    if (!spdf_win_path_join(base, "spdf_recents_test", scratch, sizeof(scratch))) return 1;
    if (!spdf_win_path_join(scratch, "Rapha\xc3\xabl", dir, sizeof(dir))) return 1;
    if (!spdf_win_paths_ensure_dir(dir)) {
        printf("FAIL: could not create %s\n", dir);
        return 1;
    }
    spdf_win_paths_set_state_dir_override(dir);
    /* A clean slate: earlier runs leave files behind. */
    spdf_win_state_write_json(SPDF_WIN_STATE_DOCUMENTS, "{}");
    spdf_win_state_write_json(SPDF_WIN_STATE_FAVORITES, "[]");
    spdf_win_state_write_json(SPDF_WIN_STATE_SETTINGS, "{}");

    test_mru_rules();
    test_closed_ring();
    test_documents_file_matches_the_shared_writers();
    test_settings_list_seeds_and_merges();
    test_favorites_toggle_dedupe_and_file();
    test_favorites_reads_legacy_wrapper();
    test_shadow_copies_are_refused_by_both_stores();

    spdf_win_paths_set_state_dir_override(NULL);
    printf("recents_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
