/* annot_comments_test.c — pins portable/win/src/spdf_win_annot.cpp against a
 * real document: the cache (and its one-frame deferral), the marks and
 * overlays it derives from a built scene, the inverse mapping, and the
 * Comments section's rows.
 *
 * THE FIXTURE IS MADE, NOT SHIPPED. golden.pdf has no annotations, so a scratch
 * copy gets one highlight comment and one text comment through the core's own
 * spdf_add_highlight_comment / spdf_add_text_comment, is saved, and is opened
 * again -- the same sequence the app runs, minus the dialogs. The comment
 * indices, bounds and page numbers the test then asserts are therefore the
 * core's answers, not this file's.
 *
 * No window and no Direct2D: the "scene" is a hand-built page list at a known
 * zoom, which is all spdf_win_annot_publish_geometry reads.
 */
/* spdf-test-sources: portable/win/src/spdf_win_annot.cpp portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c */
/* spdf-test-args: portable/win/tests/fixtures/golden.pdf */
/* spdf-test-needs: mupdf */

#include "spdf_win_annot.h"
#include "spdf_win_annot_model.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);                                           \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static int copy_file(const char* from, const char* to) {
    FILE* in = fopen(from, "rb");
    FILE* out = in ? fopen(to, "wb") : NULL;
    char buf[65536];
    size_t n;
    if (!in || !out) {
        if (in) fclose(in);
        if (out) fclose(out);
        return 0;
    }
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, n, out);
    fclose(in);
    fclose(out);
    return 1;
}

static int near_f(float a, float b, float tol) { return a - b <= tol && b - a <= tol; }

int main(int argc, char** argv) {
    char scratch[MAX_PATH];
    char err[512] = {0};
    spdf_document* doc;
    spdf_rect rects[2];
    const spdf_comments* comments;
    const spdf_comment_item* hl = NULL;
    const spdf_comment_item* note = NULL;
    spdf_win_page_draw page;
    spdf_win_scene scene;
    spdf_win_overlay base[1];
    const SpdfWinAnnotMark* marks;
    int mark_count = 0, deferred = 0, i, page_index = -1;
    float px = 0.0f, py = 0.0f;
    const float zoom = 2.0f;
    const SpdfWinSidebarResultsView* view;

    if (argc < 2) {
        fprintf(stderr, "usage: annot_comments_test <golden.pdf>\n");
        return 64;
    }
    GetTempPathA(MAX_PATH, scratch);
    strcat_s(scratch, MAX_PATH, "spdf_annot_comments_test.pdf");
    if (!copy_file(argv[1], scratch)) {
        fprintf(stderr, "FAIL could not copy %s to %s\n", argv[1], scratch);
        return 1;
    }

    /* --- make the fixture ------------------------------------------------ */
    doc = spdf_open(scratch, err, sizeof(err));
    CHECK(doc != NULL);
    if (!doc) return 1;
    CHECK(spdf_win_annot_count(doc, scratch) == 0); /* nothing yet, loaded now */
    rects[0].x0 = 72.0f;
    rects[0].y0 = 100.0f;
    rects[0].x1 = 300.0f;
    rects[0].y1 = 112.0f;
    rects[1].x0 = 72.0f;
    rects[1].y0 = 114.0f;
    rects[1].x1 = 200.0f;
    rects[1].y1 = 126.0f;
    CHECK(spdf_add_highlight_comment(doc, 0, rects, 2, "Check this figure", "Rapha\xc3\xabl", err, sizeof(err)));
    CHECK(spdf_add_text_comment(doc, 0, 400.0f, 500.0f, "A note", "Tester", err, sizeof(err)));
    CHECK(spdf_save_document(doc, scratch, err, sizeof(err)));
    spdf_close(doc);

    /* --- the cache: deferred on a document's first frame, loaded on the next -- */
    doc = spdf_open(scratch, err, sizeof(err));
    CHECK(doc != NULL);
    if (!doc) return 1;
    CHECK(spdf_win_annot_sync(doc, scratch, 1u, &deferred) == 0 && deferred == 1);
    CHECK(spdf_win_annot_sync(doc, scratch, 1u, &deferred) == 0 && deferred == 1); /* same frame: still waiting */
    CHECK(spdf_win_annot_sync(doc, scratch, 2u, &deferred) == 2 && deferred == 0);
    CHECK(spdf_win_annot_sync(doc, scratch, 3u, &deferred) == 2 && deferred == 0); /* cached */
    comments = spdf_win_annot_comments();
    CHECK(comments && comments->count == 2);
    for (i = 0; i < comments->count; ++i) {
        const spdf_comment_item* it = &comments->items[i];
        if (it->text && strcmp(it->text, "Check this figure") == 0) hl = it;
        if (it->text && strcmp(it->text, "A note") == 0) note = it;
    }
    CHECK(hl && note);
    if (!hl || !note) return 1;
    CHECK(hl->page_index == 0 && note->page_index == 0);
    CHECK(strcmp(hl->author, "Rapha\xc3\xabl") == 0 && strcmp(note->author, "Tester") == 0);
    CHECK(spdf_win_annot_item(hl->index) == hl && spdf_win_annot_item(note->index) == note);
    CHECK(spdf_win_annot_item(99) == NULL);
    /* The highlight's bounds are the union of its quads; the note is the core's 24 pt square. */
    CHECK(near_f(hl->bounds.x0, 72.0f, 1.5f) && near_f(hl->bounds.x1, 300.0f, 1.5f));
    CHECK(near_f(hl->bounds.y0, 100.0f, 1.5f) && near_f(hl->bounds.y1, 126.0f, 1.5f));
    CHECK(near_f(note->bounds.x0, 400.0f, 1.5f) && near_f(note->bounds.y0, 500.0f, 1.5f));

    /* --- geometry: one page drawn at zoom 2 with its slot at (30, 40), the
     * canvas rect at client (245, 84) ------------------------------------- */
    memset(&page, 0, sizeof(page));
    page.page_index = 0;
    page.dest_x = 30.0f;
    page.dest_y = 40.0f;
    page.dest_w = 612.0f * zoom;
    page.dest_h = 792.0f * zoom;
    memset(&scene, 0, sizeof(scene));
    scene.pages = &page;
    scene.page_count = 1;
    spdf_win_annot_publish_geometry(&scene, 245.0f, 84.0f, zoom);
    marks = spdf_win_annot_marks(&mark_count);
    CHECK(marks && mark_count == 2);
    if (marks && mark_count == 2) {
        const SpdfWinAnnotMark* m = marks[0].comment_index == hl->index ? &marks[0] : &marks[1];
        spdf_rect badge = spdf_win_annot_badge(&hl->bounds);
        CHECK(m->comment_index == hl->index && m->page_index == 0);
        /* bounds + 3 pt, through the zoom, plus the slot, plus the canvas origin. */
        CHECK(near_f(m->x0, 245.0f + 30.0f + (hl->bounds.x0 - 3.0f) * zoom, 0.01f));
        CHECK(near_f(m->y1, 84.0f + 40.0f + (hl->bounds.y1 + 3.0f) * zoom, 0.01f));
        CHECK(near_f(m->bx0, 245.0f + 30.0f + (badge.x0 - 2.0f) * zoom, 0.01f));
        CHECK(near_f(m->by0, 84.0f + 40.0f + (badge.y0 - 2.0f) * zoom, 0.01f));
    }
    /* The inverse mapping: the badge's centre comes back inside page 0 at the
     * badge's centre in points; a point off the page does not resolve. */
    {
        spdf_rect badge = spdf_win_annot_badge(&note->bounds);
        float cx = 245.0f + 30.0f + (badge.x0 + 6.0f) * zoom;
        float cy = 84.0f + 40.0f + (badge.y0 + 6.0f) * zoom;
        CHECK(spdf_win_annot_client_to_page(cx, cy, &page_index, &px, &py));
        CHECK(page_index == 0 && near_f(px, badge.x0 + 6.0f, 0.01f) && near_f(py, badge.y0 + 6.0f, 0.01f));
        CHECK(!spdf_win_annot_client_to_page(10.0f, 10.0f, &page_index, &px, &py) && page_index == -1);
    }

    /* --- overlays: appended after a base, canvas-local, frames then badges -- */
    memset(base, 0, sizeof(base));
    base[0].kind = SPDF_WIN_OVERLAY_SELECTION;
    base[0].x = 1.0f;
    base[0].y = 2.0f;
    base[0].w = 3.0f;
    base[0].h = 4.0f;
    scene.overlays = base;
    scene.overlay_count = 1;
    spdf_win_annot_apply_overlays(&scene, zoom);
    CHECK(scene.overlay_count == 5 && scene.overlays != base);
    if (scene.overlay_count == 5) {
        CHECK(scene.overlays[0].kind == SPDF_WIN_OVERLAY_SELECTION && scene.overlays[0].w == 3.0f);
        CHECK(scene.overlays[1].kind == SPDF_WIN_OVERLAY_COMMENT && scene.overlays[2].kind == SPDF_WIN_OVERLAY_COMMENT);
        CHECK(scene.overlays[3].kind == SPDF_WIN_OVERLAY_COMMENT_BADGE &&
              scene.overlays[4].kind == SPDF_WIN_OVERLAY_COMMENT_BADGE);
        /* Canvas-local: the slot, not the client origin. */
        for (i = 1; i < 5; ++i) {
            const spdf_win_overlay* o = &scene.overlays[i];
            CHECK(o->page_index == 0 && o->x >= 30.0f && o->y >= 40.0f);
            CHECK(o->x + o->w <= 30.0f + 612.0f * zoom + 8.0f * zoom); /* inside the slot (a badge may overhang 8 pt) */
            CHECK(o->w > 0.0f && o->h > 0.0f && o->alpha == 1.0f);
        }
        /* The highlight's frame is its bounds through the slot, no client origin. */
        CHECK(near_f(scene.overlays[1].x, 30.0f + hl->bounds.x0 * zoom, 0.01f) ||
              near_f(scene.overlays[2].x, 30.0f + hl->bounds.x0 * zoom, 0.01f));
        CHECK(near_f(scene.overlays[3].w, 12.0f * zoom, 0.01f) && near_f(scene.overlays[3].h, 12.0f * zoom, 0.01f));
    }
    /* A scene with no pages gets no overlays and keeps its base. */
    scene.pages = NULL;
    scene.page_count = 0;
    scene.overlays = base;
    scene.overlay_count = 1;
    spdf_win_annot_apply_overlays(&scene, zoom);
    CHECK(scene.overlays == base && scene.overlay_count == 1);

    /* --- the Comments section's rows ------------------------------------ */
    view = spdf_win_annot_sidebar_build(NULL, 400.0f, 1.0f);
    CHECK(view && view->row_count == 3); /* "Page 1", then the two comments */
    if (view && view->row_count == 3) {
        CHECK(view->rows[0].kind == SPDF_WIN_SIDEBAR_RESULT_HEADER && wcscmp(view->rows[0].title, L"Page 1") == 0);
        CHECK(view->rows[1].kind == SPDF_WIN_SIDEBAR_RESULT_MATCH && view->rows[2].kind == SPDF_WIN_SIDEBAR_RESULT_MATCH);
        CHECK(view->rows[1].bold_start == -1 && view->current_row == -1);
        /* Row order is the core's order; find the highlight's row by index. */
        for (i = 1; i < 3; ++i) {
            if (view->rows[i].match_index == hl->index) {
                CHECK(wcscmp(view->rows[i].title, L"Rapha\x00ebl: Check this figure") == 0);
                CHECK(wcsstr(view->rows[i].subtitle, L"Page 1") != NULL);
            } else {
                CHECK(view->rows[i].match_index == note->index);
                CHECK(wcscmp(view->rows[i].title, L"Tester: A note") == 0);
            }
        }
        /* A list-local y inside the header is nothing; inside a row is its comment. */
        CHECK(spdf_win_annot_sidebar_comment_at(10.0f, 1.0f) == -1);
        CHECK(spdf_win_annot_sidebar_comment_at(30.0f + 5.0f, 1.0f) == view->rows[1].match_index);
        CHECK(spdf_win_annot_sidebar_comment_at(30.0f + 46.0f + 5.0f, 1.0f) == view->rows[2].match_index);
        CHECK(spdf_win_annot_sidebar_comment_at(30.0f + 92.0f + 5.0f, 1.0f) == -1);
    }
    /* The hovered comment is the current row. */
    spdf_win_annot_set_hover(note->index);
    view = spdf_win_annot_sidebar_build(NULL, 400.0f, 1.0f);
    CHECK(view && view->current_row >= 1 && view->rows[view->current_row].match_index == note->index);
    spdf_win_annot_set_hover(-1);
    /* The filter matches the author, case- and diacritic-insensitively, and
     * the page number through "p.N"; a miss leaves the header out too. */
    view = spdf_win_annot_sidebar_build(L"raphael", 400.0f, 1.0f);
    CHECK(view && view->row_count == 2 && view->rows[1].match_index == hl->index);
    view = spdf_win_annot_sidebar_build(L"p.1", 400.0f, 1.0f);
    CHECK(view && view->row_count == 3);
    view = spdf_win_annot_sidebar_build(L"nothing here", 400.0f, 1.0f);
    CHECK(view && view->row_count == 0);
    view = spdf_win_annot_sidebar_build(NULL, 400.0f, 1.0f);
    CHECK(view && view->row_count == 3);
    /* The list scrolls only as far as its content overflows. */
    CHECK(spdf_win_annot_sidebar_scroll_by(100.0f, 400.0f, 1.0f) == 0);
    CHECK(spdf_win_annot_sidebar_scroll_by(100.0f, 60.0f, 1.0f) == 1);
    view = spdf_win_annot_sidebar_build(NULL, 60.0f, 1.0f);
    CHECK(view && near_f(view->scroll_y, 30.0f + 46.0f * 2.0f - 60.0f, 0.01f));
    CHECK(spdf_win_annot_sidebar_scroll_by(-1000.0f, 60.0f, 1.0f) == 1);

    /* --- a write invalidates; the next sync reloads at once ------------- */
    CHECK(spdf_delete_comment(doc, note->index, err, sizeof(err)));
    CHECK(spdf_save_document(doc, scratch, err, sizeof(err)));
    spdf_win_annot_invalidate();
    CHECK(spdf_win_annot_sync(doc, scratch, 4u, &deferred) == 1 && deferred == 0);
    view = spdf_win_annot_sidebar_build(NULL, 400.0f, 1.0f);
    CHECK(view && view->row_count == 2);
    /* And a changed stat with no invalidate is noticed too. */
    {
        spdf_document* other = spdf_open(scratch, err, sizeof(err));
        CHECK(other != NULL);
        if (other) {
            CHECK(spdf_add_text_comment(other, 0, 100.0f, 600.0f, "External", "X", err, sizeof(err)));
            Sleep(30); /* a distinct last-write time */
            CHECK(spdf_save_document(other, scratch, err, sizeof(err)));
            spdf_close(other);
        }
        /* The cached handle predates the write, so the count it reports is
         * whatever ITS bytes say -- the point is that the reload happened. */
        CHECK(spdf_win_annot_sync(doc, scratch, 5u, &deferred) >= 1 && deferred == 0);
    }
    /* No document releases everything. */
    CHECK(spdf_win_annot_sync(NULL, NULL, 6u, &deferred) == 0);
    CHECK(spdf_win_annot_comments()->count == 0);
    CHECK(spdf_win_annot_sidebar_build(NULL, 400.0f, 1.0f) == NULL);

    spdf_close(doc);
    remove(scratch);
    printf("[annot_comments_test] %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
