/* Drags and drops over a row, and whose row a press belongs to (szfriends_gtk_row.h, szfriends_gtk_row_private.h).
 *
 * Rows are reused by position, and a snapshot can move someone else into a row while the pointer rests on it: up to
 * ten a second arrive while files are dragged or a mouse button is held. A press and a drag therefore remember the
 * row's tenure when they begin, and a release or a drop completes only for that same person; otherwise the click is
 * cancelled and the drop refused, so nothing goes to whoever happened to slide under the pointer. */

#include "gtk/szfriends_gtk_row_private.h"

/* ---- Clicks -------------------------------------------------------------------------------------- */

void szfriends_gtk_row_press(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row) return;
    row->pressing = TRUE;
    row->press_tenure = row->tenure;
}

void szfriends_gtk_row_release(GtkWidget *widget, gboolean inside) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row) return;
    gboolean same = row->pressing && row->press_tenure == row->tenure;
    row->pressing = FALSE;
    if (inside && same) szfriends_gtk_row_activate(widget);
}

static void pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
    (void)gesture, (void)n_press, (void)x, (void)y;
    szfriends_gtk_row_press(data);
}

static void released(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
    (void)n_press;
    szfriends_gtk_row_release(data, gtk_widget_contains(gtk_event_controller_get_widget(
                                                            GTK_EVENT_CONTROLLER(gesture)), x, y));
}

/* ---- Drops --------------------------------------------------------------------------------------- */

SZFriendsGtkRowDrop szfriends_gtk_row_drop_now(const SZFriendsGtkRow *row) {
    if (!row->dragging || row->drag_tenure != row->tenure || row->verdict == SZFRIENDS_GTK_DROP_NONE)
        return SZFRIENDS_GTK_ROW_DROP_NONE;
    /* A row that takes no files says why whatever comes; one that does refuses folders, links and special files
     * (szfriends_gtk_drop_refused), with the helper's words for each. */
    if (!row->drop_label || szfriends_gtk_drop_refused(row->verdict)) return SZFRIENDS_GTK_ROW_DROP_REFUSE;
    return row->verdict == SZFRIENDS_GTK_DROP_ACCEPT ? SZFRIENDS_GTK_ROW_DROP_ACCEPT : SZFRIENDS_GTK_ROW_DROP_NONE;
}

void szfriends_gtk_row_drag_enter(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row || row->dragging) return;
    row->dragging = TRUE;
    row->drag_tenure = row->tenure;
}

void szfriends_gtk_row_drag_value(GtkWidget *widget, const GValue *value) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row) return;
    /* A value can be the first the row hears of a drag. None is what the target reports after the drag left, which
     * starts nothing. */
    if (value) szfriends_gtk_row_drag_enter(widget);
    row->value_loaded = value != NULL;
    row->verdict = szfriends_gtk_drop_verdict(szfriends_gtk_link_host(row->link), value);
    row->drop = szfriends_gtk_row_drop_now(row);
    szfriends_gtk_row_refresh(row);
}

void szfriends_gtk_row_drag_leave(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row) return;
    row->dragging = row->value_loaded = FALSE;
    row->verdict = SZFRIENDS_GTK_DROP_NONE;
    row->drop = SZFRIENDS_GTK_ROW_DROP_NONE;
    szfriends_gtk_row_refresh(row);
}

gboolean szfriends_gtk_row_drop(GtkWidget *widget, const GValue *value) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row) return FALSE;
    /* A drop the row never saw enter (the suite's direct call) is for whoever holds it now. */
    gboolean same = !row->dragging || row->drag_tenure == row->tenure;
    SZFriendsGtkDropVerdict verdict = SZFRIENDS_GTK_DROP_NONE;
    GPtrArray *items = szfriends_gtk_drop_items(szfriends_gtk_link_host(row->link), value, &verdict);
    szfriends_gtk_row_drag_leave(widget);
    /* One bad file sends none: a folder, a link or a special file anywhere in the drag refuses the whole drop. */
    gboolean taken = same && row->drop_label && verdict == SZFRIENDS_GTK_DROP_ACCEPT && items->len > 0;
    if (taken && row->handlers.dropped) row->handlers.dropped(widget, items, row->handlers_data);
    g_ptr_array_unref(items);
    return taken;
}

SZFriendsGtkRowDrop szfriends_gtk_row_get_drop(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    return row ? row->drop : SZFRIENDS_GTK_ROW_DROP_NONE;
}

/* A row that refuses files still listens to drags when it can say why, so the reason shows under the pointer. */
static gboolean on_accept(GtkDropTarget *target, GdkDrop *drop, gpointer data) {
    SZFriendsGtkRow *row = data;
    return (row->drop_label || (row->drop_refusal && *row->drop_refusal)) &&
           gdk_content_formats_match(gtk_drop_target_get_formats(target), gdk_drop_get_formats(drop));
}

static GdkDragAction on_motion(GtkDropTarget *target, double x, double y, gpointer data) {
    (void)target, (void)x, (void)y;
    SZFriendsGtkRow *row = data;
    /* Until the value arrives nothing is known to be wrong; anything refused shows as soon as it does. */
    return row->drop_label && (!row->value_loaded || row->drop == SZFRIENDS_GTK_ROW_DROP_ACCEPT) ? GDK_ACTION_COPY : 0;
}

static GdkDragAction on_enter(GtkDropTarget *target, double x, double y, gpointer data) {
    szfriends_gtk_row_drag_enter(GTK_WIDGET(((SZFriendsGtkRow *)data)));
    return on_motion(target, x, y, data);
}

static void on_value(GObject *target, GParamSpec *spec, gpointer data) {
    (void)spec;
    szfriends_gtk_row_drag_value(data, gtk_drop_target_get_value(GTK_DROP_TARGET(target)));
}

static gboolean on_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
    (void)target, (void)x, (void)y;
    return szfriends_gtk_row_drop(data, value);
}

static void on_leave(GtkDropTarget *target, gpointer data) {
    (void)target;
    szfriends_gtk_row_drag_leave(data);
}

void szfriends_gtk_row_install_targets(SZFriendsGtkRow *row) {
    GtkWidget *widget = GTK_WIDGET(row);
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "pressed", G_CALLBACK(pressed), row);
    g_signal_connect(click, "released", G_CALLBACK(released), row);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(click));
    gsize n_types = 0;
    GType *types = szfriends_gtk_drop_types(szfriends_gtk_link_host(row->link), &n_types);
    row->target = gtk_drop_target_new(G_TYPE_INVALID, GDK_ACTION_COPY);
    gtk_drop_target_set_gtypes(row->target, types, n_types);
    gtk_drop_target_set_preload(row->target, TRUE); /* the value is needed while hovering, to refuse folders */
    g_free(types);
    g_signal_connect(row->target, "accept", G_CALLBACK(on_accept), row);
    g_signal_connect(row->target, "enter", G_CALLBACK(on_enter), row);
    g_signal_connect(row->target, "motion", G_CALLBACK(on_motion), row);
    g_signal_connect(row->target, "notify::value", G_CALLBACK(on_value), row);
    g_signal_connect(row->target, "drop", G_CALLBACK(on_drop), row);
    g_signal_connect(row->target, "leave", G_CALLBACK(on_leave), row);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(row->target));
}
