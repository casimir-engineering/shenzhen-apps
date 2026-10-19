/* The live text selection: the core call, the gesture's state, the overlay
 * rects and the clipboard. See spdf_win_selection.h for the layering and for
 * why sections 1 and 2 of that header are inline and this file is not.
 *
 * THE CORE DOES THE HARD PART. Everything about which glyphs a drag covers,
 * where a word starts, how a block is bounded, what an OCR gap means and how
 * CJK runs without spaces are segmented lives in portable/core/spdf_selection.c
 * and is pinned by SPDFCoreSelectionTests and SPDFCoreCJKSelectionTests. This
 * file does not re-derive one line of it: it turns mouse coordinates into a
 * page and two page points, calls spdf_select_text(), and owns the answer.
 * spdf_selection_adapter.c on the GTK side is the same file with the same job,
 * and the ownership rules below are transcribed from it.
 */
#include "spdf_win_selection.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#define SPDF_WIN_SELECTION_ERROR_CAPACITY 1024

struct spdf_win_selection {
    SpdfWinSelectionGesture gesture;
    spdf_selection_granularity granularity;
    int uses_range_path;

    int active;   /* a press is in flight */
    int page;     /* anchor page, or -1 */
    float ax, ay; /* anchor, page points */
    float bx, by; /* current end, page points */
    double start_dev_x;
    double start_dev_y;

    /* The result. Owns its text, rects and error message, exactly as
     * SpdfSelectionAdapterResult does. */
    char* text;
    spdf_rect* rects;
    int rect_count;
    unsigned flags;
    char* error;
    int result_page;

    /* Overlay scratch, grown and reused rather than reallocated per frame: a
     * malloc on every paint is a malloc on the scroll hot path, which is the
     * same reason spdf_win_canvas keeps `draws` around. */
    spdf_win_overlay* overlays;
    int overlay_capacity;
    int overlay_count;
};

/* --- ownership ------------------------------------------------------------ */

static char* dup_string(const char* text) {
    size_t size;
    char* copy;

    if (!text) return NULL;
    size = strlen(text) + 1;
    copy = (char*)malloc(size);
    if (copy) memcpy(copy, text, size);
    return copy;
}

/* Hand text and rects back to the core exactly as they came, which is what
 * spdf_free_text_selection expects -- they are one allocation pair from
 * spdf_select_text, not two mallocs of ours. */
static void free_result(spdf_win_selection* sel) {
    spdf_text_selection core;

    if (!sel) return;
    if (sel->text || sel->rects) {
        memset(&core, 0, sizeof(core));
        core.text = sel->text;
        core.rects = sel->rects;
        core.rect_count = sel->rect_count;
        core.flags = sel->flags;
        spdf_free_text_selection(&core);
    }
    free(sel->error);
    sel->text = NULL;
    sel->rects = NULL;
    sel->rect_count = 0;
    sel->flags = 0;
    sel->error = NULL;
    sel->result_page = -1;
}

spdf_win_selection* spdf_win_selection_new(void) {
    spdf_win_selection* sel = (spdf_win_selection*)calloc(1, sizeof(*sel));
    if (!sel) return NULL;
    sel->page = -1;
    sel->result_page = -1;
    return sel;
}

void spdf_win_selection_free(spdf_win_selection* sel) {
    if (!sel) return;
    free_result(sel);
    free(sel->overlays);
    free(sel);
}

void spdf_win_selection_clear(spdf_win_selection* sel) {
    if (!sel) return;
    free_result(sel);
    spdf_win_selection_gesture_reset(&sel->gesture);
    sel->active = 0;
    sel->page = -1;
    sel->overlay_count = 0;
}

/* --- the core call -------------------------------------------------------- */

/* Returns 1 when the visible selection changed. A NONE (a click on blank paper,
 * or in an OCR gap) clears whatever was selected, which is what every viewer
 * does and what the reader means by clicking there. */
static int run_selection(spdf_win_selection* sel, spdf_document* doc) {
    spdf_text_selection core;
    spdf_selection_status status;
    char err[SPDF_WIN_SELECTION_ERROR_CAPACITY];
    int had_text;

    if (!sel) return 0;
    had_text = sel->text != NULL;
    err[0] = '\0';
    memset(&core, 0, sizeof(core));
    if (!doc || sel->page < 0) {
        free_result(sel);
        return had_text;
    }
    status = spdf_select_text(doc, sel->page, sel->granularity, sel->ax, sel->ay, sel->bx, sel->by, &core, err,
                              sizeof(err));
    free_result(sel);
    sel->flags = core.flags;
    if (status == SPDF_SELECTION_OK) {
        /* The adapter's rule: OK with nothing in it is not a selection, it is a
         * defect, and it is reported rather than shown as an empty highlight. */
        if (!core.text || !core.text[0] || !core.rects || core.rect_count <= 0) {
            sel->error = dup_string("Text selection returned incomplete data.");
            spdf_free_text_selection(&core);
            return had_text;
        }
        sel->text = core.text;
        sel->rects = core.rects;
        sel->rect_count = core.rect_count;
        sel->result_page = sel->page;
        core.text = NULL;
        core.rects = NULL;
        core.rect_count = 0;
        spdf_free_text_selection(&core);
        return 1;
    }
    if (status == SPDF_SELECTION_ERROR) sel->error = dup_string(err[0] ? err : "Text selection failed.");
    spdf_free_text_selection(&core);
    return had_text;
}

/* --- the gesture ---------------------------------------------------------- */

int spdf_win_selection_press(spdf_win_selection* sel, spdf_document* doc, const spdf_win_page_draw* pages,
                             int page_count, const SpdfWinPageSizePt* sizes, int size_count, float x, float y,
                             unsigned press_count, int over_link) {
    SpdfWinSelectionClickPolicy policy;
    spdf_win_page_point hit;

    if (!sel) return 0;
    policy = spdf_win_selection_gesture_begin(&sel->gesture, press_count, over_link);
    sel->granularity = policy.granularity;
    sel->uses_range_path = policy.uses_range_path;
    sel->start_dev_x = (double)x;
    sel->start_dev_y = (double)y;
    sel->active = 1;

    if (!spdf_win_selection_point_on_page(pages, page_count, sizes, size_count, x, y, &hit)) {
        /* No page under or near the point: end the interaction without
         * selecting, as spdf_docview_selection_press does for a page below
         * zero. */
        sel->page = -1;
        return run_selection(sel, doc);
    }
    sel->page = hit.page_index;
    sel->ax = sel->bx = hit.x;
    sel->ay = sel->by = hit.y;

    /* A single press is a range CANDIDATE and selects nothing yet -- selecting
     * on press would flash a one-character highlight under every click,
     * including the click that follows a link. Word and block fire at once,
     * because their result does not depend on where the pointer goes next. */
    if (policy.uses_range_path) {
        int had_text = sel->text != NULL;
        free_result(sel);
        return had_text;
    }
    return run_selection(sel, doc);
}

int spdf_win_selection_drag(spdf_win_selection* sel, spdf_document* doc, const spdf_win_page_draw* pages,
                            int page_count, const SpdfWinPageSizePt* sizes, int size_count, float x, float y,
                            double threshold) {
    spdf_win_page_point hit;

    if (!sel || !sel->active) return 0;
    if (!spdf_win_selection_gesture_update_drag(&sel->gesture, sel->start_dev_x, sel->start_dev_y, (double)x, (double)y,
                                                threshold))
        return 0;
    /* A word or block selection stays exactly as the press made it while its
     * gesture finishes; only the range path tracks the pointer. */
    if (!sel->uses_range_path) return 0;
    if (sel->page < 0) return 0;
    if (!spdf_win_selection_point_on_page_index(pages, page_count, sizes, size_count, sel->page, x, y, &hit)) return 0;
    if (hit.x == sel->bx && hit.y == sel->by) return 0;
    sel->bx = hit.x;
    sel->by = hit.y;
    return run_selection(sel, doc);
}

int spdf_win_selection_release(spdf_win_selection* sel) {
    int activate;

    if (!sel) return 0;
    activate = spdf_win_selection_gesture_take_link(&sel->gesture);
    sel->active = 0;
    return activate;
}

void spdf_win_selection_cancel(spdf_win_selection* sel) {
    if (!sel) return;
    spdf_win_selection_gesture_cancel(&sel->gesture);
    sel->active = 0;
}

int spdf_win_selection_has_text(const spdf_win_selection* sel) {
    return sel && sel->text && sel->text[0] ? 1 : 0;
}

int spdf_win_selection_is_dragging(const spdf_win_selection* sel) {
    return sel && sel->gesture.dragging ? 1 : 0;
}

const char* spdf_win_selection_text(const spdf_win_selection* sel) {
    return sel ? sel->text : NULL;
}

int spdf_win_selection_page(const spdf_win_selection* sel) {
    return sel ? sel->result_page : -1;
}

const spdf_rect* spdf_win_selection_rects(const spdf_win_selection* sel, int* out_count) {
    if (out_count) *out_count = sel ? sel->rect_count : 0;
    return sel ? sel->rects : NULL;
}

const char* spdf_win_selection_error(const spdf_win_selection* sel) {
    return sel ? sel->error : NULL;
}

/* --- overlays ------------------------------------------------------------- */

void spdf_win_selection_compose_overlays(spdf_win_selection* sel, const spdf_win_page_draw* pages, int page_count,
                                         const SpdfWinPageSizePt* sizes, int size_count, struct spdf_win_scene* scene) {
    spdf_win_scene* sc = (spdf_win_scene*)scene;
    const spdf_win_overlay* base;
    int base_count, need, n, i;

    if (!sc) return;
    if (!sel || sel->rect_count <= 0 || !sel->rects || !pages || page_count <= 0) return;

    base = sc->overlays;
    base_count = sc->overlay_count;
    /* Our own array from a previous frame is not a base: composing over it
     * would duplicate the selection every frame, and the realloc below could
     * move the very memory being copied from. A caller that composes twice
     * without another producer in between gets the base it had. */
    if (base == sel->overlays) {
        base = NULL;
        base_count = 0;
    }
    if (base_count < 0 || !base) base_count = 0;

    need = base_count + sel->rect_count;
    if (need > sel->overlay_capacity) {
        spdf_win_overlay* grown = (spdf_win_overlay*)realloc(sel->overlays, sizeof(*grown) * (size_t)need);
        /* Leave the scene's base overlays alone: a selection that cannot be
         * drawn must not take the search highlights down with it. */
        if (!grown) return;
        sel->overlays = grown;
        sel->overlay_capacity = need;
    }
    n = 0;
    if (base_count > 0) {
        memcpy(sel->overlays, base, sizeof(*sel->overlays) * (size_t)base_count);
        n = base_count;
    }

    for (i = 0; i < page_count; ++i) {
        const spdf_win_page_draw* pd = &pages[i];
        int r;
        if (pd->page_index != sel->result_page) continue;
        for (r = 0; r < sel->rect_count && n < sel->overlay_capacity; ++r) {
            spdf_win_overlay o;
            if (!spdf_win_selection_rect_to_device(pd, sizes, size_count, sel->rects[r], &o)) break;
            if (!(o.w > 0.0f && o.h > 0.0f)) continue; /* a degenerate rect owns no pixels */
            sel->overlays[n++] = o;
        }
    }
    sel->overlay_count = n;
    /* Appended NOTHING -- the selection is on a page this scene does not show,
     * or every rect was degenerate. Leave the scene exactly as it was found,
     * pointer included, so "compose changed the scene" and "the selection is
     * visible" stay the same statement. */
    if (n <= base_count) return;
    sc->overlays = sel->overlays;
    sc->overlay_count = n;
}

/* --- the clipboard -------------------------------------------------------- */

int spdf_win_utf8_to_utf16(const char* utf8, wchar_t* out, int out_len) {
    int needed;

    if (!utf8) return 0;
    /* -1 makes MultiByteToWideChar count and copy the NUL, so the returned
     * length already includes it. MB_ERR_INVALID_CHARS rather than the silent
     * U+FFFD substitution: a selection that cannot be converted is a defect to
     * report, not a string of replacement characters to paste. */
    needed = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, NULL, 0);
    if (needed <= 0) return 0;
    if (!out) return needed;
    if (out_len < needed) return 0;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, out, out_len) != needed) return 0;
    return needed;
}

HGLOBAL spdf_win_clipboard_alloc_utf16(const char* utf8) {
    int chars;
    HGLOBAL handle;
    wchar_t* buffer;

    if (!utf8 || !utf8[0]) return NULL;
    chars = spdf_win_utf8_to_utf16(utf8, NULL, 0);
    if (chars <= 0) return NULL;

    /* GMEM_MOVEABLE is not optional: SetClipboardData takes ownership of the
     * handle and the clipboard requires a moveable one. */
    handle = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)chars * sizeof(wchar_t));
    if (!handle) return NULL;
    buffer = (wchar_t*)GlobalLock(handle);
    if (!buffer) {
        GlobalFree(handle);
        return NULL;
    }
    if (spdf_win_utf8_to_utf16(utf8, buffer, chars) != chars) {
        GlobalUnlock(handle);
        GlobalFree(handle);
        return NULL;
    }
    GlobalUnlock(handle);
    return handle;
}

int spdf_win_clipboard_put_utf8(const char* utf8) {
    HGLOBAL handle;
    int attempt;

    handle = spdf_win_clipboard_alloc_utf16(utf8);
    if (!handle) return 0;

    /* Another process can hold the clipboard for a few milliseconds after its
     * own copy; retrying briefly is the documented way to lose to a real owner
     * rather than to a race. */
    for (attempt = 0; attempt < 10; ++attempt) {
        if (OpenClipboard(NULL)) break;
        if (attempt == 9) {
            GlobalFree(handle);
            return 0;
        }
        Sleep(20);
    }
    if (!EmptyClipboard()) {
        CloseClipboard();
        GlobalFree(handle);
        return 0;
    }
    if (!SetClipboardData(CF_UNICODETEXT, handle)) {
        CloseClipboard();
        GlobalFree(handle);
        return 0;
    }
    /* The clipboard owns `handle` now -- freeing it here would be a
     * double free the next paste discovers. */
    CloseClipboard();
    return 1;
}

int spdf_win_clipboard_get_utf8(char* out, int out_len) {
    HANDLE handle;
    const wchar_t* text;
    int written = 0;
    int attempt;

    if (!out || out_len <= 0) return 0;
    out[0] = '\0';
    for (attempt = 0; attempt < 10; ++attempt) {
        if (OpenClipboard(NULL)) break;
        if (attempt == 9) return 0;
        Sleep(20);
    }
    handle = GetClipboardData(CF_UNICODETEXT);
    if (handle) {
        text = (const wchar_t*)GlobalLock(handle);
        if (text) {
            written = WideCharToMultiByte(CP_UTF8, 0, text, -1, out, out_len, NULL, NULL);
            GlobalUnlock(handle);
        }
    }
    CloseClipboard();
    return written;
}
