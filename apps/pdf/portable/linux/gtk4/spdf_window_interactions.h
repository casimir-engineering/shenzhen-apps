// Pure interaction state shared by the GTK4 window shell and its GLib-only
// tests. Keeping this free of GTK types lets the removal-order cases emitted
// by AdwTabView be tested without a display server.
#pragma once

#include <glib.h>

G_BEGIN_DECLS

typedef gboolean (*SpdfWindowPagePresentFunc)(gpointer page, gpointer user_data);

typedef struct {
    GPtrArray* pages; // borrowed page identities, most recently active first
    gpointer selected;
} SpdfWindowTabHistory;

void spdf_window_tab_history_init(SpdfWindowTabHistory* history);
void spdf_window_tab_history_clear(SpdfWindowTabHistory* history);
void spdf_window_tab_history_activate(SpdfWindowTabHistory* history, gpointer page);

// Records a selected-page notification. If AdwTabView selected an adjacent
// page because the previously selected page was detached, returns the prior
// MRU page that should be restored; otherwise returns NULL.
gpointer spdf_window_tab_history_selection_changed(SpdfWindowTabHistory* history, gpointer page,
                                                   SpdfWindowPagePresentFunc is_present, gpointer user_data);

// Removes a page from the history. For a drag-detach, returns the prior MRU
// page when the detached page was active. Deliberate closes pass FALSE so the
// normal AdwTabView close selection remains unchanged.
gpointer spdf_window_tab_history_remove(SpdfWindowTabHistory* history, gpointer page, gboolean restore_previous,
                                        SpdfWindowPagePresentFunc is_present, gpointer user_data);

typedef enum {
    SPDF_HEADER_HIT_EMPTY,
    SPDF_HEADER_HIT_CONTROL,
} SpdfHeaderHitKind;

enum {
    SPDF_WINDOW_PRIMARY_BUTTON = 1
};

gboolean spdf_window_header_should_toggle_maximize(guint press_count, guint button, SpdfHeaderHitKind hit,
                                                   gboolean fullscreen_or_presentation);

G_END_DECLS
