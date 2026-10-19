/* find_overlay_test.c — the find engine end to end, and the two geometries it
 * produces: the in-page highlight rects and the scrollbar heat-map ticks.
 *
 * WHY IT NEEDS A REAL DOCUMENT. Everything the differential can check about
 * search is already checked by portable/win/tests/search-differential-native.cmd
 * against the GTK4 original. What it CANNOT check is the parts with no GTK
 * original: the worker thread's lifecycle, and the two mappings that turn a
 * match in PDF points into a rectangle on the canvas and a fraction of the
 * document's height. Those need pages, so this one opens
 * portable/win/tests/fixtures/outline.pdf -- four pages at three sizes, every
 * one of them carrying the line "ShenzhenPDF outline fixture", so the expected
 * match count is known without hard-coding a rectangle.
 *
 * THAT PROPERTY IS LOAD-BEARING. This suite asserts exactly 4 matches for
 * "outline fixture", one per page, in page order. If the fixture is ever
 * regenerated from make_outline_fixture.py, keep that line on every page and
 * keep page 2 the 1224 pt foldout -- test_overlays() uses the foldout precisely
 * so that a wrong page size shows up as a rectangle in the wrong place rather
 * than as no rectangle at all.
 *
 * IT DRIVES A SESSION OF ITS OWN, never spdf_win_find_shared(): no environment,
 * no window, no app, and no chance of a test leaving a process-wide search
 * running behind it.
 *
 * EACH DIRECTIVE BELOW IS ITS OWN ONE-LINE COMMENT, opened and closed on that
 * line. harness-lib.sh's `declared` matches up to a closing comment marker, so a
 * directive written as a continuation line inside a block comment is silently
 * ignored -- and the test then fails to link for a reason that looks nothing
 * like the cause. Cost one full suite run.
 */
/* spdf-test-sources: portable/win/src/spdf_win_search.cpp portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_open.c */
/* spdf-test-args: portable/win/tests/fixtures/outline.pdf */
/* spdf-test-needs: mupdf */
#include "spdf_win_chrome_find.h"
#include "spdf_win_d2d.h"

#include <stdio.h>
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

#define CHECK_EQI(a, b)                                                                                                \
    do {                                                                                                               \
        long long va = (long long)(a);                                                                                 \
        long long vb = (long long)(b);                                                                                 \
        ++g_checks;                                                                                                    \
        if (va != vb) {                                                                                                \
            printf("FAIL %s:%d: %s (%lld) != %s (%lld)\n", __FILE__, __LINE__, #a, va, #b, vb);                        \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- the pure half: mark thinning, which needs no document ---------------- */

static void test_thin_marks(void) {
    float in[8];
    float out[8];
    int active = -9;
    int n;

    /* Nothing is dropped when every tick is far apart. */
    in[0] = 0.0f;
    in[1] = 0.25f;
    in[2] = 0.5f;
    in[3] = 0.75f;
    in[4] = 1.0f;
    n = spdf_win_find_thin_marks(in, 5, 2, 800.0f, 1.5f, out, 8, &active);
    CHECK_EQI(n, 5);
    CHECK_EQI(active, 2);
    CHECK(out[0] == 0.0f && out[4] == 1.0f);

    /* A dense run on a short lane collapses to one tick. 0.001 of 100 px is
     * 0.1 px, well inside the 1.5 px minimum gap. */
    in[0] = 0.500f;
    in[1] = 0.501f;
    in[2] = 0.502f;
    in[3] = 0.503f;
    n = spdf_win_find_thin_marks(in, 4, -1, 100.0f, 1.5f, out, 8, &active);
    CHECK_EQI(n, 1);
    CHECK_EQI(active, -1);

    /* THE RULE THAT IS EASY TO GET WRONG: the gap is measured against the last
     * KEPT tick, not the last one seen. Four ticks 1.0 px apart on a 100 px lane
     * must give two (0, then 2.0), not four. */
    in[0] = 0.00f;
    in[1] = 0.01f;
    in[2] = 0.02f;
    in[3] = 0.03f;
    n = spdf_win_find_thin_marks(in, 4, -1, 100.0f, 1.5f, out, 8, &active);
    CHECK_EQI(n, 2);
    CHECK(out[0] == 0.00f);
    CHECK(out[1] == 0.02f);

    /* The active tick survives being swallowed: it takes the kept marker's
     * slot, so the reader never loses the one tick they are looking for. */
    in[0] = 0.500f;
    in[1] = 0.501f;
    n = spdf_win_find_thin_marks(in, 2, 1, 100.0f, 1.5f, out, 8, &active);
    CHECK_EQI(n, 1);
    CHECK_EQI(active, 0);
    CHECK(out[0] == 0.501f);

    /* Out of range in, clamped out; and a zero-capacity output is not a crash. */
    in[0] = -2.0f;
    in[1] = 3.0f;
    n = spdf_win_find_thin_marks(in, 2, -1, 800.0f, 1.5f, out, 8, &active);
    CHECK_EQI(n, 2);
    CHECK(out[0] == 0.0f && out[1] == 1.0f);
    CHECK_EQI(spdf_win_find_thin_marks(in, 2, -1, 800.0f, 1.5f, out, 0, &active), 0);
    CHECK_EQI(spdf_win_find_thin_marks(NULL, 2, -1, 800.0f, 1.5f, out, 8, &active), 0);
}

/* --- the counter, which is macOS's and not the GTK one -------------------- */

static void test_counter_text(void) {
    SpdfWinChromeModel m;
    wchar_t buf[SPDF_WIN_FIND_COUNTER_MAX];

    memset(&m, 0, sizeof(m));
    m.match_index = -1;

    /* "" with no query -- and the pill and counter are hidden with it. */
    spdf_win_find_counter_text(&m, buf, SPDF_WIN_FIND_COUNTER_MAX);
    CHECK(buf[0] == L'\0');
    CHECK_EQI(spdf_win_find_has_query(&m), 0);
    m.query = L"";
    CHECK_EQI(spdf_win_find_has_query(&m), 0);

    m.query = L"fixture";
    CHECK_EQI(spdf_win_find_has_query(&m), 1);

    /* "..." while searching with nothing found yet. */
    m.searching = 1;
    spdf_win_find_counter_text(&m, buf, SPDF_WIN_FIND_COUNTER_MAX);
    CHECK(wcscmp(buf, L"...") == 0);

    /* "0 / 0" on no match. */
    m.searching = 0;
    spdf_win_find_counter_text(&m, buf, SPDF_WIN_FIND_COUNTER_MAX);
    CHECK(wcscmp(buf, L"0 / 0") == 0);

    /* "<index+1> / <total>" -- the +1 is the presentation-layer conversion and
     * happens exactly here, as it does for the page number. */
    m.match_count = 12;
    m.match_index = 0;
    spdf_win_find_counter_text(&m, buf, SPDF_WIN_FIND_COUNTER_MAX);
    CHECK(wcscmp(buf, L"1 / 12") == 0);
    m.match_index = 11;
    spdf_win_find_counter_text(&m, buf, SPDF_WIN_FIND_COUNTER_MAX);
    CHECK(wcscmp(buf, L"12 / 12") == 0);
    m.match_count = 20000;
    m.match_index = 19999;
    spdf_win_find_counter_text(&m, buf, SPDF_WIN_FIND_COUNTER_MAX);
    CHECK(wcscmp(buf, L"20000 / 20000") == 0);

    /* A partial batch: matches, but nothing selected yet -- the bare total. */
    m.match_count = 7;
    m.match_index = -1;
    m.searching = 1;
    spdf_win_find_counter_text(&m, buf, SPDF_WIN_FIND_COUNTER_MAX);
    CHECK(wcscmp(buf, L"7") == 0);

    /* A buffer too small truncates rather than overruns. Named `tight` and not
     * `small`: rpcndr.h, which arrives with windows.h, has `#define small char`,
     * so a local called `small` is a syntax error two lines later. */
    {
        wchar_t tight[4];
        m.match_count = 12;
        m.match_index = 11;
        m.searching = 0;
        tight[3] = L'X';
        spdf_win_find_counter_text(&m, tight, 4);
        CHECK_EQI((int)wcslen(tight), 3);
    }
}

/* --- the engine, against a real document ---------------------------------- */

static int wait_for_search(SpdfWinFindSession* s) {
    int spins;
    /* The worker is a thread; poll it the way the UI thread does. 20 s is far
     * beyond a four-page fixture and is a hang detector, not a timing
     * assumption. */
    for (spins = 0; spins < 20000; ++spins) {
        spdf_win_find_poll(s);
        if (!spdf_win_find_searching(s)) {
            spdf_win_find_poll(s); /* the final batch */
            return 1;
        }
        Sleep(1);
    }
    return 0;
}

static void test_engine(const char* path) {
    SpdfWinFindSession* s = spdf_win_find_session_new();
    const float* marks;
    int mark_count = -1, active = -9, i;

    CHECK(s != NULL);
    if (!s) return;

    /* Nothing set: no search, no matches, no marks. */
    CHECK_EQI(spdf_win_find_searching(s), 0);
    CHECK_EQI(spdf_win_find_match_count(s), 0);
    CHECK_EQI(spdf_win_find_match_index(s), -1);

    /* An empty query starts nothing even with a document. */
    spdf_win_find_set(s, path, "", 0);
    CHECK_EQI(spdf_win_find_searching(s), 0);
    CHECK_EQI(spdf_win_find_match_count(s), 0);

    /* Every page of the fixture carries "ShenzhenPDF outline fixture". */
    spdf_win_find_set(s, path, "outline fixture", 0);
    CHECK(wait_for_search(s));
    CHECK_EQI(spdf_win_find_match_count(s), 4);
    CHECK_EQI(spdf_win_find_match_index(s), 0);
    CHECK(spdf_win_find_error(s) == NULL);

    /* Matches arrive in document order, one per page. */
    for (i = 0; i < 4; ++i) {
        int page = -1;
        spdf_rect rect;
        memset(&rect, 0, sizeof(rect));
        CHECK_EQI(spdf_win_find_step(s, i == 0 ? 0 : 1), i);
        CHECK(spdf_win_find_current_target(s, &page, &rect));
        CHECK_EQI(page, i);
        CHECK(rect.x1 > rect.x0 && rect.y1 > rect.y0);
    }
    /* Wraparound, forward and backward, exactly as GTK3 find_step does. */
    CHECK_EQI(spdf_win_find_step(s, 1), 0);
    CHECK_EQI(spdf_win_find_step(s, -1), 3);
    CHECK_EQI(spdf_win_find_step(s, -7), 0);

    /* Marks: one per match, sorted, inside [0,1], and the active one tracked. */
    marks = spdf_win_find_marks(s, &mark_count, &active);
    CHECK(marks != NULL);
    CHECK_EQI(mark_count, 4);
    CHECK_EQI(active, 0);
    for (i = 0; i < mark_count; ++i) {
        CHECK(marks[i] >= 0.0f && marks[i] <= 1.0f);
        if (i > 0) CHECK(marks[i] >= marks[i - 1]);
    }
    /* A four-page document's four ticks must not all land at the top: the
     * layout is real, so the last match is well down the document. */
    CHECK(marks[3] > 0.5f);

    /* THE RESULTS SIDEBAR'S INPUTS. Every match carries its page, its line and
     * the outline entry it falls under; the fixture's outline is
     * Introduction(p0,l0) Background(p0,l1) Uberblick(p1,l1) Chapter Two(p1,l0)
     * CJK section(p2,l1) Appendix(p3,l0), so the LAST entry starting on or
     * before each page is 1, 3, 4, 5 -- the rule spdf_win_search_chapter_for_page
     * transcribes and the differential pins. */
    {
        static const int kChapter[4] = {1, 3, 4, 5};
        SpdfWinFindMatchInfo info;
        unsigned rev_before;
        const SpdfWinFindPageMark* pm;
        int pm_count = -1, pm_active = -9;

        CHECK_EQI(spdf_win_find_chapter_count(s), 6);
        CHECK(spdf_win_find_chapter_title(s, 1) && strcmp(spdf_win_find_chapter_title(s, 1), "Background") == 0);
        CHECK(spdf_win_find_chapter_title(s, 5) && strcmp(spdf_win_find_chapter_title(s, 5), "Appendix") == 0);
        CHECK(spdf_win_find_chapter_title(s, 6) == NULL);
        CHECK(spdf_win_find_chapter_title(s, -1) == NULL);
        CHECK(spdf_win_find_query(s) && strcmp(spdf_win_find_query(s), "outline fixture") == 0);
        for (i = 0; i < 4; ++i) {
            memset(&info, 0, sizeof(info));
            CHECK(spdf_win_find_match_at(s, i, &info));
            CHECK_EQI(info.page, i);
            CHECK_EQI(info.chapter_index, kChapter[i]);
            CHECK(info.snippet && strstr(info.snippet, "outline fixture") != NULL);
        }
        CHECK(!spdf_win_find_match_at(s, 4, &info));
        CHECK(!spdf_win_find_match_at(s, -1, &info));

        /* The minimap markers: one per match, on its own page, inside [0,1]. */
        pm = spdf_win_find_page_marks(s, &pm_count, &pm_active);
        CHECK(pm != NULL);
        CHECK_EQI(pm_count, 4);
        CHECK_EQI(pm_active, spdf_win_find_match_index(s));
        for (i = 0; i < pm_count; ++i) {
            CHECK_EQI(pm[i].page, i);
            CHECK(pm[i].fraction >= 0.0f && pm[i].fraction <= 1.0f);
        }

        /* set_current moves the selection and the revision; out of range and
         * "already there" change neither. */
        rev_before = spdf_win_find_revision(s);
        CHECK_EQI(spdf_win_find_set_current(s, 2), 1);
        CHECK_EQI(spdf_win_find_match_index(s), 2);
        CHECK(spdf_win_find_revision(s) != rev_before);
        rev_before = spdf_win_find_revision(s);
        CHECK_EQI(spdf_win_find_set_current(s, 2), 0);
        CHECK_EQI(spdf_win_find_set_current(s, 9), 0);
        CHECK_EQI(spdf_win_find_set_current(s, -1), 0);
        CHECK(spdf_win_find_revision(s) == rev_before);
        spdf_win_find_page_marks(s, &pm_count, &pm_active);
        CHECK_EQI(pm_active, 2);
        spdf_win_find_marks(s, &mark_count, &active);
        CHECK_EQI(active, 2);
        CHECK_EQI(spdf_win_find_set_current(s, 0), 1);

        /* The multiline flag is a fourth input to set(): flipping it reruns the
         * same query (the results go, the worker restarts), and flipping it
         * back reruns again. Both directions land on the same four matches. */
        CHECK_EQI(spdf_win_find_regex_multiline(), 1); /* the originals' default */
        spdf_win_find_set_regex_multiline(0);
        CHECK_EQI(spdf_win_find_regex_multiline(), 0);
        spdf_win_find_set(s, path, "outline fixture", 0);
        CHECK(wait_for_search(s));
        CHECK_EQI(spdf_win_find_match_count(s), 4);
        spdf_win_find_set_regex_multiline(1);
        spdf_win_find_set(s, path, "outline fixture", 0);
        CHECK(wait_for_search(s));
        CHECK_EQI(spdf_win_find_match_count(s), 4);
        /* Unchanged inputs do not restart: the revision holds still. */
        rev_before = spdf_win_find_revision(s);
        spdf_win_find_set(s, path, "outline fixture", 0);
        CHECK(spdf_win_find_revision(s) == rev_before);

        /* restart() drops the results and lets the same set() rerun them. */
        spdf_win_find_restart(s);
        CHECK_EQI(spdf_win_find_match_count(s), 0);
        CHECK_EQI(spdf_win_find_chapter_count(s), 0);
        spdf_win_find_set(s, path, "outline fixture", 0);
        CHECK(wait_for_search(s));
        CHECK_EQI(spdf_win_find_match_count(s), 4);
        CHECK_EQI(spdf_win_find_chapter_count(s), 6);
    }

    /* A query with no matches: zero, and no error. */
    spdf_win_find_set(s, path, "zzzznotinthisdocument", 0);
    CHECK(wait_for_search(s));
    CHECK_EQI(spdf_win_find_match_count(s), 0);
    CHECK_EQI(spdf_win_find_match_index(s), -1);
    CHECK(spdf_win_find_error(s) == NULL);
    spdf_win_find_marks(s, &mark_count, &active);
    CHECK_EQI(mark_count, 0);
    CHECK_EQI(active, -1);

    /* Regex: the same four lines, reached through the pattern engine. */
    spdf_win_find_set(s, path, "outline +fixture", 1);
    CHECK(wait_for_search(s));
    CHECK_EQI(spdf_win_find_match_count(s), 4);

    /* An invalid pattern fails gracefully -- no matches, and an error the
     * toolbar can show, rather than a crash or a stuck "..." . */
    spdf_win_find_set(s, path, "[unclosed", 1);
    CHECK(wait_for_search(s));
    CHECK_EQI(spdf_win_find_match_count(s), 0);
    CHECK_EQI(spdf_win_find_searching(s), 0);

    /* Clearing the query cancels and empties. */
    spdf_win_find_set(s, path, "", 0);
    CHECK_EQI(spdf_win_find_match_count(s), 0);
    CHECK_EQI(spdf_win_find_searching(s), 0);

    spdf_win_find_session_free(s);
}

/* --- the overlay mapping -------------------------------------------------- */

/* THE COORDINATE CONTRACT, which is the easiest thing here to get wrong: a
 * page_draw's dest is CANVAS-LOCAL device pixels and a match rect is PDF points
 * measured from the page's own top-left. So an overlay must land inside its
 * page's dest rect, and it must move with the page rather than with the window.
 * Both are asserted by placing the page at a deliberately non-zero origin. */
static void test_overlays(const char* path) {
    SpdfWinFindSession* s = spdf_win_find_session_new();
    spdf_win_page_draw pages[2];
    spdf_win_scene scene;
    int i, rings = 0, fills = 0;

    CHECK(s != NULL);
    if (!s) return;
    spdf_win_find_set(s, path, "outline fixture", 0);
    CHECK(wait_for_search(s));
    CHECK_EQI(spdf_win_find_match_count(s), 4);

    memset(pages, 0, sizeof(pages));
    memset(&scene, 0, sizeof(scene));
    /* Page 0 (612x792 pt) at half zoom, offset well away from the origin. */
    pages[0].page_index = 0;
    pages[0].dest_x = 37.0f;
    pages[0].dest_y = 91.0f;
    pages[0].dest_w = 306.0f;
    pages[0].dest_h = 396.0f;
    /* Page 2 is the 1224 pt foldout, so a wrong page size shows as a rect in
     * the wrong place rather than as no rect at all. */
    pages[1].page_index = 2;
    pages[1].dest_x = 37.0f;
    pages[1].dest_y = 600.0f;
    pages[1].dest_w = 612.0f;
    pages[1].dest_h = 396.0f;
    scene.pages = pages;
    scene.page_count = 2;
    scene.target_px_h = 900;
    scene.dpi_scale = 1.0f;

    spdf_win_find_apply_overlays_for(s, &scene);
    /* Two visible pages, one match each, plus the ring for the active match
     * (which is on page 0). */
    CHECK_EQI(scene.overlay_count, 3);
    CHECK(scene.overlays != NULL);
    if (!scene.overlays) {
        spdf_win_find_session_free(s);
        return;
    }
    for (i = 0; i < scene.overlay_count; ++i) {
        const spdf_win_overlay* o = &scene.overlays[i];
        const spdf_win_page_draw* pd = o->page_index == 0 ? &pages[0] : &pages[1];
        CHECK(o->page_index == 0 || o->page_index == 2);
        CHECK(o->w > 0.0f && o->h > 0.0f);
        CHECK(o->x >= pd->dest_x && o->x + o->w <= pd->dest_x + pd->dest_w);
        CHECK(o->y >= pd->dest_y && o->y + o->h <= pd->dest_y + pd->dest_h);
        CHECK(o->alpha == 1.0f);
        if (o->kind == SPDF_WIN_OVERLAY_SEARCH_ACTIVE) ++rings;
        if (o->kind == SPDF_WIN_OVERLAY_SEARCH_MATCH) ++fills;
    }
    CHECK_EQI(fills, 2);
    CHECK_EQI(rings, 1);
    /* The ring is LAST, because the overlay painter draws in array order and it
     * has to sit on top of every fill. */
    CHECK_EQI(scene.overlays[scene.overlay_count - 1].kind, SPDF_WIN_OVERLAY_SEARCH_ACTIVE);

    /* Step to a match on a page that is not on screen: the fills stay, the ring
     * goes, and nothing is drawn for the off-screen match. */
    CHECK_EQI(spdf_win_find_step(s, 1), 1); /* page 1, not in `pages` */
    spdf_win_find_apply_overlays_for(s, &scene);
    CHECK_EQI(scene.overlay_count, 2);

    /* No pages: no overlays, and the scene's two fields are cleared rather than
     * left pointing at last frame's array. */
    scene.page_count = 0;
    spdf_win_find_apply_overlays_for(s, &scene);
    CHECK_EQI(scene.overlay_count, 0);
    CHECK(scene.overlays == NULL);

    /* A NULL session is the "nobody searched" path and must be a clean no-op. */
    scene.page_count = 2;
    spdf_win_find_apply_overlays_for(NULL, &scene);
    CHECK_EQI(scene.overlay_count, 0);

    spdf_win_find_session_free(s);
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : NULL;

    test_thin_marks();
    test_counter_text();
    if (!path) {
        printf("find_overlay_test: no document argument; ran %d pure checks\n", g_checks);
        return g_failures == 0 ? 0 : 1;
    }
    test_engine(path);
    test_overlays(path);

    printf("find_overlay_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
