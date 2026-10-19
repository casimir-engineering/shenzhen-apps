/* spdf_win_annot.cpp — see spdf_win_annot.h for what this is and why it is
 * shaped this way. UI thread only, like every consumer of the cache. */
#include "spdf_win_annot.h"

#include "spdf_win_annot_model.h"
#include "spdf_win_chrome_content.h"   /* spdf_win_sidebar_title_matches, spdf_win_sidebar_utf16_from_utf8 */
#include "spdf_win_sidebar_results.h"  /* spdf_win_sidebar_group_append */

#include <stdlib.h>
#include <string.h>

namespace {

/* --- the cache ------------------------------------------------------------ */

struct Cache {
    spdf_document* doc;
    char* path;
    spdf_comments comments;
    int loaded;
    int dirty;
    /* The frame the document was first seen in; the load waits for a later
     * one (spdf_win_annot.h, "NOTHING HERE RUNS ON THE FIRST PAINT"). */
    unsigned armed_frame;
    int armed;
    /* The file's stat at load time, so an external rewrite (which the watcher
     * turns into a fresh document at the same or another address) re-reads. */
    unsigned long long size;
    unsigned long long mtime;
    unsigned revision; /* bumped on every (re)load; the row builder keys on it */
    int hover;
};

Cache g_cache = {NULL, NULL, {NULL, 0}, 0, 0, 0u, 0, 0ull, 0ull, 0u, -1};

int stat_path(const char* utf8_path, unsigned long long* size, unsigned long long* mtime) {
    wchar_t wide[1024];
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!utf8_path || !*utf8_path) return 0;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8_path, -1, wide, (int)(sizeof(wide) / sizeof(wide[0]))) <= 0) return 0;
    if (!GetFileAttributesExW(wide, GetFileExInfoStandard, &fad)) return 0;
    *size = ((unsigned long long)fad.nFileSizeHigh << 32) | fad.nFileSizeLow;
    *mtime = ((unsigned long long)fad.ftLastWriteTime.dwHighDateTime << 32) | fad.ftLastWriteTime.dwLowDateTime;
    return 1;
}

void cache_release(Cache* c) {
    if (c->comments.items) spdf_free_comments(&c->comments);
    memset(&c->comments, 0, sizeof(c->comments));
    free(c->path);
    c->path = NULL;
    c->doc = NULL;
    c->loaded = 0;
    c->dirty = 0;
    c->armed = 0;
    c->hover = -1;
}

int same_document(const Cache* c, spdf_document* doc, const char* path) {
    if (c->doc != doc) return 0;
    if ((c->path == NULL) != (path == NULL)) return 0;
    return !path || strcmp(c->path, path) == 0;
}

void cache_load(Cache* c) {
    char err[512] = {0};
    if (c->comments.items) spdf_free_comments(&c->comments);
    memset(&c->comments, 0, sizeof(c->comments));
    if (c->doc && !spdf_load_comments(c->doc, &c->comments, err, sizeof(err))) memset(&c->comments, 0, sizeof(c->comments));
    c->loaded = 1;
    c->dirty = 0;
    c->armed = 0;
    c->hover = -1;
    c->revision++;
    if (!stat_path(c->path, &c->size, &c->mtime)) {
        c->size = 0;
        c->mtime = 0;
    }
}

/* Point the cache at (doc, path); returns 1 when that is a new document. */
int cache_target(Cache* c, spdf_document* doc, const char* path) {
    if (same_document(c, doc, path)) return 0;
    cache_release(c);
    c->doc = doc;
    c->path = path ? _strdup(path) : NULL;
    return 1;
}

int cache_stat_changed(const Cache* c) {
    unsigned long long size = 0, mtime = 0;
    if (!c->loaded || !c->path) return 0;
    if (!stat_path(c->path, &size, &mtime)) return 0;
    return size != c->size || mtime != c->mtime;
}

/* --- this paint's geometry ------------------------------------------------ */

/* A drawn page's slot in CANVAS-LOCAL px (what the scene carries and what the
 * overlays want); the canvas rect's client origin is kept beside them and
 * added only where a CLIENT point or rect is wanted (the marks, the inverse
 * mapping). One origin for all frames, one place to add it. */
struct Frame {
    int page;
    float x, y, w, h;
};

Frame* g_frames;
int g_frame_count, g_frame_cap;
float g_zoom = 1.0f;
float g_origin_x, g_origin_y;
SpdfWinAnnotMark* g_marks;
int g_mark_count, g_mark_cap;
spdf_win_overlay* g_overlays;
int g_overlay_cap;

template <typename T>
int grow(T** buf, int* cap, int want) {
    T* next;
    if (want <= *cap) return 1;
    next = (T*)realloc(*buf, sizeof(T) * (size_t)want);
    if (!next) return 0;
    *buf = next;
    *cap = want;
    return 1;
}

const Frame* frame_for(int page) {
    int i;
    for (i = 0; i < g_frame_count; ++i)
        if (g_frames[i].page == page) return &g_frames[i];
    return NULL;
}

/* A page-space rect to client px through a frame, `slop_pt` added on every
 * side in page points first. */
void rect_to_client(const Frame* f, const spdf_rect* r, float slop_pt, float zoom, float* x0, float* y0, float* x1,
                    float* y1) {
    float rx0 = (r->x0 < r->x1 ? r->x0 : r->x1) - slop_pt;
    float rx1 = (r->x0 > r->x1 ? r->x0 : r->x1) + slop_pt;
    float ry0 = (r->y0 < r->y1 ? r->y0 : r->y1) - slop_pt;
    float ry1 = (r->y0 > r->y1 ? r->y0 : r->y1) + slop_pt;
    *x0 = f->x + rx0 * zoom;
    *x1 = f->x + rx1 * zoom;
    *y0 = f->y + ry0 * zoom;
    *y1 = f->y + ry1 * zoom;
}

/* --- the Comments section ------------------------------------------------- */

struct Rows {
    SpdfWinSidebarResultRow* rows;
    int count, cap;
    wchar_t* arena;
    size_t arena_cap, used;
    SpdfWinSidebarResultsView view;
    float scroll_y;
    unsigned built_revision;
    int built;
    wchar_t filter[128];
};

Rows g_rows;

const wchar_t* arena_put(Rows* r, const wchar_t* text) {
    size_t n = wcslen(text) + 1;
    wchar_t* dst;
    if (r->used + n > r->arena_cap) return L"";
    dst = r->arena + r->used;
    memcpy(dst, text, n * sizeof(wchar_t));
    r->used += n;
    return dst;
}

void rows_rebuild(Rows* r, const Cache* c, const wchar_t* filter) {
    SpdfWinSidebarGroupRow* group;
    int group_count = 0, group_cap, prev = SPDF_WIN_SIDEBAR_NO_CHAPTER;
    int i;

    r->count = 0;
    r->used = 0;
    r->built = 1;
    r->built_revision = c->revision;
    wcsncpy_s(r->filter, filter ? filter : L"", _TRUNCATE);
    if (!c->loaded || c->comments.count <= 0) return;

    group_cap = c->comments.count * 2 + 1;
    if (!grow(&r->rows, &r->cap, group_cap)) return;
    if (r->arena_cap < (size_t)group_cap * 600u) {
        wchar_t* next = (wchar_t*)realloc(r->arena, sizeof(wchar_t) * (size_t)group_cap * 600u);
        if (!next) return;
        r->arena = next;
        r->arena_cap = (size_t)group_cap * 600u;
    }
    group = (SpdfWinSidebarGroupRow*)malloc(sizeof(SpdfWinSidebarGroupRow) * (size_t)group_cap);
    if (!group) return;

    for (i = 0; i < c->comments.count; ++i) {
        const spdf_comment_item* item = &c->comments.items[i];
        char hay8[1400];
        wchar_t hay[1400];
        int written, k;
        if (item->index < 0) continue;
        if (filter && filter[0]) {
            spdf_win_annot_filter_haystack(item, hay8, sizeof(hay8));
            spdf_win_sidebar_utf16_from_utf8(hay8, hay, (int)(sizeof(hay) / sizeof(hay[0])));
            if (!spdf_win_sidebar_title_matches(hay, filter)) continue;
        }
        /* The grouping rule over pages: chapter_index = page, has_outline = 1
         * so a header always precedes the first comment of a page. */
        written = spdf_win_sidebar_group_append(group, &group_count, group_cap, &prev, item->page_index, 1, i);
        for (k = group_count - written; k < group_count; ++k) {
            SpdfWinSidebarResultRow* row = &r->rows[r->count];
            memset(row, 0, sizeof(*row));
            row->match_index = -1;
            row->bold_start = -1;
            if (group[k].is_header) {
                wchar_t title[32];
                _snwprintf_s(title, _TRUNCATE, L"Page %d", group[k].value + 1);
                row->kind = SPDF_WIN_SIDEBAR_RESULT_HEADER;
                row->title = arena_put(r, title);
            } else {
                char utf8[1100];
                wchar_t wide[1100];
                const spdf_comment_item* it = &c->comments.items[group[k].value];
                row->kind = SPDF_WIN_SIDEBAR_RESULT_MATCH;
                row->match_index = it->index;
                spdf_win_annot_row_title(it, utf8, sizeof(utf8));
                spdf_win_sidebar_utf16_from_utf8(utf8, wide, (int)(sizeof(wide) / sizeof(wide[0])));
                row->title = arena_put(r, wide);
                _snprintf_s(utf8, sizeof(utf8), _TRUNCATE, "%s - Page %d",
                            it->type && *it->type ? it->type : "Comment", it->page_index + 1);
                spdf_win_sidebar_utf16_from_utf8(utf8, wide, (int)(sizeof(wide) / sizeof(wide[0])));
                row->subtitle = arena_put(r, wide);
            }
            r->count++;
        }
    }
    free(group);
}

int rows_current(const Rows* r, int comment_index) {
    int i;
    if (comment_index < 0) return -1;
    for (i = 0; i < r->count; ++i)
        if (r->rows[i].kind == SPDF_WIN_SIDEBAR_RESULT_MATCH && r->rows[i].match_index == comment_index) return i;
    return -1;
}

} /* namespace */

/* --- the cache ---------------------------------------------------------------- */

int spdf_win_annot_sync(spdf_document* doc, const char* utf8_path, unsigned frame, int* out_deferred) {
    Cache* c = &g_cache;
    if (out_deferred) *out_deferred = 0;
    if (!doc) {
        cache_release(c);
        return 0;
    }
    if (cache_target(c, doc, utf8_path) || (!c->loaded && !c->armed && !c->dirty)) {
        /* First sight of this document: arm, and load on a LATER frame. */
        c->armed = 1;
        c->armed_frame = frame;
        if (out_deferred) *out_deferred = 1;
        return 0;
    }
    if (c->loaded && !c->dirty && cache_stat_changed(c)) c->dirty = 1;
    if (c->dirty) {
        cache_load(c);
        return c->comments.count;
    }
    if (c->armed) {
        if (frame == c->armed_frame) {
            if (out_deferred) *out_deferred = 1;
            return 0;
        }
        cache_load(c);
    }
    return c->loaded ? c->comments.count : 0;
}

int spdf_win_annot_count(spdf_document* doc, const char* utf8_path) {
    Cache* c = &g_cache;
    if (!doc) return 0;
    cache_target(c, doc, utf8_path);
    if (!c->loaded || c->dirty || cache_stat_changed(c)) cache_load(c);
    return c->comments.count;
}

void spdf_win_annot_invalidate(void) {
    g_cache.dirty = 1;
    g_cache.hover = -1;
}

const spdf_comments* spdf_win_annot_comments(void) { return &g_cache.comments; }

const spdf_comment_item* spdf_win_annot_item(int comment_index) {
    if (!g_cache.loaded) return NULL;
    return spdf_win_annot_item_for_index(g_cache.comments.items, g_cache.comments.count, comment_index);
}

void spdf_win_annot_set_hover(int comment_index) { g_cache.hover = comment_index; }
int spdf_win_annot_hover(void) { return g_cache.hover; }

/* --- this paint's geometry ------------------------------------------------------ */

void spdf_win_annot_publish_geometry(const spdf_win_scene* scene, float canvas_x, float canvas_y, float zoom) {
    const Cache* c = &g_cache;
    int i;
    g_frame_count = 0;
    g_mark_count = 0;
    g_zoom = zoom > 0.0f ? zoom : 1.0f;
    g_origin_x = canvas_x;
    g_origin_y = canvas_y;
    if (!scene || !scene->pages || scene->page_count <= 0) return;
    if (!grow(&g_frames, &g_frame_cap, scene->page_count)) return;
    for (i = 0; i < scene->page_count; ++i) {
        const spdf_win_page_draw* d = &scene->pages[i];
        Frame* f = &g_frames[g_frame_count];
        if (!(d->dest_w > 0.0f && d->dest_h > 0.0f)) continue;
        f->page = d->page_index;
        f->x = d->dest_x;
        f->y = d->dest_y;
        f->w = d->dest_w;
        f->h = d->dest_h;
        g_frame_count++;
    }
    if (!c->loaded || c->comments.count <= 0) return;
    if (!grow(&g_marks, &g_mark_cap, c->comments.count)) return;
    for (i = 0; i < c->comments.count; ++i) {
        const spdf_comment_item* item = &c->comments.items[i];
        const Frame* f;
        SpdfWinAnnotMark* m;
        spdf_rect badge;
        if (item->index < 0 || !spdf_win_annot_bounds_have_area(&item->bounds)) continue;
        f = frame_for(item->page_index);
        if (!f) continue;
        m = &g_marks[g_mark_count++];
        m->comment_index = item->index;
        m->page_index = item->page_index;
        rect_to_client(f, &item->bounds, SPDF_WIN_ANNOT_COMMENT_HIT_SLOP_PT, g_zoom, &m->x0, &m->y0, &m->x1, &m->y1);
        badge = spdf_win_annot_badge(&item->bounds);
        rect_to_client(f, &badge, SPDF_WIN_ANNOT_BADGE_HIT_SLOP_PT, g_zoom, &m->bx0, &m->by0, &m->bx1, &m->by1);
        /* Client px: the canvas origin, once, here. */
        m->x0 += g_origin_x;
        m->x1 += g_origin_x;
        m->bx0 += g_origin_x;
        m->bx1 += g_origin_x;
        m->y0 += g_origin_y;
        m->y1 += g_origin_y;
        m->by0 += g_origin_y;
        m->by1 += g_origin_y;
    }
}

const SpdfWinAnnotMark* spdf_win_annot_marks(int* out_count) {
    if (out_count) *out_count = g_mark_count;
    return g_mark_count > 0 ? g_marks : NULL;
}

int spdf_win_annot_client_to_page(float client_x, float client_y, int* page_index, float* page_x, float* page_y) {
    int i;
    if (page_index) *page_index = -1;
    if (page_x) *page_x = 0.0f;
    if (page_y) *page_y = 0.0f;
    for (i = 0; i < g_frame_count; ++i) {
        const Frame* f = &g_frames[i];
        float x = client_x - g_origin_x, y = client_y - g_origin_y; /* canvas-local */
        if (x < f->x || x > f->x + f->w || y < f->y || y > f->y + f->h) continue;
        if (page_index) *page_index = f->page;
        if (page_x) *page_x = (x - f->x) / g_zoom;
        if (page_y) *page_y = (y - f->y) / g_zoom;
        return 1;
    }
    return 0;
}

void spdf_win_annot_apply_overlays(spdf_win_scene* scene, float zoom) {
    const Cache* c = &g_cache;
    int i, n = 0, base;
    float z = zoom > 0.0f ? zoom : 1.0f;
    if (!scene || !scene->pages || scene->page_count <= 0 || !c->loaded || c->comments.count <= 0) return;
    for (i = 0; i < c->comments.count; ++i) {
        const spdf_comment_item* item = &c->comments.items[i];
        if (item->index >= 0 && spdf_win_annot_bounds_have_area(&item->bounds) && frame_for(item->page_index)) ++n;
    }
    if (n <= 0) return;
    base = scene->overlays && scene->overlay_count > 0 ? scene->overlay_count : 0;
    if (!grow(&g_overlays, &g_overlay_cap, base + 2 * n)) return; /* the base overlays stay untouched */
    if (base > 0 && scene->overlays != g_overlays) memcpy(g_overlays, scene->overlays, sizeof(spdf_win_overlay) * (size_t)base);
    n = base;
    /* Frames first, then every badge on top, as GTK draws the badges last. */
    for (i = 0; i < c->comments.count; ++i) {
        const spdf_comment_item* item = &c->comments.items[i];
        const Frame* f;
        spdf_win_overlay* o;
        float x0, y0, x1, y1;
        if (item->index < 0 || !spdf_win_annot_bounds_have_area(&item->bounds)) continue;
        f = frame_for(item->page_index);
        if (!f) continue;
        /* Canvas-local, like every other producer's: the frames are. */
        rect_to_client(f, &item->bounds, 0.0f, z, &x0, &y0, &x1, &y1);
        o = &g_overlays[n++];
        o->page_index = item->page_index;
        o->x = x0;
        o->y = y0;
        o->w = x1 - x0;
        o->h = y1 - y0;
        o->kind = SPDF_WIN_OVERLAY_COMMENT;
        o->alpha = 1.0f;
    }
    for (i = 0; i < c->comments.count; ++i) {
        const spdf_comment_item* item = &c->comments.items[i];
        const Frame* f;
        spdf_win_overlay* o;
        spdf_rect badge;
        float x0, y0, x1, y1;
        if (item->index < 0 || !spdf_win_annot_bounds_have_area(&item->bounds)) continue;
        f = frame_for(item->page_index);
        if (!f) continue;
        badge = spdf_win_annot_badge(&item->bounds);
        rect_to_client(f, &badge, 0.0f, z, &x0, &y0, &x1, &y1);
        o = &g_overlays[n++];
        o->page_index = item->page_index;
        o->x = x0;
        o->y = y0;
        o->w = x1 - x0;
        o->h = y1 - y0;
        o->kind = SPDF_WIN_OVERLAY_COMMENT_BADGE;
        o->alpha = 1.0f;
    }
    scene->overlays = g_overlays;
    scene->overlay_count = n;
}

/* --- the Comments section ------------------------------------------------------- */

const SpdfWinSidebarResultsView* spdf_win_annot_sidebar_build(const wchar_t* filter, float list_h_px,
                                                              float dpi_scale) {
    Rows* r = &g_rows;
    const Cache* c = &g_cache;
    float max;
    if (!c->loaded) return NULL;
    if (!r->built || r->built_revision != c->revision || wcscmp(r->filter, filter ? filter : L"") != 0)
        rows_rebuild(r, c, filter);
    r->view.rows = r->rows;
    r->view.row_count = r->count;
    r->view.current_row = rows_current(r, c->hover);
    max = spdf_win_sidebar_results_max_scroll(&r->view, list_h_px, dpi_scale);
    if (r->scroll_y > max) r->scroll_y = max;
    if (r->scroll_y < 0.0f) r->scroll_y = 0.0f;
    r->view.scroll_y = r->scroll_y;
    return &r->view;
}

int spdf_win_annot_sidebar_scroll_by(float dy, float list_h_px, float dpi_scale) {
    Rows* r = &g_rows;
    float max = spdf_win_sidebar_results_max_scroll(&r->view, list_h_px, dpi_scale);
    float want = r->scroll_y + dy;
    if (want > max) want = max;
    if (want < 0.0f) want = 0.0f;
    if (want == r->scroll_y) return 0;
    r->scroll_y = want;
    r->view.scroll_y = want;
    return 1;
}

int spdf_win_annot_sidebar_comment_at(float local_y, float dpi_scale) {
    const Rows* r = &g_rows;
    int row = spdf_win_sidebar_results_row_at(&r->view, local_y, dpi_scale);
    if (row < 0 || r->view.rows[row].kind != SPDF_WIN_SIDEBAR_RESULT_MATCH) return -1;
    return r->view.rows[row].match_index;
}
