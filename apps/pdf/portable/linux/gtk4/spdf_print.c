// spdf_print.c — printing for the GTK4 shell (Wave C). See spdf_print.h for
// the module contract; Mac reference: ShenzhenPDFMac.mm printDocument: @15166
// + SPDFMacPrintView.mm (NSPrintOperation + scaling accessory).
//
// Structure:
//   1. Pure scaling/placement math (double arithmetic only) — also compiled
//      alone by tests/print_scaling_test.c via SPDF_PRINT_TESTING.
//   2. GTK module: the win.print action, GtkPrintOperation lifecycle, the
//      "Scaling" custom dialog tab, per-page rendering.
//
// Rendering strategy — synchronous per page, in draw-page, from a PRIVATE
// spdf_document owned by the print job:
//   - The core is not thread-ambivalent: the tab's main-thread doc and the
//     render service's worker docs must not be shared, so printing opens its
//     own document (same rule as spdf_search.c / spdf_palette.c workers).
//     draw-page runs on the main thread, so that private doc is only ever
//     touched from one thread.
//   - Synchronous-per-page is the Mac behavior (SPDFPrintView drawRect:
//     renders on demand) and keeps memory bounded to ONE page region bitmap
//     (≤ SPDF_PRINT_RENDER_BYTE_CAP RGBA bytes) plus its cairo copy,
//     regardless of document length or the selected page range. Pre-rendering
//     on a worker between begin-print and draw-page would either hold the
//     whole range at printer resolution in RAM or add a disk spool — real
//     complexity for a stall GtkPrintOperation already mitigates by running
//     its own main-loop iterations (progress dialog stays live) between
//     pages. If per-page latency ever becomes a problem, a one-page-ahead
//     worker prefetch can slot in behind spdf_print_visible_source without
//     changing any of the math below.

#include <math.h>

#include "spdf_print.h"

/* ---------------------------------------------------------------------------
 * 1. Pure scaling/placement math. Ports of the Mac helpers:
 *    SPDFClampPrintCustomScale, spdf_print_scale_for_mode and
 *    spdf_print_destination_rect (SPDFMacPrintView.mm); the visible-source
 *    split and the render-zoom policy are Linux additions (the Mac renders
 *    full pages at a flat 1200 dpi target and halves on failure). */

double spdf_print_clamp_custom_scale(double scale) {
    if (!isfinite(scale) || scale <= 0.0) return 1.0;
    return CLAMP(scale, SPDF_PRINT_MIN_CUSTOM_SCALE, SPDF_PRINT_MAX_CUSTOM_SCALE);
}

double spdf_print_mode_scale(double page_w, double page_h, double imageable_w, double imageable_h,
                             SpdfPrintScalingMode mode, double custom_scale) {
    if (page_w <= 0.0 || page_h <= 0.0 || imageable_w <= 0.0 || imageable_h <= 0.0) return 1.0;
    if (mode == SPDF_PRINT_SCALING_ACTUAL) return 1.0;
    if (mode == SPDF_PRINT_SCALING_CUSTOM) return spdf_print_clamp_custom_scale(custom_scale);
    return MIN(imageable_w / page_w, imageable_h / page_h);
}

SpdfPrintRect spdf_print_dest_rect(double page_w, double page_h, double imageable_w, double imageable_h,
                                   SpdfPrintScalingMode mode, double custom_scale) {
    double scale = spdf_print_mode_scale(page_w, page_h, imageable_w, imageable_h, mode, custom_scale);
    SpdfPrintRect rect;

    rect.w = MAX(1.0, page_w * scale);
    rect.h = MAX(1.0, page_h * scale);
    rect.x = (imageable_w - rect.w) / 2.0;
    rect.y = (imageable_h - rect.h) / 2.0;
    return rect;
}

gboolean spdf_print_visible_source(const SpdfPrintRect* dest, double page_w, double page_h, double imageable_w,
                                   double imageable_h, SpdfPrintRect* src_pt, SpdfPrintRect* dst_pt) {
    double scale;
    double x0;
    double y0;
    double x1;
    double y1;

    if (!dest || !src_pt || !dst_pt) return FALSE;
    if (dest->w <= 0.0 || dest->h <= 0.0 || page_w <= 0.0 || page_h <= 0.0) return FALSE;
    if (imageable_w <= 0.0 || imageable_h <= 0.0) return FALSE;

    scale = dest->w / page_w; /* uniform by construction of the dest rect */
    x0 = MAX(dest->x, 0.0);
    y0 = MAX(dest->y, 0.0);
    x1 = MIN(dest->x + dest->w, imageable_w);
    y1 = MIN(dest->y + dest->h, imageable_h);
    if (x1 <= x0 || y1 <= y0) return FALSE;

    dst_pt->x = x0;
    dst_pt->y = y0;
    dst_pt->w = x1 - x0;
    dst_pt->h = y1 - y0;
    src_pt->x = (x0 - dest->x) / scale;
    src_pt->y = (y0 - dest->y) / scale;
    src_pt->w = dst_pt->w / scale;
    src_pt->h = dst_pt->h / scale;
    return TRUE;
}

double spdf_print_render_zoom(double mode_scale, double dpi_x, double dpi_y, double src_w_pt, double src_h_pt,
                              double byte_cap) {
    double dpi = MAX(dpi_x, dpi_y);
    double zoom;
    double bytes;
    double max_dim;

    if (!isfinite(dpi) || dpi < SPDF_PRINT_TARGET_DPI_FLOOR) dpi = SPDF_PRINT_TARGET_DPI_FLOOR;
    if (!isfinite(mode_scale) || mode_scale <= 0.0) mode_scale = 1.0;
    zoom = mode_scale * dpi / 72.0;
    if (zoom < SPDF_PRINT_MIN_RENDER_ZOOM) zoom = SPDF_PRINT_MIN_RENDER_ZOOM;
    if (src_w_pt <= 0.0 || src_h_pt <= 0.0) return zoom;

    /* Memory correctness beats the dpi target: shrink continuously (keeps the
     * best resolution the cap allows, unlike the Mac's halving loop). */
    if (byte_cap > 0.0) {
        bytes = src_w_pt * zoom * src_h_pt * zoom * 4.0;
        if (bytes > byte_cap) zoom *= sqrt(byte_cap / bytes);
    }
    max_dim = MAX(src_w_pt, src_h_pt) * zoom;
    if (max_dim > SPDF_PRINT_MAX_RENDER_DIMENSION) zoom *= SPDF_PRINT_MAX_RENDER_DIMENSION / max_dim;
    return MAX(zoom, 0.05);
}

double spdf_print_permission_render_zoom(double render_zoom, double mode_scale, gboolean high_quality_allowed) {
    double restricted_zoom;

    if (!isfinite(render_zoom) || render_zoom <= 0.0) return 0.05;
    if (high_quality_allowed) return render_zoom;
    if (!isfinite(mode_scale) || mode_scale <= 0.0) mode_scale = 1.0;
    restricted_zoom = MAX(0.05, mode_scale * SPDF_PRINT_RESTRICTED_DPI / 72.0);
    return MIN(render_zoom, restricted_zoom);
}

#ifndef SPDF_PRINT_TESTING

#include <string.h>

#include "spdf_app.h"
#include "spdf_password_prompt.h"

// ---------------------------------------------------------------------------
// 2. GTK module.

// One print job = one GtkPrintOperation. Owned by the operation
// (g_object_set_data_full), so it outlives the async dialog + spool and dies
// exactly when GTK drops its last ref on the operation.
typedef struct {
    SpdfWindow* win; // ref'd: error reporting after async completion
    char* path;
    spdf_document* doc; // private print doc (see strategy note above)
    int page_count;
    int scaling_mode; // live copy driving draw-page
    double custom_scale;
    gboolean high_quality_allowed;
    // Custom-tab controls; borrowed while the dialog is alive, cleared in
    // custom-widget-apply (the widgets die with the dialog).
    GtkCheckButton* mode_checks[3];
    GtkSpinButton* scale_spin;
} SpdfPrintJob;

// Last accepted dialog settings (printer, copies, paper…), remembered for
// the process lifetime like every GTK app does; scaling mode + custom scale
// persist across launches via settings.json instead.
static GtkPrintSettings* s_print_settings;

static void print_job_free(gpointer data) {
    SpdfPrintJob* job = data;

    if (job->doc) spdf_close(job->doc);
    g_clear_object(&job->win);
    g_free(job->path);
    g_free(job);
}

static void print_show_error(SpdfWindow* win, const char* heading, const char* detail) {
    GtkAlertDialog* alert = gtk_alert_dialog_new("%s", heading);
    gtk_alert_dialog_set_detail(alert, detail && *detail ? detail : "Unknown error.");
    gtk_alert_dialog_show(alert, win && gtk_widget_get_mapped(GTK_WIDGET(win)) ? GTK_WINDOW(win) : NULL);
    g_object_unref(alert);
}

static SpdfState* print_window_state(SpdfWindow* win) {
    GtkApplication* app = win ? gtk_window_get_application(GTK_WINDOW(win)) : NULL;
    return app && SPDF_IS_APP(app) ? spdf_app_get_state(SPDF_APP(app)) : NULL;
}

// ---------------------------------------------------------------------------
// Rendering (draw-page, main thread)

// The core clears its pixmap to white and renders with no alpha, so the RGBA
// bytes are always opaque — RGB24 (xRGB native-endian) is lossless here and
// skips premultiplication.
static cairo_surface_t* print_surface_from_bitmap(const spdf_bitmap* bitmap) {
    cairo_surface_t* surface;
    unsigned char* dst;
    int dst_stride;

    if (!bitmap || !bitmap->rgba || bitmap->width <= 0 || bitmap->height <= 0 || bitmap->stride <= 0) return NULL;
    surface = cairo_image_surface_create(CAIRO_FORMAT_RGB24, bitmap->width, bitmap->height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    cairo_surface_flush(surface);
    dst = cairo_image_surface_get_data(surface);
    dst_stride = cairo_image_surface_get_stride(surface);
    for (int y = 0; y < bitmap->height; ++y) {
        const unsigned char* s = bitmap->rgba + (gsize)y * (gsize)bitmap->stride;
        guint32* d = (guint32*)(dst + (gsize)y * (gsize)dst_stride);
        for (int x = 0; x < bitmap->width; ++x, s += 4)
            d[x] = ((guint32)s[0] << 16) | ((guint32)s[1] << 8) | (guint32)s[2];
    }
    cairo_surface_mark_dirty(surface);
    return surface;
}

static void print_draw_page(GtkPrintOperation* op, GtkPrintContext* context, int page_nr, gpointer user_data) {
    SpdfPrintJob* job = user_data;
    cairo_t* cr = gtk_print_context_get_cairo_context(context);
    GtkPageSetup* setup = gtk_print_context_get_page_setup(context);
    double imageable_w = gtk_page_setup_get_page_width(setup, GTK_UNIT_POINTS);
    double imageable_h = gtk_page_setup_get_page_height(setup, GTK_UNIT_POINTS);
    double context_w = gtk_print_context_get_width(context);
    double context_h = gtk_print_context_get_height(context);
    float page_w = 0.0f;
    float page_h = 0.0f;
    double mode_scale;
    double zoom;
    SpdfPrintRect dest;
    SpdfPrintRect src;
    SpdfPrintRect dst;
    spdf_bitmap bitmap = {0, 0, 0, NULL};
    spdf_rect region;
    cairo_surface_t* surface;
    gboolean rendered = FALSE;
    char err[1024] = "";

    (void)op;
    if (!cr || !job->doc || imageable_w <= 0.0 || imageable_h <= 0.0) return;
    if (!spdf_page_size(job->doc, page_nr, &page_w, &page_h, err, sizeof(err)) || page_w <= 0.0f || page_h <= 0.0f) {
        g_warning("shenzhenpdf: print: page %d size unavailable: %s", page_nr + 1, err);
        return;
    }

    cairo_save(cr);
    // Normalize the context to PDF points. The CUPS/PDF backends already hand
    // one point per unit (context_w == imageable_w); image-based backends hand
    // device pixels — context_w / imageable_w is exactly that per-axis factor.
    if (context_w > 0.0 && context_h > 0.0) cairo_scale(cr, context_w / imageable_w, context_h / imageable_h);

    dest = spdf_print_dest_rect(page_w, page_h, imageable_w, imageable_h, (SpdfPrintScalingMode)job->scaling_mode,
                                job->custom_scale);
    if (!spdf_print_visible_source(&dest, page_w, page_h, imageable_w, imageable_h, &src, &dst)) {
        cairo_restore(cr);
        return; // nothing of this page lands on the paper
    }
    mode_scale = spdf_print_mode_scale(page_w, page_h, imageable_w, imageable_h,
                                       (SpdfPrintScalingMode)job->scaling_mode, job->custom_scale);
    {
        double dpi_x = gtk_print_context_get_dpi_x(context);
        double dpi_y = gtk_print_context_get_dpi_y(context);
        zoom = spdf_print_render_zoom(mode_scale, dpi_x, dpi_y, src.w, src.h, SPDF_PRINT_RENDER_BYTE_CAP);
        zoom = spdf_print_permission_render_zoom(zoom, mode_scale, job->high_quality_allowed);
    }

    // Halve on mupdf failure like the Mac print view — the zoom above already
    // respects the byte cap, so this only catches renderer errors.
    region.x0 = (float)src.x;
    region.y0 = (float)src.y;
    region.x1 = (float)(src.x + src.w);
    region.y1 = (float)(src.y + src.h);
    for (; zoom >= 0.05; zoom *= 0.5) {
        if (spdf_render_page_region_rgba(job->doc, page_nr, (float)zoom, region, &bitmap, err, sizeof(err))) {
            rendered = TRUE;
            break;
        }
    }
    if (!rendered) {
        g_warning("shenzhenpdf: print: could not render page %d: %s", page_nr + 1, err);
        cairo_restore(cr);
        return;
    }

    surface = print_surface_from_bitmap(&bitmap);
    spdf_free_bitmap(&bitmap);
    if (!surface) {
        g_warning("shenzhenpdf: print: could not allocate print surface for page %d", page_nr + 1);
        cairo_restore(cr);
        return;
    }

    // Clip to the imageable area (Actual/Custom may still poke out by the
    // sub-point rounding of the region render), place, scale bitmap px → pt.
    cairo_rectangle(cr, 0.0, 0.0, imageable_w, imageable_h);
    cairo_clip(cr);
    cairo_translate(cr, dst.x, dst.y);
    cairo_scale(cr, dst.w / cairo_image_surface_get_width(surface), dst.h / cairo_image_surface_get_height(surface));
    cairo_set_source_surface(cr, surface, 0.0, 0.0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    cairo_paint(cr);
    cairo_surface_destroy(surface);
    cairo_restore(cr);
}

static void print_begin_print(GtkPrintOperation* op, GtkPrintContext* context, gpointer user_data) {
    SpdfPrintJob* job = user_data;

    (void)context;
    gtk_print_operation_set_n_pages(op, MAX(1, job->page_count));
}

// ---------------------------------------------------------------------------
// "Scaling" custom dialog tab (Mac SPDFPrintScalingAccessoryController)

static void print_mode_check_toggled(GtkCheckButton* check, gpointer user_data) {
    SpdfPrintJob* job = user_data;

    (void)check;
    if (job->scale_spin && job->mode_checks[SPDF_PRINT_SCALING_CUSTOM])
        gtk_widget_set_sensitive(GTK_WIDGET(job->scale_spin),
                                 gtk_check_button_get_active(job->mode_checks[SPDF_PRINT_SCALING_CUSTOM]));
}

static GObject* print_create_custom_widget(GtkPrintOperation* op, gpointer user_data) {
    static const char* k_mode_labels[3] = {"Fit to printable area", "Actual size (100%)", "Custom scale"};
    SpdfPrintJob* job = user_data;
    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    GtkWidget* custom_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget* spin;
    GtkWidget* percent;
    int active = CLAMP(job->scaling_mode, SPDF_PRINT_SCALING_FIT, SPDF_PRINT_SCALING_CUSTOM);

    (void)op;
    gtk_widget_set_margin_top(box, 12);
    gtk_widget_set_margin_bottom(box, 12);
    gtk_widget_set_margin_start(box, 12);
    gtk_widget_set_margin_end(box, 12);

    for (int mode = 0; mode < 3; ++mode) {
        GtkWidget* check = gtk_check_button_new_with_label(k_mode_labels[mode]);
        if (mode > 0) gtk_check_button_set_group(GTK_CHECK_BUTTON(check), job->mode_checks[0]);
        gtk_check_button_set_active(GTK_CHECK_BUTTON(check), mode == active);
        g_signal_connect(check, "toggled", G_CALLBACK(print_mode_check_toggled), job);
        job->mode_checks[mode] = GTK_CHECK_BUTTON(check);
        gtk_box_append(GTK_BOX(box), check);
    }

    spin =
        gtk_spin_button_new_with_range(SPDF_PRINT_MIN_CUSTOM_SCALE * 100.0, SPDF_PRINT_MAX_CUSTOM_SCALE * 100.0, 1.0);
    gtk_spin_button_set_digits(GTK_SPIN_BUTTON(spin), 0);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(spin), round(spdf_print_clamp_custom_scale(job->custom_scale) * 100.0));
    gtk_widget_set_sensitive(spin, active == SPDF_PRINT_SCALING_CUSTOM);
    job->scale_spin = GTK_SPIN_BUTTON(spin);
    percent = gtk_label_new("% of actual size");
    gtk_widget_set_margin_start(custom_row, 26); // align under the radio labels
    gtk_box_append(GTK_BOX(custom_row), spin);
    gtk_box_append(GTK_BOX(custom_row), percent);
    gtk_box_append(GTK_BOX(box), custom_row);

    return G_OBJECT(box);
}

// Emitted when the dialog is accepted (Print or Preview) — read the controls
// into the job and persist them, like the Mac accessory's changeHandler →
// savePersistentState. (A canceled dialog persists nothing.)
static void print_custom_widget_apply(GtkPrintOperation* op, GtkWidget* widget, gpointer user_data) {
    SpdfPrintJob* job = user_data;
    SpdfState* state = print_window_state(job->win);

    (void)op;
    (void)widget;
    if (job->mode_checks[SPDF_PRINT_SCALING_ACTUAL] &&
        gtk_check_button_get_active(job->mode_checks[SPDF_PRINT_SCALING_ACTUAL]))
        job->scaling_mode = SPDF_PRINT_SCALING_ACTUAL;
    else if (job->mode_checks[SPDF_PRINT_SCALING_CUSTOM] &&
             gtk_check_button_get_active(job->mode_checks[SPDF_PRINT_SCALING_CUSTOM]))
        job->scaling_mode = SPDF_PRINT_SCALING_CUSTOM;
    else
        job->scaling_mode = SPDF_PRINT_SCALING_FIT;
    if (job->scale_spin)
        job->custom_scale = spdf_print_clamp_custom_scale(gtk_spin_button_get_value(job->scale_spin) / 100.0);

    if (state) {
        SpdfSettings* settings = spdf_state_settings(state);
        settings->print_scaling_mode = job->scaling_mode;
        settings->print_custom_scale = job->custom_scale;
        spdf_state_save_settings(state);
    }

    // The dialog (and these widgets) are about to die; drop the borrows.
    memset(job->mode_checks, 0, sizeof(job->mode_checks));
    job->scale_spin = NULL;
}

// ---------------------------------------------------------------------------
// Operation lifecycle

static void print_done(GtkPrintOperation* op, GtkPrintOperationResult result, gpointer user_data) {
    SpdfPrintJob* job = user_data;

    if (result == GTK_PRINT_OPERATION_RESULT_ERROR) {
        GError* error = NULL;
        gtk_print_operation_get_error(op, &error);
        print_show_error(job->win, "Could not print document", error ? error->message : NULL);
        g_clear_error(&error);
    } else if (result == GTK_PRINT_OPERATION_RESULT_APPLY) {
        GtkPrintSettings* accepted = gtk_print_operation_get_print_settings(op);
        if (accepted) g_set_object(&s_print_settings, accepted);
    }
    // The job itself is freed with the operation (set_data_full).
}

static void print_action(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    SpdfState* state = print_window_state(win);
    SpdfSettings* settings = state ? spdf_state_settings(state) : NULL;
    GtkPrintOperation* op;
    SpdfPrintJob* job;
    spdf_document* doc;
    SpdfPasswordSource source = {0};
    GError* error = NULL;
    char* job_name;
    char err[1024] = "";

    (void)action;
    (void)parameter;
    if (!tab || !tab->path) return;

    // Permission gate, like the Mac allowsPrinting check.
    if (!spdf_password_require_permission(GTK_WINDOW(win), tab->doc, 'p', "Printing is not allowed")) return;

    spdf_password_source_init(&source, tab->working_path ? tab->working_path : tab->path, tab->credential);
    doc = spdf_password_source_open(&source, err, sizeof(err));
    spdf_password_source_clear(&source);
    if (!doc) {
        print_show_error(win, "Could not print document", err);
        return;
    }
    if (spdf_page_count(doc) <= 0) {
        spdf_close(doc);
        print_show_error(win, "Could not print document", "The document has no pages.");
        return;
    }

    job = g_new0(SpdfPrintJob, 1);
    job->win = g_object_ref(win);
    job->path = g_strdup(tab->path);
    job->doc = doc;
    job->page_count = spdf_page_count(doc);
    job->scaling_mode = settings ? CLAMP(settings->print_scaling_mode, 0, 2) : SPDF_PRINT_SCALING_FIT;
    job->custom_scale = spdf_print_clamp_custom_scale(settings ? settings->print_custom_scale : 1.0);
    job->high_quality_allowed = spdf_has_permission(doc, 'h');

    op = gtk_print_operation_new();
    g_object_set_data_full(G_OBJECT(op), "spdf-print-job", job, print_job_free);
    job_name = g_path_get_basename(job->path);
    gtk_print_operation_set_job_name(op, job_name);
    g_free(job_name);
    gtk_print_operation_set_n_pages(op, job->page_count); // dialog range widget; re-set in begin-print
    gtk_print_operation_set_embed_page_setup(op, TRUE);   // paper size + orientation in the dialog
    gtk_print_operation_set_show_progress(op, TRUE);
    gtk_print_operation_set_allow_async(op, TRUE);
    gtk_print_operation_set_custom_tab_label(op, "Scaling");
    if (s_print_settings) gtk_print_operation_set_print_settings(op, s_print_settings);

    g_signal_connect(op, "begin-print", G_CALLBACK(print_begin_print), job);
    g_signal_connect(op, "draw-page", G_CALLBACK(print_draw_page), job);
    g_signal_connect(op, "create-custom-widget", G_CALLBACK(print_create_custom_widget), job);
    g_signal_connect(op, "custom-widget-apply", G_CALLBACK(print_custom_widget_apply), job);
    g_signal_connect(op, "done", G_CALLBACK(print_done), job);

    // Async: run returns immediately with IN_PROGRESS; ::done reports the
    // outcome. GTK holds its own ref on the operation until then, and the
    // default preview handler (external previewer, usually Evince) is left
    // untouched. Synchronous errors (no print backends…) surface here.
    gtk_print_operation_run(op, GTK_PRINT_OPERATION_ACTION_PRINT_DIALOG, GTK_WINDOW(win), &error);
    if (error) {
        print_show_error(win, "Could not print document", error->message);
        g_clear_error(&error);
    }
    g_object_unref(op);
}

static const GActionEntry k_print_actions[] = {
    {"print", print_action, NULL, NULL, NULL, {0}},
};

void spdf_print_install(SpdfWindow* win) {
    g_return_if_fail(SPDF_IS_WINDOW(win));
    g_action_map_add_action_entries(G_ACTION_MAP(win), k_print_actions, G_N_ELEMENTS(k_print_actions), win);
}

#endif /* SPDF_PRINT_TESTING */
