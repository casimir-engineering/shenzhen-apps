// spdf_resident_warmup.c -- the resident start's first-frame warmup, moved verbatim out of spdf_app.c (whose line
// cap is frozen); declared in spdf_resident_warmup.h.

#include "spdf_app.h"
#include "spdf_resident_warmup.h"
#include "spdf_window.h"

// Resident warmup (see the resident-start branch below): realize a throwaway
// shell window (never mapped) and push one text render node through its GSK
// renderer, forcing the process-global first-frame work — font map, glyph
// rasterization + atlas upload, CSS, icon theme, shader compilation — to
// happen at login instead of on the user's first open.
static gboolean resident_warmup_teardown(gpointer win) {
    gtk_window_destroy(GTK_WINDOW(win));
    spdf_launch_mark("resident-warmup-done");
    return G_SOURCE_REMOVE;
}

static void resident_warmup_mapped(GtkWidget* warm, gpointer user_data) {
    (void)user_data;
    // Destroy from an idle, after the frame that mapping produced — that
    // frame is exactly the warmup payload.
    g_idle_add_full(G_PRIORITY_LOW, resident_warmup_teardown, warm, NULL);
}

gboolean spdf_resident_warmup_idle(gpointer user_data) {
    SpdfApp* self = SPDF_APP(user_data);
    GtkWidget* warm;
    GskRenderer* renderer;

    // A real open raced us and already paid the bill.
    if (gtk_application_get_windows(GTK_APPLICATION(self))) return G_SOURCE_REMOVE;

    warm = GTK_WIDGET(spdf_window_new(ADW_APPLICATION(self)));
    g_object_set_data(G_OBJECT(warm), "spdf-warmup", GINT_TO_POINTER(1));
    (void)renderer;
    // Realize alone rasterizes nothing (measured: the first real present
    // still blocked ~220 ms). The full bill is only paid by an actual first
    // frame of a real widget tree, so present the throwaway window fully
    // transparent and tear it down right after it maps. This happens only on
    // the --resident login start, before any user-visible window exists.
    gtk_widget_set_opacity(warm, 0.0);
    g_signal_connect(warm, "map", G_CALLBACK(resident_warmup_mapped), self);
    gtk_window_present(GTK_WINDOW(warm));
    return G_SOURCE_REMOVE;
}
