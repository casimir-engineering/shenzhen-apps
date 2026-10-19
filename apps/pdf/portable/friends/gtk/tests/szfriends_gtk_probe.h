/* Offscreen widget probes for friends-gtk-check: widgets laid out in a window that is realized but never mapped or
 * presented, snapshotted, and rendered by a GskRenderer realized for the display, never for a surface. Nothing
 * reaches the screen; every PNG lands in the renders directory for review. */

#ifndef SZFRIENDS_GTK_PROBE_H
#define SZFRIENDS_GTK_PROBE_H

#include "szfriends_gtk_support.h"
#include "gtk/szfriends_gtk_internal.h"

#include <adwaita.h>

extern const char *szfg_renders;  /* where PNGs go */
extern const char *szfg_manifest; /* the animal set's manifest.json */

/* A window to hold `child`, never shown. The probe owns it: destroy it with gtk_window_destroy. */
GtkWidget *szfg_probe_window(GtkWidget *child);
/* Lays `widget` (the window's child) out at `width` (and `height`, or its natural height for -1), renders it at
 * scale 2 over the theme's window background, writes `name`.png and returns the texture. */
GdkTexture *szfg_render(GtkWidget *window, int width, int height, const char *name);
/* The same at `scale` render pixels a point (1 for a 1x screen). */
GdkTexture *szfg_render_at(GtkWidget *window, int width, int height, int scale, const char *name);
/* Lays the window's child out without rendering, so allocations can be read. */
void szfg_layout(GtkWidget *window, int width, int height);
/* Pixel access on a downloaded texture: RGBA, 8 bits each, in render pixels (scale 2). */
typedef struct {
    int width, height;
    gsize stride;
    GBytes *bytes;
} SZFGPixels;
SZFGPixels szfg_pixels(GdkTexture *texture);
void szfg_pixels_free(SZFGPixels *pixels);
const guint8 *szfg_pixel(const SZFGPixels *pixels, int x, int y);
/* Pixels in the render rectangle (render coordinates) differing from `background` by more than `tolerance`. */
int szfg_count_differing(const SZFGPixels *pixels, int x, int y, int width, int height, const guint8 *background,
                         int tolerance);
void szfg_set_dark(gboolean dark);

/* A link with the fake helper behind it, for probes whose dropdown sends intents. */
SZFGHarness *szfg_probe_harness(const char *label);

void szfg_run_icon_probes(void);
void szfg_run_button_probes(void);
void szfg_run_dropdown_probes(void);
void szfg_run_avatar_probes(void);
void szfg_run_route_probes(void);

#endif /* SZFRIENDS_GTK_PROBE_H */
