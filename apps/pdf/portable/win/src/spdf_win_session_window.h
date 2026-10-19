/* spdf_win_session_window.h — the WINDOW object's own keys: "frame",
 * "display" and "focusedAt", read and written; and which of the file's windows
 * a plain launch takes.
 *
 * Module-internal, included by spdf_win_session.cpp alone after
 * spdf_win_session_json.h, whose reader and emitter it uses. Same arrangement
 * as that header, and split from spdf_win_session.cpp for the reason that file
 * keeps giving: the display identity and the focus stamp took it past the
 * 500-line cap, and tools/file-size-limits.md asks for an extracted file rather
 * than a raised one. Not part of the port's public surface, except for
 * spdf_win_session_window_ids(), declared in spdf_win_session.h and defined
 * here because it walks the same array these helpers do.
 *
 * The tab's keys stay next door: a tab is the same thing on every frontend,
 * while two of the three keys here are not (see spdf_win_session.h).
 */
#ifndef SPDF_WIN_SESSION_WINDOW_H
#define SPDF_WIN_SESSION_WINDOW_H

#include "spdf_win_session.h"
#include "spdf_win_session_json.h"
#include "spdf_win_state.h"

#include <time.h>

/* --- focusedAt ------------------------------------------------------------ */

/* NSDate's reference date, 2001-01-01 00:00:00 UTC, as a Unix time. The mac
 * stamps NSDate.timeIntervalSinceReferenceDate; a newest-wins comparison across
 * a file both apps write only holds if this port counts from the same instant. */
#define SPDF_WIN_SESSION_REFERENCE_DATE 978307200LL

static double session_focused_at_now(void) { return (double)(time(NULL) - SPDF_WIN_SESSION_REFERENCE_DATE); }

/* A window with no stamp reads as 0 -- older than any stamped one, and equal
 * to every other unstamped one, so a file written before the key existed still
 * resolves to its first window, exactly as before. */
static double session_window_focused_at(const char* window_obj) {
    return window_obj ? json_num(window_obj, "focusedAt", 0.0) : 0.0;
}

/* The stamp to write: now while this window is the foreground window, else
 * what the file already says for it. */
static void emit_focused_at(out_buf* out, const char* disk_window, int focused_now) {
    buf_puts(out, ",\"focusedAt\":");
    emit_fixed(out, focused_now ? session_focused_at_now() : session_window_focused_at(disk_window), 1);
}

/* --- the frame and its display ------------------------------------------ */

static void read_window_frame(const char* window, spdf_win_session_frame* out) {
    const char* frame = obj_value(window, "frame", NULL);
    const char* display;
    if (frame && *frame == '{') {
        out->x = json_int(frame, "x", 0);
        out->y = json_int(frame, "y", 0);
        out->w = json_int(frame, "width", 0);
        out->h = json_int(frame, "height", 0);
        if (out->w <= 0 || out->h <= 0) out->w = out->h = 0;
    }
    display = obj_value(window, "display", NULL);
    if (display && *display == '{') {
        char* name = json_str(display, "name");
        if (name) snprintf(out->display, sizeof(out->display), "%s", name);
        free(name);
        out->display_x = json_int(display, "x", 0);
        out->display_y = json_int(display, "y", 0);
        out->display_w = json_int(display, "width", 0);
        out->display_h = json_int(display, "height", 0);
    }
}

static void emit_rect(out_buf* out, int x, int y, int w, int h) {
    buf_puts(out, "\"height\":");
    emit_int(out, h);
    buf_puts(out, ",\"width\":");
    emit_int(out, w);
    buf_puts(out, ",\"x\":");
    emit_int(out, x);
    buf_puts(out, ",\"y\":");
    emit_int(out, y);
}

/* Our frame when the caller has one; else the frame -- and display -- already
 * on disk, so a save that knows no geometry never moves a mac user's window. */
static void emit_window_frame(out_buf* out, const spdf_win_session_frame* frame, const char* disk_window) {
    const char* disk_end = NULL;
    const char* disk;
    if (frame && frame->w > 0 && frame->h > 0) {
        buf_puts(out, ",\"frame\":{");
        emit_rect(out, frame->x, frame->y, frame->w, frame->h);
        buf_puts(out, "}");
        if (frame->display[0]) {
            buf_puts(out, ",\"display\":{\"name\":");
            emit_string(out, frame->display);
            buf_puts(out, ",");
            emit_rect(out, frame->display_x, frame->display_y, frame->display_w, frame->display_h);
            buf_puts(out, "}");
        }
        return;
    }
    disk = disk_window ? obj_value(disk_window, "frame", &disk_end) : NULL;
    if (disk && disk_end) {
        buf_puts(out, ",\"frame\":");
        buf_put(out, disk, (size_t)(disk_end - disk));
    }
    disk = disk_window ? obj_value(disk_window, "display", &disk_end) : NULL;
    if (disk && disk_end) {
        buf_puts(out, ",\"display\":");
        buf_put(out, disk, (size_t)(disk_end - disk));
    }
}

/* --- which window --------------------------------------------------------- */

static int window_is_parked(const char* element) {
    char* id = json_str(element, "id");
    int parked = id && strcmp(id, SPDF_WIN_SESSION_HANDOFF_ID) == 0;
    free(id);
    return parked;
}

/* The window a plain launch restores: the newest "focusedAt"; the first on a
 * tie, which is every window of a file written before the key existed. THE
 * HAND-OFF PARKING SPOT IS NOT A WINDOW (spdf_win_session.h): a launch never
 * restores a tab that was in flight when something crashed. */
static const char* focused_window(const char* windows) {
    const char* end = NULL;
    const char* element;
    const char* best = NULL;
    double best_at = 0.0;
    for (element = array_first(windows, &end); element; element = array_next(end, &end)) {
        double at;
        if (*element != '{' || window_is_parked(element)) continue;
        at = session_window_focused_at(element);
        if (!best || at > best_at) {
            best = element;
            best_at = at;
        }
    }
    return best;
}

int spdf_win_session_window_ids(char ids[][SPDF_WIN_SESSION_ID_MAX], int max) {
    char* json = spdf_win_state_read_json(SPDF_WIN_STATE_SESSION);
    const char* windows;
    const char* end = NULL;
    const char* element;
    int count = 0;
    if (!json || !ids) {
        free(json);
        return 0;
    }
    windows = obj_value(skip_ws(json), "windows", NULL);
    for (element = array_first(windows, &end); element && count < max; element = array_next(end, &end)) {
        char* id;
        if (*element != '{' || window_is_parked(element)) continue;
        id = json_str(element, "id");
        if (id && *id) snprintf(ids[count++], SPDF_WIN_SESSION_ID_MAX, "%s", id);
        free(id);
    }
    free(json);
    return count;
}

#endif /* SPDF_WIN_SESSION_WINDOW_H */
