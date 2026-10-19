/* The minimap: the real page strip, with real thumbnails.
 *
 * macOS (portable/mac/SPDFMacMinimapView.mm, its theme half in
 * SPDFMacMinimapViewTheme.mm since 61070e502):
 *   - Background is the READING theme's gutter (stripBackgroundColor: the
 *     theme's viewportBackgroundColor in dark, windowBackgroundColor in light)
 *     plus a 1 pt separatorColor line at x = 0 (:728-732).
 *   - Strip layout (:308-343): usable width boundsWidth - 18.0, inter-page gap
 *     4.0, top inset 8.0 when scrolled or vertically CENTRED when the strip
 *     fits. Scale comes from the MEDIAN page width with any single page capped
 *     at kMinimapMaxWidthRatio = 2.5x the median (:113, :139-147); each page
 *     centred horizontally, aspect preserved.
 *   - Per page: the theme's PAPER (pageFillColor -- not white, which leaked a
 *     bright sliver under a dark page that fell a fraction short of its slot),
 *     then the thumbnail at NSImageInterpolationLow, or a placeholder of ruled
 *     lines at calibratedWhite 0.76 (light) / 0.62 (dark) @0.34, then in dark
 *     the same 1 px paperBorderColor frame a PDF page gets
 *     (drawPageBorderInRect:, half-pixel inset so the stroke sits on the pixel
 *     grid); light draws a shadow on the canvas and nothing here.
 *     spdf_win_chrome_theme.h's minimap_* roles carry those four colours.
 *   - Current-page outline calibratedWhite:0.75 @0.9, rect outset 1 pt,
 *     lineWidth 1.5 -- deliberately GREY so it does not compete with the
 *     viewport box, which is the accent (:664-675).
 *   - Viewport rectangle: fill calibrated(0.18, 0.55, 0.92, 0.18) radius 4,
 *     stroke controlAccentColor lineWidth 1.2, clipped to
 *     NSInsetRect(bounds, 1, 1) (:776-786).
 *
 * All of the arithmetic lives in spdf_win_minimap.h, ported from the GTK4
 * frontend's toolkit-free version of the same and differentially tested against
 * it. This file is drawing only.
 *
 * THUMBNAILS ARE NOT RENDERED HERE. `content->thumb` is a LOOKUP against
 * spdf_win_chrome_thumbs.h's store; a page with no thumbnail yet draws the
 * placeholder and the frame goes out. `content->request` tells the store which
 * pages are visible so its bounded window can follow and queue what is missing
 * on spdf_win_render.h's worker pool. Nothing on this path can block, and
 * nothing on this path can call the core.
 *
 * SEARCH MARKERS are drawn in the strip the way the GTK4 minimap draws them
 * (spdf_minimap.c minimap_draw_marker_tick): a 3 px tick inside the page's slot
 * at the match's fraction of the page height, the scroller heat-map's own two
 * lane colours, the current match drawn last and on top. The marks arrive
 * published (spdf_win_search_map.h) because this painter cannot reach the find
 * session; the frame this paint drew is recorded the same way for the input
 * layer, so a click lands on the page that was under the pointer.
 */
#include "spdf_win_chrome_panels.h"
#include "spdf_win_minimap.h"
#include "spdf_win_search_map.h"

#include <math.h>
#include <string.h>

/* --- the side channels (declared in spdf_win_search_map.h) ----------------- */

namespace {
SpdfWinMapFrame g_frame;
int g_frame_valid;
const SpdfWinFindPageMark* g_marks;
int g_mark_count;
int g_mark_active = -1;
} /* namespace */

int spdf_win_map_frame_current(SpdfWinMapFrame* out) {
    if (!g_frame_valid) return 0;
    if (out) *out = g_frame;
    return 1;
}

void spdf_win_map_marks_publish(const SpdfWinFindPageMark* marks, int count, int active) {
    g_marks = count > 0 ? marks : NULL;
    g_mark_count = marks ? count : 0;
    g_mark_active = g_marks && active >= 0 && active < g_mark_count ? active : -1;
}

const SpdfWinFindPageMark* spdf_win_map_marks_current(int* out_count, int* out_active) {
    if (out_count) *out_count = g_mark_count;
    if (out_active) *out_active = g_mark_active;
    return g_marks;
}

namespace {

float px(double points, float s) {
    return spdf_win_chrome_px(points, s);
}

/* Device bitmaps for the thumbnails the store hands out as RGBA.
 *
 * WHY A CACHE AND NOT A PER-FRAME CreateBitmap. Uploading ten ~100x140 textures
 * every frame is small but it is not nothing, and it is exactly the kind of
 * per-frame allocation architecture.md §9 rules out of the paint path. The cache
 * is a fixed table -- no allocator -- keyed on (page, revision, target): the
 * revision catches a re-rendered thumbnail, and the target catches a device
 * loss or a window resize that rebuilt the render target, after which every
 * bitmap belonging to the old one must go. */
struct BitmapEntry {
    ID2D1RenderTarget* target;
    int page;
    unsigned revision;
    ID2D1Bitmap* bitmap;
};

const int kBitmapCacheSize = 96;
BitmapEntry g_bitmaps[kBitmapCacheSize];
ID2D1RenderTarget* g_bitmap_target;

void drop_all_bitmaps() {
    int i;
    for (i = 0; i < kBitmapCacheSize; ++i) {
        if (g_bitmaps[i].bitmap) g_bitmaps[i].bitmap->Release();
        g_bitmaps[i].bitmap = NULL;
        g_bitmaps[i].target = NULL;
    }
}

/* The core produces RGBA; Direct2D wants BGRA. Same swizzle spdf_win_d2d.cpp's
 * page path does, and for the same reason -- but here it runs ONCE per
 * thumbnail, at cache-fill time, never per frame. */
unsigned char* rgba_to_bgra(const SpdfWinMinimapThumb& t) {
    size_t bytes = (size_t)t.stride * (size_t)t.height;
    unsigned char* out = (unsigned char*)malloc(bytes);
    int y, x;
    if (!out) return NULL;
    for (y = 0; y < t.height; ++y) {
        const unsigned char* src = t.rgba + (size_t)y * (size_t)t.stride;
        unsigned char* dst = out + (size_t)y * (size_t)t.stride;
        for (x = 0; x < t.width; ++x) {
            dst[x * 4 + 0] = src[x * 4 + 2];
            dst[x * 4 + 1] = src[x * 4 + 1];
            dst[x * 4 + 2] = src[x * 4 + 0];
            dst[x * 4 + 3] = src[x * 4 + 3];
        }
    }
    return out;
}

ID2D1Bitmap* device_bitmap(ID2D1RenderTarget* target, int page, const SpdfWinMinimapThumb& t) {
    D2D1_BITMAP_PROPERTIES props;
    D2D1_SIZE_U size;
    ID2D1Bitmap* bitmap = NULL;
    unsigned char* bgra;
    int i;
    int slot = -1;

    if (!target || !t.rgba || t.width <= 0 || t.height <= 0 || t.stride < t.width * 4) return NULL;
    if (g_bitmap_target != target) {
        drop_all_bitmaps();
        g_bitmap_target = target;
    }
    for (i = 0; i < kBitmapCacheSize; ++i) {
        if (g_bitmaps[i].bitmap && g_bitmaps[i].page == page && g_bitmaps[i].target == target) {
            if (g_bitmaps[i].revision == t.revision) return g_bitmaps[i].bitmap;
            slot = i; /* same page, stale pixels: replace in place */
            break;
        }
        if (slot < 0 && !g_bitmaps[i].bitmap) slot = i;
    }
    if (slot < 0) slot = page % kBitmapCacheSize; /* full: evict by page, bounded */

    bgra = rgba_to_bgra(t);
    if (!bgra) return NULL;
    size.width = (UINT32)t.width;
    size.height = (UINT32)t.height;
    props.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED;
    props.dpiX = 96.0f;
    props.dpiY = 96.0f;
    {
        HRESULT hr = target->CreateBitmap(size, bgra, (UINT32)t.stride, &props, &bitmap);
        free(bgra);
        if (FAILED(hr)) return NULL;
    }
    if (g_bitmaps[slot].bitmap) g_bitmaps[slot].bitmap->Release();
    g_bitmaps[slot].bitmap = bitmap;
    g_bitmaps[slot].target = target;
    g_bitmaps[slot].page = page;
    g_bitmaps[slot].revision = t.revision;
    return bitmap;
}

/* The strip rects, cached across frames.
 *
 * spdf_win_minimap_strip_compute allocates its rect array, and a 500-page
 * document would then allocate 16 kB on every single frame -- the exact thing
 * architecture.md §9 keeps off the paint path. So the strip is recomputed only
 * when its INPUTS change: page count, panel width, the two insets, and a cheap
 * checksum over the page sizes, which is what changes as the store's sizing
 * sweep replaces fallback sizes with measured ones. The checksum is O(pages) of
 * multiply-add per frame with no allocation and no branches, which is a
 * different order of cost from a calloc plus a full relayout. */
struct StripCache {
    SpdfWinMinimapStrip strip;
    int count;
    double panel_w;
    double side_inset;
    double gap;
    double checksum;
    int valid;
};

StripCache g_strip;

double sizes_checksum(const SpdfWinPageSizePt* sizes, int count) {
    double sum = 0.0;
    int i;
    for (i = 0; i < count; ++i) sum = sum * 1.000001 + sizes[i].width * 31.0 + sizes[i].height;
    return sum;
}

const SpdfWinMinimapStrip* strip_for(const SpdfWinPageSizePt* sizes, int count, double panel_w, double side_inset,
                                     double gap) {
    double checksum = sizes_checksum(sizes, count);
    if (g_strip.valid && g_strip.count == count && g_strip.panel_w == panel_w && g_strip.side_inset == side_inset &&
        g_strip.gap == gap && g_strip.checksum == checksum)
        return &g_strip.strip;
    spdf_win_minimap_strip_compute(&g_strip.strip, sizes, count, panel_w, side_inset, gap);
    g_strip.count = count;
    g_strip.panel_w = panel_w;
    g_strip.side_inset = side_inset;
    g_strip.gap = gap;
    g_strip.checksum = checksum;
    g_strip.valid = 1;
    return &g_strip.strip;
}

/* macOS's placeholder, transcribed rather than approximated (:524-536): the line
 * count, both width factors, the 0.08 top offset, the 0.018 line height and the
 * "stop 2 px from the bottom" rule are all its numbers. */
void draw_placeholder(const SpdfWinChromePaintCtx& ctx, SpdfWinChromeRect r, ID2D1Brush* grey, float s) {
    int lines, i;
    float y, line_h;

    if (r.h < px(6.0, s) || r.w < px(10.0, s) || !grey) return;
    lines = (int)floorf(r.h / px(7.0, s));
    if (lines < 2) lines = 2;
    if (lines > 16) lines = 16;
    y = r.y + spdf_win_chrome_max(px(2.0, s), r.h * 0.08f);
    line_h = spdf_win_chrome_max(1.0f, r.h * 0.018f);
    for (i = 0; i < lines; ++i) {
        float factor = (i % 5 == 4) ? 0.56f : 0.78f;
        ctx.target->FillRectangle(D2D1::RectF(r.x + r.w * 0.12f, y, r.x + r.w * 0.12f + r.w * factor, y + line_h),
                                  grey);
        y += spdf_win_chrome_max(px(3.0, s), r.h / (float)(lines + 2));
        if (y > r.y + r.h - px(2.0, s)) break;
    }
}

/* One search-hit tick inside a page's slot (spdf_minimap.c
 * minimap_draw_marker_tick): x inset 1, at least 1 wide, 3 px tall, placed by
 * the ported spdf_win_minimap_marker_y so it never leaves the slot. */
void draw_tick(const SpdfWinChromePaintCtx& ctx, const SpdfWinRect* slot, float panel_x, float slot_y,
               double fraction, double page_h_pt, ID2D1Brush* brush, float s) {
    float tick_h = px(SPDF_WIN_MINIMAP_MARKER_TICK_H, s);
    double y = spdf_win_minimap_marker_y(slot, fraction * page_h_pt, page_h_pt, (double)tick_h);
    float x0 = panel_x + (float)slot->x + px(1.0, s);
    float w = spdf_win_chrome_max(1.0f, (float)slot->w - px(2.0, s));
    float top = slot_y + (float)(y - slot->y);
    if (!brush) return;
    ctx.target->FillRectangle(D2D1::RectF(x0, top, x0 + w, top + tick_h), brush);
}

void draw_marks(const SpdfWinChromePaintCtx& ctx, const SpdfWinMinimapStrip* strip, const SpdfWinMinimapContent* c,
                SpdfWinChromeRect mm, double content_top, int first, int last, float s) {
    int count = 0, active = -1, i;
    const SpdfWinFindPageMark* marks = spdf_win_map_marks_current(&count, &active);
    ID2D1SolidColorBrush* mark;
    ID2D1SolidColorBrush* hot;
    if (!marks || count <= 0) return;
    mark = spdf_win_chrome_brush(ctx.target, ctx.theme->find_mark);
    hot = spdf_win_chrome_brush(ctx.target, ctx.theme->find_mark_active);
    for (i = 0; i < count; ++i) {
        int page = marks[i].page;
        if (i == active || page < first || page > last || page >= strip->count || page >= c->page_count) continue;
        draw_tick(ctx, &strip->rects[page], mm.x, mm.y + (float)(strip->rects[page].y + content_top),
                  marks[i].fraction, c->sizes[page].height, mark, s);
    }
    if (active >= 0 && active < count) {
        int page = marks[active].page;
        if (page >= first && page <= last && page < strip->count && page < c->page_count)
            draw_tick(ctx, &strip->rects[page], mm.x, mm.y + (float)(strip->rects[page].y + content_top),
                      marks[active].fraction, c->sizes[page].height, hot, s);
    }
    if (mark) mark->Release();
    if (hot) hot->Release();
}

} /* namespace */

void spdf_win_chrome_paint_minimap(const SpdfWinChromePaintCtx& ctx, const SpdfWinMinimapContent* content) {
    SpdfWinChromeRect mm = ctx.layout->minimap;
    const SpdfWinChromeTheme* th = ctx.theme;
    float s = ctx.dpi_scale > 0.0f ? ctx.dpi_scale : 1.0f;
    const SpdfWinMinimapStrip* strip;
    double side_inset = (double)px(SPDF_WIN_MINIMAP_SIDE_INSET, s);
    double gap = (double)px(SPDF_WIN_MINIMAP_GAP, s);
    double content_top;
    int first = 0, last = -1, i;
    ID2D1SolidColorBrush* white; /* the theme's paper: white in light, #1E1E1E in dark */
    ID2D1SolidColorBrush* grey;  /* the placeholder tint */
    ID2D1SolidColorBrush* border; /* the dark theme's 1 px sheet frame; NULL in light */
    ID2D1SolidColorBrush* panel;

    /* Whatever happens below, the frame the INPUT layer hit-tests is this
     * paint's or none: a stale frame from a document that is gone would send
     * a click to a page that no longer exists. */
    g_frame_valid = 0;
    if (spdf_win_chrome_rect_empty(mm)) return;

    /* The reading theme's gutter, not the chrome's panel colour: the strip is
     * the same document on the same paper, and in dark a #1E1E1E sheet on a
     * #202020 panel had no edge at all. */
    panel = spdf_win_chrome_brush(ctx.target, th->minimap_gutter);
    if (panel) {
        ctx.target->FillRectangle(spdf_win_chrome_d2d_rect(mm), panel);
        panel->Release();
    }
    /* macOS draws a 1 pt separator at x = 0 of the minimap view. */
    {
        ID2D1SolidColorBrush* line = spdf_win_chrome_brush(ctx.target, th->separator);
        if (line) {
            float hw = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
            ctx.target->FillRectangle(D2D1::RectF(mm.x, mm.y, mm.x + hw, mm.y + mm.h), line);
            line->Release();
        }
    }

    if (!content || content->page_count <= 0 || !content->sizes) return;

    strip = strip_for(content->sizes, content->page_count, (double)mm.w, side_inset, gap);
    if (strip->count <= 0 || strip->content_h <= 0.0) return;
    content_top =
        spdf_win_minimap_content_top(strip->content_h, (double)mm.h, (double)px(SPDF_WIN_MINIMAP_EDGE_INSET, s),
                                     (double)px(SPDF_WIN_MINIMAP_TOP_PAD, s), content->scroll_fraction);

    /* Which pages are on screen. Everything else is skipped entirely -- the
     * per-frame cost is bounded by the panel's height, not by the page count,
     * which is what lets the strip draw at any document size (:762-770). */
    if (!spdf_win_minimap_strip_visible_range(strip, -content_top, -content_top + (double)mm.h, &first, &last)) {
        first = 0;
        last = -1;
    }

    /* Tell the store what is visible BEFORE drawing, so the pages this frame
     * shows as placeholders are the ones already queued when the next frame
     * arrives. This does not render: it moves a window and posts tasks. */
    if (content->request && last >= first)
        content->request(content->ctx, first, last, (double)mm.w, side_inset, ctx.model && ctx.model->dark);

    ctx.target->PushAxisAlignedClip(spdf_win_chrome_d2d_rect(mm), D2D1_ANTIALIAS_MODE_ALIASED);
    /* The theme's paper and placeholder tint (see the header): white and 0xC2
     * in light, #1E1E1E and 0x9E in dark. */
    white = spdf_win_chrome_brush(ctx.target, th->minimap_paper);
    grey = spdf_win_chrome_brush(ctx.target, th->minimap_placeholder);
    border = th->minimap_draws_page_border ? spdf_win_chrome_brush(ctx.target, th->minimap_page_border) : NULL;

    for (i = first; i <= last && i < strip->count; ++i) {
        SpdfWinChromeRect p;
        SpdfWinMinimapThumb t;
        ID2D1Bitmap* bitmap = NULL;

        p.x = mm.x + (float)strip->rects[i].x;
        p.y = mm.y + (float)(strip->rects[i].y + content_top);
        p.w = (float)strip->rects[i].w;
        p.h = (float)strip->rects[i].h;

        /* Paper first, always: a minimap slot is a picture of paper, and macOS
         * fills the theme's paper before it draws anything into it. */
        if (white) ctx.target->FillRectangle(spdf_win_chrome_d2d_rect(p), white);

        memset(&t, 0, sizeof(t));
        if (content->thumb && content->thumb(content->ctx, i, &t)) bitmap = device_bitmap(ctx.target, i, t);
        if (bitmap) {
            /* NSImageInterpolationLow: the thumbnail is already close to its
             * drawn size, so LINEAR is the equivalent and NEAREST would alias. */
            ctx.target->DrawBitmap(bitmap, spdf_win_chrome_d2d_rect(p), 1.0f,
                                   D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, NULL);
        } else {
            draw_placeholder(ctx, p, grey, s);
        }

        /* Dark draws no paper shadow (a black shadow is invisible on a dark
         * gutter), so without this frame a #1E1E1E sheet has no edge against
         * the gutter and the strip reads as one continuous dark column -- only
         * the selected page, outlined below, stayed visible. Same 1 px frame a
         * PDF page gets, drawn after the content and before the outline
         * (drawPageBorderInRect:). Slots under 3 pt are too small to frame. */
        if (border && p.w >= px(3.0, s) && p.h >= px(3.0, s)) {
            float hair = spdf_win_chrome_stroke_px(SPDF_WIN_CT_HAIRLINE, s);
            ctx.target->DrawRectangle(spdf_win_chrome_stroke_rect(p, hair), border, hair, NULL);
        }

        if (i == content->current_page) {
            /* Light grey, NOT the accent: the accent is the viewport box's
             * colour and the current-page outline must not compete with it. */
            ID2D1SolidColorBrush* outline = spdf_win_chrome_brush(ctx.target, spdf_win_ct_rgb(0xBFBFBFu, 0.9f));
            if (outline) {
                SpdfWinChromeRect o = p;
                float lw = spdf_win_chrome_stroke_px(1.5f, s);
                float inset = px(1.0, s);
                o.x -= inset;
                o.y -= inset;
                o.w += 2.0f * inset;
                o.h += 2.0f * inset;
                ctx.target->DrawRectangle(spdf_win_chrome_stroke_rect(o, lw), outline, lw, NULL);
                outline->Release();
            }
        }
    }
    if (white) white->Release();
    if (grey) grey->Release();
    if (border) border->Release();

    /* The search hits, over the thumbnails and under the viewport box. */
    draw_marks(ctx, strip, content, mm, content_top, first, last, s);

    /* The viewport rectangle. The per-page document rects the accent-narrowing
     * version needs are the canvas's and do not reach this track yet, so this is
     * spdf_win_minimap_viewport_band -- macOS's own fallback branch
     * (:300-306) -- rather than an invented approximation. */
    {
        SpdfWinRect band = spdf_win_minimap_viewport_band((double)mm.w, strip->content_h, content->doc_h,
                                                          content->doc_visible_h, content->scroll_fraction);
        SpdfWinChromeRect vp;

        /* Record what this paint drew for the input layer (spdf_win_search_map.h). */
        g_frame.panel = mm;
        g_frame.content_top = content_top;
        g_frame.strip = strip;
        g_frame.page_count = strip->count;
        g_frame.sizes = content->sizes;
        g_frame.band = band;
        g_frame.dpi_scale = s;
        g_frame_valid = 1;
        ID2D1SolidColorBrush* fill = spdf_win_chrome_brush(ctx.target, spdf_win_ct_rgb(0x2E8CEBu, 0.18f));
        ID2D1SolidColorBrush* stroke = spdf_win_chrome_brush(ctx.target, th->accent);
        vp.x = mm.x + (float)band.x;
        vp.y = mm.y + (float)(band.y + content_top);
        vp.w = (float)band.w;
        vp.h = (float)band.h;
        /* NSInsetRect(bounds, 1, 1): the indicator never touches the panel edge. */
        if (vp.y < mm.y + 1.0f) {
            vp.h -= (mm.y + 1.0f) - vp.y;
            vp.y = mm.y + 1.0f;
        }
        if (vp.y + vp.h > mm.y + mm.h - 1.0f) vp.h = mm.y + mm.h - 1.0f - vp.y;
        if (vp.w > 1.0f && vp.h > 1.0f)
            spdf_win_chrome_panel_fill_rounded(ctx.target, vp, px(4.0, s), fill, stroke,
                                               spdf_win_chrome_stroke_px(1.2f, s));
        if (fill) fill->Release();
        if (stroke) stroke->Release();
    }

    ctx.target->PopAxisAlignedClip();
}
