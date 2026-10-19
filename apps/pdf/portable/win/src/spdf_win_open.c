/* spdf_win_open.c — see spdf_win_open.h. */
#include "spdf_win_open.h"

static spdf_win_open_fn g_hook;

spdf_document* spdf_win_open_document(const char* utf8_path, char* err, size_t err_len) {
    spdf_win_open_fn fn = g_hook;
    return fn ? fn(utf8_path, err, err_len) : spdf_open(utf8_path, err, err_len);
}

void spdf_win_open_set_hook(spdf_win_open_fn fn) { g_hook = fn; }

spdf_win_open_fn spdf_win_open_hook(void) { return g_hook; }
