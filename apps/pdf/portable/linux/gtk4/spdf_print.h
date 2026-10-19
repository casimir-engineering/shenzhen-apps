// spdf_print.c — printing for the GTK4 shell (Wave C): win.print →
// GtkPrintOperation with the full native dialog (page range, copies, paper
// size + orientation via embedded page setup) plus a "Scaling" custom tab
// carrying the Mac print panel accessory (SPDFMacPrintView.mm /
// ShenzhenPDFMac.mm printDocument: @15166): Fit to Printable Area /
// Actual Size (100%) / Custom Scale, persisted as settings.json
// "printScalingMode" / "printCustomScale" (same values the Mac app writes).
//
// Every page draws centered on the paper's imageable area; Fit shrinks or
// grows to fill it (aspect preserved), Actual maps 1 PDF point to 1/72 inch,
// Custom is a percentage of Actual. Rendering happens synchronously per page
// in draw-page through a private spdf_document (the core is not
// thread-ambivalent; the tab's doc and the render-service worker docs are
// never touched) — see the strategy note in spdf_print.c.
#pragma once

#ifndef SPDF_PRINT_TESTING
#include "spdf_window.h"

G_BEGIN_DECLS

// Registers win.print on the window action map (replaces the Wave A stub).
// Called from spdf_window_init.
void spdf_print_install(SpdfWindow* win);

G_END_DECLS
#else
#include <glib.h>
#endif

G_BEGIN_DECLS

// ---------------------------------------------------------------------------
// Pure scaling/placement math (double arithmetic only — no GTK, no core),
// exercised by tests/print_scaling_test.c. Ports of the Mac helpers named in
// each comment. All rects are in PDF points; the imageable area's origin is
// (0, 0) — exactly the coordinate space GtkPrintContext hands draw-page.

// Values persist as settings.json "printScalingMode"; must match the Mac
// SPDFPrintScalingMode enum (SPDFMacPrintView.h).
typedef enum {
    SPDF_PRINT_SCALING_FIT = 0,
    SPDF_PRINT_SCALING_ACTUAL = 1,
    SPDF_PRINT_SCALING_CUSTOM = 2,
} SpdfPrintScalingMode;

// Same limits as the Mac accessory and the settings.json clamp in
// spdf_state.c (SPDF_STATE_MIN/MAX_PRINT_SCALE).
#define SPDF_PRINT_MIN_CUSTOM_SCALE 0.10
#define SPDF_PRINT_MAX_CUSTOM_SCALE 8.0

// Render-resolution policy (spdf_print_render_zoom):
// never render below 72 dpi (Mac kSPDFMinimumPrintRenderZoom)…
#define SPDF_PRINT_MIN_RENDER_ZOOM 1.0
// …aim for at least 300 dpi even when the backend reports a nominal 72 dpi
// (print-to-file / preview), instead of the Mac's flat 1200 dpi target…
#define SPDF_PRINT_TARGET_DPI_FLOOR 300.0
// PDF permissions may allow printing while disallowing high-quality printing.
#define SPDF_PRINT_RESTRICTED_DPI 150.0
// …and never hold more than this many bytes of RGBA for one page render
// (the byte cap wins over the dpi target; the core's own hard cap is 512 MB).
#define SPDF_PRINT_RENDER_BYTE_CAP (128.0 * 1024.0 * 1024.0)
#define SPDF_PRINT_MAX_RENDER_DIMENSION 16384.0

typedef struct {
    double x;
    double y;
    double w;
    double h;
} SpdfPrintRect;

// SPDFClampPrintCustomScale: non-finite / non-positive → 1.0, else clamped
// into [0.10, 8.0].
double spdf_print_clamp_custom_scale(double scale);

// spdf_print_scale_for_mode (SPDFMacPrintView.mm): points-on-paper per
// PDF point. Fit = min(iw/pw, ih/ph) (may grow small pages), Actual = 1.0,
// Custom = clamped custom_scale. Degenerate inputs → 1.0.
double spdf_print_mode_scale(double page_w, double page_h, double imageable_w, double imageable_h,
                             SpdfPrintScalingMode mode, double custom_scale);

// spdf_print_destination_rect (SPDFMacPrintView.mm): the scaled page centered
// on the imageable area (origin (0,0)); at least 1×1 pt. Oversized results
// (Actual/Custom on big pages) deliberately overflow — the visible part is
// what spdf_print_visible_source extracts.
SpdfPrintRect spdf_print_dest_rect(double page_w, double page_h, double imageable_w, double imageable_h,
                                   SpdfPrintScalingMode mode, double custom_scale);

// Intersects dest with the imageable area and maps the overlap back onto the
// page: *src_pt is the page region (page-space points, origin top-left) that
// must be rendered, *dst_pt where it lands on the paper (imageable-space
// points). Keeps print memory proportional to PAPER area, not page area, for
// oversized Actual/Custom jobs. FALSE when nothing is visible.
gboolean spdf_print_visible_source(const SpdfPrintRect* dest, double page_w, double page_h, double imageable_w,
                                   double imageable_h, SpdfPrintRect* src_pt, SpdfPrintRect* dst_pt);

// Render zoom (device pixels per PDF point) for one page: mode_scale ×
// max(dpi_x, dpi_y)/72, raised to the 300 dpi floor and the 1.0 minimum,
// then shrunk continuously (not the Mac's halving) so the rendered region
// stays under byte_cap bytes of RGBA and under the dimension cap. byte_cap
// <= 0 disables the byte cap (tests).
double spdf_print_render_zoom(double mode_scale, double dpi_x, double dpi_y, double src_w_pt, double src_h_pt,
                              double byte_cap);

// Applies the PDF high-quality-print permission after the normal quality and
// memory policy. Restricted jobs never exceed 150 effective DPI.
double spdf_print_permission_render_zoom(double render_zoom, double mode_scale, gboolean high_quality_allowed);

G_END_DECLS
