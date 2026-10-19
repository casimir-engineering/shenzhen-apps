/* spdf_win_md_code.cpp -- see spdf_win_md_code.h. */
#include "spdf_win_md_code.h"

#include "spdf_win_d2d.h" /* spdf_win_scene, spdf_win_page_draw */
#include "spdf_win_md.h"  /* the options generation the override map bumps */

/* The language catalog and the picker's filter predicate. spdf_markdown.h calls
 * itself the subsystem's own header, and everything else in it is indeed
 * internal; the catalog is the exception -- it is what the picker LISTS, so the
 * frontend has to be able to read it. */
#include "spdf_markdown.h"

#include <windows.h>

#include <math.h>
#include <stdio.h>
#include <wchar.h>
#include <stdlib.h>
#include <string.h>

namespace {

#define MD_CODE_MAX_OVERRIDES 512

struct Fence {
    int page_index;  /* -1 when the anchor did not resolve */
    float top_y;     /* page space, PDF points, y down */
    char language[32];
    const char* name; /* borrowed from the catalog, or "Plain Text" */
    char* code;
    size_t code_len;
};

Fence* g_fences;
int g_fence_count;
int g_fence_cap;

spdf_markdown_language_override g_overrides[MD_CODE_MAX_OVERRIDES];
char g_override_ids[MD_CODE_MAX_OVERRIDES][32];
int g_override_count;

int g_copied = -1;
unsigned long long g_copied_ms;

SpdfWinMdCodeMark* g_marks;
int g_mark_count;
int g_mark_cap;
SpdfWinMdCodePill* g_pills;
int g_pill_count;
int g_pill_cap;
/* The titles the pills point at, kept alive between publish and paint. */
wchar_t* g_titles;
int g_title_cap;

template <typename T> int grow(T** slot, int* cap, int want) {
    T* bigger;
    int next;
    if (want <= *cap) return 1;
    next = *cap ? *cap * 2 : 8;
    while (next < want) next *= 2;
    bigger = (T*)realloc(*slot, (size_t)next * sizeof(T));
    if (!bigger) return 0;
    *slot = bigger;
    *cap = next;
    return 1;
}

void clear_fences(void) {
    int i;
    for (i = 0; i < g_fence_count; ++i) free(g_fences[i].code);
    g_fence_count = 0;
    g_mark_count = 0;
    g_pill_count = 0;
    g_copied = -1;
}

/* The override recorded for `index`, or NULL. Last entry wins, so a caller may
 * append rather than rewrite. */
const char* override_for(int index) {
    int i;
    const char* found = NULL;
    for (i = 0; i < g_override_count; ++i)
        if (g_overrides[i].fence_index == index) found = g_overrides[i].language_id;
    return found;
}

const char* display_name(const char* id) {
    int i, n = spdf_markdown_language_count();
    for (i = 0; i < n; ++i) {
        const spdf_markdown_language* l = spdf_markdown_language_at(i);
        if (l && strcmp(l->id, id) == 0) return l->name;
    }
    return "Plain Text";
}

/* Read a whole file, bounded by the core's own Markdown budget. */
char* read_file(const char* path, size_t* len_out) {
    FILE* f = fopen(path, "rb");
    char* buf;
    long n;
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0 || n > 64L * 1024L * 1024L) {
        fclose(f);
        return NULL;
    }
    buf = (char*)malloc((size_t)n + 1);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    buf[n] = '\0';
    *len_out = (size_t)n;
    return buf;
}

const spdf_win_page_draw* frame_for(const spdf_win_scene* scene, int page_index) {
    int i;
    if (!scene || !scene->pages) return NULL;
    for (i = 0; i < scene->page_count; ++i)
        if (scene->pages[i].page_index == page_index && scene->pages[i].dest_w > 0 && scene->pages[i].dest_h > 0)
            return &scene->pages[i];
    return NULL;
}

/* The title, with the disclosure triangle the mac appends (U+25BE). */
int title_for(int fence, wchar_t* out, size_t units) {
    const char* name = spdf_win_md_code_language_name(fence);
    int wrote;
    if (!name) return 0;
    wrote = MultiByteToWideChar(CP_UTF8, 0, name, -1, out, (int)units - 3);
    if (wrote <= 0) return 0;
    wcscat(out, L" \x25BE");
    return (int)wcslen(out);
}

} // namespace

/* --- the document's fences ---------------------------------------------------- */

void spdf_win_md_code_sync(spdf_document* doc, const char* path) {
    spdf_markdown_fences scanned;
    char* text;
    size_t len = 0;
    int i;

    clear_fences();
    if (!doc || !path || !spdf_path_is_markdown(path)) return;
    text = read_file(path, &len);
    if (!text) return;
    if (!spdf_markdown_scan_fences(text, len, &scanned)) {
        free(text);
        return;
    }
    free(text);
    if (scanned.count > 0 && grow(&g_fences, &g_fence_cap, scanned.count)) {
        for (i = 0; i < scanned.count; ++i) {
            const spdf_markdown_fence* s = &scanned.items[i];
            Fence* f = &g_fences[i];
            char uri[64];
            memset(f, 0, sizeof(*f));
            f->page_index = -1;
            snprintf(f->language, sizeof(f->language), "%s",
                     s->language[0] ? s->language : "plain");
            f->name = display_name(f->language);
            f->code = (char*)malloc(s->code_len + 1);
            if (f->code) {
                memcpy(f->code, s->code, s->code_len);
                f->code[s->code_len] = '\0';
                f->code_len = s->code_len;
            }
            snprintf(uri, sizeof(uri), "#%s%d", SPDF_MARKDOWN_CODE_ANCHOR_PREFIX, i);
            spdf_markdown_resolve_anchor(doc, uri, &f->page_index, &f->top_y);
            ++g_fence_count;
        }
    }
    spdf_markdown_free_fences(&scanned);
}

int spdf_win_md_code_count(void) {
    return g_fence_count;
}

const char* spdf_win_md_code_language(int index) {
    const char* over;
    if (index < 0 || index >= g_fence_count) return NULL;
    over = override_for(index);
    return over ? over : g_fences[index].language;
}

const char* spdf_win_md_code_language_name(int index) {
    const char* id = spdf_win_md_code_language(index);
    if (!id) return NULL;
    if (strcmp(id, g_fences[index].language) == 0) return g_fences[index].name;
    return display_name(id);
}

const char* spdf_win_md_code_source(int index, size_t* len_out) {
    if (index < 0 || index >= g_fence_count) return NULL;
    if (len_out) *len_out = g_fences[index].code_len;
    return g_fences[index].code ? g_fences[index].code : "";
}

/* --- the override map --------------------------------------------------------- */

int spdf_win_md_code_set_language(int index, const char* language_id) {
    int i;
    if (index < 0 || !language_id || !language_id[0]) return 0;
    for (i = 0; i < g_override_count; ++i) {
        if (g_overrides[i].fence_index != index) continue;
        if (strcmp(g_override_ids[i], language_id) == 0) return 0; /* already that */
        snprintf(g_override_ids[i], sizeof(g_override_ids[i]), "%s", language_id);
        spdf_win_md_bump_options();
        return 1;
    }
    if (g_override_count >= MD_CODE_MAX_OVERRIDES) return 0;
    i = g_override_count;
    snprintf(g_override_ids[i], sizeof(g_override_ids[i]), "%s", language_id);
    g_overrides[i].fence_index = index;
    g_overrides[i].language_id = g_override_ids[i];
    ++g_override_count;
    spdf_win_md_bump_options();
    return 1;
}

const spdf_markdown_language_override* spdf_win_md_code_overrides(int* out_count) {
    if (out_count) *out_count = g_override_count;
    return g_override_count > 0 ? g_overrides : NULL;
}

void spdf_win_md_code_clear_overrides(void) {
    if (g_override_count == 0) return;
    g_override_count = 0;
    spdf_win_md_bump_options();
}

/* --- the clipboard and the copied feedback ------------------------------------ */

int spdf_win_md_code_copied_at(int armed, unsigned long long armed_ms, unsigned long long now_ms) {
    if (armed < 0) return -1;
    if (now_ms < armed_ms) return armed; /* a wrapped tick counter: keep it up */
    return now_ms - armed_ms < SPDF_WIN_MD_CODE_FEEDBACK_MS ? armed : -1;
}

int spdf_win_md_code_copied(void) {
    g_copied = spdf_win_md_code_copied_at(g_copied, g_copied_ms, GetTickCount64());
    return g_copied;
}

int spdf_win_md_code_copy(int index) {
    size_t len = 0;
    const char* utf8 = spdf_win_md_code_source(index, &len);
    int units;
    HGLOBAL block;
    wchar_t* wide;

    if (!utf8 || len == 0) return 0;
    units = MultiByteToWideChar(CP_UTF8, 0, utf8, (int)len, NULL, 0);
    if (units <= 0) return 0;
    block = GlobalAlloc(GMEM_MOVEABLE, ((size_t)units + 1) * sizeof(wchar_t));
    if (!block) return 0;
    wide = (wchar_t*)GlobalLock(block);
    if (!wide) {
        GlobalFree(block);
        return 0;
    }
    MultiByteToWideChar(CP_UTF8, 0, utf8, (int)len, wide, units);
    wide[units] = L'\0';
    GlobalUnlock(block);

    if (!OpenClipboard(NULL)) {
        GlobalFree(block);
        return 0;
    }
    EmptyClipboard();
    if (!SetClipboardData(CF_UNICODETEXT, block)) {
        CloseClipboard();
        GlobalFree(block); /* still ours: the clipboard refused it */
        return 0;
    }
    CloseClipboard(); /* the clipboard owns `block` now */
    g_copied = index;
    g_copied_ms = GetTickCount64();
    return 1;
}

/* --- pure geometry ------------------------------------------------------------- */

float spdf_win_md_code_pill_width(float title_chars, float scale) {
    /* An estimate, deliberately shared by the painter and the hit test rather
     * than measured at paint time: DirectWrite is not reachable from the
     * publish path, and a pill measured in one place and tested in another is
     * exactly the disagreement spdf_win_chrome.h forbids. 0.58 em is the
     * average advance of the 11px medium UI face over ASCII; the pill is a
     * couple of pixels wide of the glyphs at worst, which reads as padding. */
    float text = title_chars * 0.58f * SPDF_WIN_MD_CODE_TITLE_PX;
    float w = (text + SPDF_WIN_MD_CODE_PAD_X * 2.0f) * (scale > 0.0f ? scale : 1.0f);
    return (float)ceil((double)w);
}

int spdf_win_md_code_row(float column_x0, float column_x1, float top_y, float scale, float language_chars,
                         SpdfWinMdCodePill* language_out, SpdfWinMdCodePill* copy_out) {
    float s = scale > 0.0f ? scale : 1.0f;
    float h = SPDF_WIN_MD_CODE_HEIGHT * s;
    float inset = SPDF_WIN_MD_CODE_SIDE_INSET * s;
    float gap = SPDF_WIN_MD_CODE_MIN_GAP * s;
    /* The row RESTS ON the box's top edge: its bottom is a 2px lip inside the
     * box, so it reads as chrome fastened to the box and still cannot cover the
     * first line of code -- which a row centred on the edge did, because the
     * anchor MuPDF gives is the first line's baseline and the box's own padding
     * is only 12pt. */
    float y = (float)floor((double)(top_y + SPDF_WIN_MD_CODE_LIP * s - h) + 0.5);
    float lw = spdf_win_md_code_pill_width(language_chars, s);
    /* Always measured from the WIDER title, so the "Copied" state cannot move
     * or resize the button under the pointer (the mac's rule). */
    float cw = spdf_win_md_code_pill_width(6.0f, s); /* "Copied" */
    float room = column_x1 - column_x0 - inset * 2.0f;
    int drew_copy = 0;

    if (!(room > 0.0f)) return 0;
    if (lw > room) lw = room;
    if (language_out) {
        language_out->x = column_x1 - inset - lw;
        language_out->y = y;
        language_out->w = lw;
        language_out->h = h;
        language_out->title = NULL;
    }
    if (copy_out) {
        copy_out->x = column_x0 + inset;
        copy_out->y = y;
        copy_out->w = cw;
        copy_out->h = h;
        copy_out->title = NULL;
        /* The copy button stands down when the row cannot hold both with air;
         * the language pill always keeps the row. */
        if (copy_out->x + cw + gap <= column_x1 - inset - lw) drew_copy = 1;
        else memset(copy_out, 0, sizeof(*copy_out));
    }
    return drew_copy;
}

/* --- per paint ----------------------------------------------------------------- */

void spdf_win_md_code_publish_geometry(const spdf_win_scene* scene, float canvas_x, float canvas_y, float zoom) {
    float z = zoom > 0.0f ? zoom : 1.0f;
    float s;
    int i;

    g_mark_count = 0;
    g_pill_count = 0;
    if (!scene || g_fence_count <= 0) return;
    s = scene->dpi_scale > 0.0f ? scene->dpi_scale : 1.0f;
    if (!grow(&g_marks, &g_mark_cap, g_fence_count) || !grow(&g_pills, &g_pill_cap, g_fence_count * 2) ||
        !grow(&g_titles, &g_title_cap, g_fence_count * 48))
        return;

    for (i = 0; i < g_fence_count; ++i) {
        const Fence* f = &g_fences[i];
        const spdf_win_page_draw* frame = frame_for(scene, f->page_index);
        SpdfWinMdCodePill language, copy;
        SpdfWinMdCodeMark* m;
        wchar_t* title;
        float column_x0, column_x1, top_y, inset_px;
        int has_copy, chars;

        if (f->page_index < 0 || !frame) continue;
        inset_px = SPDF_WIN_MD_CODE_COLUMN_INSET_PT * z;
        column_x0 = frame->dest_x + inset_px;
        column_x1 = frame->dest_x + frame->dest_w - inset_px;
        /* The anchor is the box's first line of code; the box's own top edge is
         * one padding above it, and that is where the row belongs. */
        top_y = frame->dest_y + (f->top_y - SPDF_WIN_MD_CODE_BOX_PADDING_PT) * z;

        title = g_titles + (size_t)i * 48;
        chars = title_for(i, title, 48);
        if (chars <= 0) continue;
        has_copy = spdf_win_md_code_row(column_x0, column_x1, top_y, s, (float)chars, &language, &copy);
        if (language.w <= 0.0f) continue;

        language.title = title;
        g_pills[g_pill_count++] = language;
        if (has_copy) {
            copy.title = spdf_win_md_code_copied() == i ? L"Copied" : L"Copy";
            g_pills[g_pill_count++] = copy;
        }

        m = &g_marks[g_mark_count++];
        m->fence_index = i;
        m->page_index = f->page_index;
        /* Client px: the canvas origin, added once, here -- the router knows no
         * canvas. The slop is added in device px, since the pills are chrome. */
        m->lx0 = canvas_x + language.x - SPDF_WIN_MD_CODE_HIT_SLOP * s;
        m->lx1 = canvas_x + language.x + language.w + SPDF_WIN_MD_CODE_HIT_SLOP * s;
        m->ly0 = canvas_y + language.y - SPDF_WIN_MD_CODE_HIT_SLOP * s;
        m->ly1 = canvas_y + language.y + language.h + SPDF_WIN_MD_CODE_HIT_SLOP * s;
        if (has_copy) {
            m->cx0 = canvas_x + copy.x - SPDF_WIN_MD_CODE_HIT_SLOP * s;
            m->cx1 = canvas_x + copy.x + copy.w + SPDF_WIN_MD_CODE_HIT_SLOP * s;
            m->cy0 = canvas_y + copy.y - SPDF_WIN_MD_CODE_HIT_SLOP * s;
            m->cy1 = canvas_y + copy.y + copy.h + SPDF_WIN_MD_CODE_HIT_SLOP * s;
        } else {
            m->cx0 = m->cx1 = m->cy0 = m->cy1 = 0.0f;
        }
    }
}

void spdf_win_md_code_frame(spdf_document* doc, const char* path, const spdf_win_scene* scene, float canvas_x,
                            float canvas_y, float zoom) {
    static char synced_path[1024];
    static unsigned synced_generation;
    unsigned generation = spdf_win_md_options_generation();
    const char* want = path ? path : "";

    if (!doc || !path) {
        if (synced_path[0]) {
            spdf_win_md_code_sync(NULL, NULL);
            synced_path[0] = '\0';
        }
        spdf_win_md_code_publish_geometry(NULL, 0.0f, 0.0f, 1.0f);
        return;
    }
    if (strcmp(synced_path, want) != 0 || synced_generation != generation) {
        spdf_win_md_code_sync(doc, path);
        snprintf(synced_path, sizeof(synced_path), "%s", want);
        synced_generation = generation;
    }
    spdf_win_md_code_publish_geometry(scene, canvas_x, canvas_y, zoom);
}

const SpdfWinMdCodeMark* spdf_win_md_code_marks(int* out_count) {
    if (out_count) *out_count = g_mark_count;
    return g_mark_count > 0 ? g_marks : NULL;
}

int spdf_win_md_code_pills(SpdfWinMdCodePill* out, int cap) {
    int n = g_pill_count < cap ? g_pill_count : cap;
    if (out && n > 0) memcpy(out, g_pills, (size_t)n * sizeof(*out));
    return n;
}
