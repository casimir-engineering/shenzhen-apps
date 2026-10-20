/* A request row's Accept, Decline and Block, answered without opening the request, and the arming rule they share
 * with every Block in the dropdown (szfriends_gtk_row.h; mirrors mac/SZFriendsRowActions.m and SZFriendsArming.m).
 *
 * Accept and Decline show their word (the action's `title`), so a first-time reader tells Decline from Block; Block
 * is a round red icon button. Each has the snapshot's label as its tooltip and accessible name. Block asks for a
 * second click: the first turns it into a red "Block?" pill and sends nothing; a second,
 * separate click within arm.seconds blocks. The pill turns back when that time passes, on Escape and when the
 * pointer leaves the row, so a pill left behind cannot turn a later stray click into a block. */

#include "gtk/szfriends_gtk_glyphs.h"
#include "gtk/szfriends_gtk_row.h"

#include <string.h>

/* ---- Time ---------------------------------------------------------------------------------------- */

static SZFriendsGtkClock clock_seam;

void szfriends_gtk_set_clock(const SZFriendsGtkClock *clock) {
    if (clock) clock_seam = *clock;
    else memset(&clock_seam, 0, sizeof clock_seam);
}

gint64 szfriends_gtk_clock_now(void) {
    return clock_seam.now_us ? clock_seam.now_us(clock_seam.data) : g_get_monotonic_time();
}

guint szfriends_gtk_clock_schedule(guint milliseconds, GSourceFunc func, gpointer data) {
    if (clock_seam.schedule) return clock_seam.schedule(milliseconds, func, data, clock_seam.data);
    return g_timeout_add(milliseconds, func, data);
}

void szfriends_gtk_clock_cancel(guint id) {
    if (!id) return;
    if (clock_seam.cancel) clock_seam.cancel(id, clock_seam.data);
    else g_source_remove(id);
}

/* ---- Arming -------------------------------------------------------------------------------------- */

struct _SZFriendsGtkArming {
    gboolean armed;
    gint64 armed_at;
    guint source;
    void (*expired)(gpointer data);
    gpointer data;
};

gboolean szfriends_gtk_arm_accepts_confirm(gint64 armed_at_us, gint64 pressed_at_us, int n_press,
                                           gint64 double_click_us) {
    return n_press <= 1 && pressed_at_us - armed_at_us >= double_click_us;
}

SZFriendsGtkArming *szfriends_gtk_arming_new(void) {
    return g_new0(SZFriendsGtkArming, 1);
}

void szfriends_gtk_arming_free(SZFriendsGtkArming *arming) {
    if (!arming) return;
    szfriends_gtk_clock_cancel(arming->source);
    g_free(arming);
}

gboolean szfriends_gtk_arming_is_armed(const SZFriendsGtkArming *arming) {
    return arming && arming->armed;
}

static gboolean arming_expired(gpointer data) {
    SZFriendsGtkArming *arming = data;
    arming->source = 0;
    if (!arming->armed) return G_SOURCE_REMOVE;
    arming->armed = FALSE;
    if (arming->expired) arming->expired(arming->data);
    return G_SOURCE_REMOVE;
}

void szfriends_gtk_arming_arm(SZFriendsGtkArming *arming, double seconds, void (*expired)(gpointer data),
                              gpointer data) {
    /* Cancelled, not left to run: only the latest arming's timer may turn a pill back. */
    szfriends_gtk_clock_cancel(arming->source);
    arming->armed = TRUE;
    arming->armed_at = szfriends_gtk_clock_now();
    arming->expired = expired;
    arming->data = data;
    /* At least a second, so a snapshot without a usable time cannot arm for good; at most a minute, so an absurd
     * one cannot either. NaN fails both comparisons and gets the second. */
    double span = seconds >= 1 ? MIN(seconds, 60) : 1;
    arming->source = szfriends_gtk_clock_schedule((guint)(span * 1000), arming_expired, arming);
}

gboolean szfriends_gtk_arming_press_confirms(SZFriendsGtkArming *arming, int n_press, gint64 double_click_us) {
    return arming && arming->armed &&
           szfriends_gtk_arm_accepts_confirm(arming->armed_at, szfriends_gtk_clock_now(), n_press, double_click_us);
}

gboolean szfriends_gtk_arming_disarm(SZFriendsGtkArming *arming) {
    if (!arming || !arming->armed) return FALSE;
    arming->armed = FALSE;
    szfriends_gtk_clock_cancel(arming->source);
    arming->source = 0;
    return TRUE;
}

gint64 szfriends_gtk_double_click_us(GtkWidget *widget) {
    GtkSettings *settings = widget ? gtk_widget_get_settings(widget) : gtk_settings_get_default();
    int milliseconds = 400;
    if (settings) g_object_get(settings, "gtk-double-click-time", &milliseconds, NULL);
    return (gint64)MAX(milliseconds, 0) * 1000;
}

/* ---- The buttons --------------------------------------------------------------------------------- */

typedef struct {
    SZFriendsGtkActionKind action;
    SZFriendsGtkRowIcon icon;
    char *title, *label, *arm_label, *arm_accessibility_label;
    gboolean has_arm;
    double seconds;
    GtkWidget *button, *glyph, *text;
    int n_press; /* of the press that started the current click; 1 for the keyboard */
} SZFriendsGtkRowButton;

typedef struct {
    GtkWidget *box;
    GArray *buttons; /* SZFriendsGtkRowButton */
    SZFriendsGtkArming *arming;
    SZFriendsGtkRowButton *armed;
    gboolean busy, inactive;
    SZFriendsGtkRowActionFunc func;
    gpointer func_data;
} SZFriendsGtkRowActions;

static SZFriendsGtkRowActions *actions_of(GtkWidget *box) {
    return box ? g_object_get_data(G_OBJECT(box), "szfriends-row-actions") : NULL;
}

gboolean szfriends_gtk_row_action_known(const SZFriendsGtkRowAction *action) {
    if (!action || action->icon == SZFRIENDS_GTK_ICON_UNKNOWN) return FALSE;
    return action->action == SZFRIENDS_GTK_ACTION_ACCEPT_REQUEST ||
           action->action == SZFRIENDS_GTK_ACTION_DECLINE_REQUEST || action->action == SZFRIENDS_GTK_ACTION_BLOCK;
}

static SZFriendsGtkGlyphKind glyph_for(SZFriendsGtkRowIcon icon) {
    switch (icon) {
    case SZFRIENDS_GTK_ICON_ACCEPT: return SZFRIENDS_GTK_GLYPH_CHECK;
    case SZFRIENDS_GTK_ICON_DECLINE: return SZFRIENDS_GTK_GLYPH_CLOSE;
    case SZFRIENDS_GTK_ICON_BLOCK: return SZFRIENDS_GTK_GLYPH_BLOCK;
    default: return SZFRIENDS_GTK_GLYPH_NONE;
    }
}

static void show_labels(SZFriendsGtkRowButton *entry, gboolean armed) {
    const char *name = armed && entry->arm_accessibility_label ? entry->arm_accessibility_label : entry->label;
    gboolean worded = !armed && entry->title && *entry->title;
    gtk_label_set_text(GTK_LABEL(entry->text), armed && entry->arm_label ? entry->arm_label
                                               : worded              ? entry->title
                                                                     : "");
    gtk_widget_set_visible(entry->text, armed || worded);
    gtk_widget_set_visible(entry->glyph, !worded);
    if (worded) gtk_widget_add_css_class(entry->button, "worded");
    else gtk_widget_remove_css_class(entry->button, "worded");
    /* The mockup's sizes: the cross smaller so the three glyphs look the same weight; 13 beside the pill's words. */
    szfriends_gtk_glyph_set_size(entry->glyph, armed ? 13 : entry->icon == SZFRIENDS_GTK_ICON_DECLINE ? 12 : 14);
    if (armed) gtk_widget_add_css_class(entry->button, "armed");
    else gtk_widget_remove_css_class(entry->button, "armed");
    gtk_widget_set_tooltip_text(entry->button, name && *name ? name : NULL);
    if (name && *name)
        gtk_accessible_update_property(GTK_ACCESSIBLE(entry->button), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
}

static void update_sensitive(SZFriendsGtkRowActions *actions) {
    for (guint i = 0; i < actions->buttons->len; i++)
        gtk_widget_set_sensitive(g_array_index(actions->buttons, SZFriendsGtkRowButton, i).button,
                                 !actions->busy && !actions->inactive);
}

gboolean szfriends_gtk_row_actions_disarm(GtkWidget *box) {
    SZFriendsGtkRowActions *actions = actions_of(box);
    if (!actions || !actions->armed) return FALSE;
    szfriends_gtk_arming_disarm(actions->arming);
    show_labels(actions->armed, FALSE);
    actions->armed = NULL;
    return TRUE;
}

static void expired(gpointer data) {
    SZFriendsGtkRowActions *actions = data;
    if (actions->armed) show_labels(actions->armed, FALSE);
    actions->armed = NULL;
}

static void clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkRowActions *actions = data;
    SZFriendsGtkRowButton *entry = NULL;
    for (guint i = 0; i < actions->buttons->len && !entry; i++)
        if (g_array_index(actions->buttons, SZFriendsGtkRowButton, i).button == GTK_WIDGET(button))
            entry = &g_array_index(actions->buttons, SZFriendsGtkRowButton, i);
    if (!entry) return;
    int n_press = entry->n_press > 0 ? entry->n_press : 1;
    entry->n_press = 1;
    if (actions->busy || actions->inactive) return;
    if (entry->has_arm && actions->armed != entry) {
        szfriends_gtk_row_actions_disarm(actions->box);
        actions->armed = entry;
        szfriends_gtk_arming_arm(actions->arming, entry->seconds, expired, actions);
        show_labels(entry, TRUE);
        /* Says what the next click does, in the helper's words ("Click again to block Lena Weber"). */
        if (entry->arm_accessibility_label && *entry->arm_accessibility_label)
            gtk_accessible_announce(GTK_ACCESSIBLE(entry->button), entry->arm_accessibility_label,
                                    GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_HIGH);
        return;
    }
    /* The second half of a double-click, or a click too quick to have read the pill: stay armed, send nothing. */
    if (entry->has_arm &&
        !szfriends_gtk_arming_press_confirms(actions->arming, n_press, szfriends_gtk_double_click_us(actions->box)))
        return;
    szfriends_gtk_row_actions_disarm(actions->box);
    if (actions->func) actions->func(actions->box, entry->action, actions->func_data);
}

/* GtkButton's own gesture says nothing about the click count; this one, in the capture phase, only listens. */
static void pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
    (void)x, (void)y;
    SZFriendsGtkRowActions *actions = data;
    GtkWidget *button = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    for (guint i = 0; i < actions->buttons->len; i++)
        if (g_array_index(actions->buttons, SZFriendsGtkRowButton, i).button == button)
            g_array_index(actions->buttons, SZFriendsGtkRowButton, i).n_press = n_press;
}

static void clear_entry(gpointer data) {
    SZFriendsGtkRowButton *entry = data;
    g_free(entry->label);
    g_free(entry->title);
    g_free(entry->arm_label);
    g_free(entry->arm_accessibility_label);
}

static void actions_free(gpointer data) {
    SZFriendsGtkRowActions *actions = data;
    szfriends_gtk_arming_free(actions->arming);
    g_array_unref(actions->buttons);
    g_free(actions);
}

GtkWidget *szfriends_gtk_row_actions_new(void) {
    SZFriendsGtkRowActions *actions = g_new0(SZFriendsGtkRowActions, 1);
    actions->box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(actions->box, "szfriends-row-actions");
    gtk_widget_set_valign(actions->box, GTK_ALIGN_CENTER);
    actions->buttons = g_array_new(FALSE, TRUE, sizeof(SZFriendsGtkRowButton));
    g_array_set_clear_func(actions->buttons, clear_entry);
    actions->arming = szfriends_gtk_arming_new();
    g_object_set_data_full(G_OBJECT(actions->box), "szfriends-row-actions", actions, actions_free);
    return actions->box;
}

static gboolean same_actions(SZFriendsGtkRowActions *actions, const SZFriendsGtkRowAction *list, gsize count) {
    guint shown = 0;
    for (gsize i = 0; i < count; i++) {
        if (!szfriends_gtk_row_action_known(&list[i])) continue;
        if (shown >= actions->buttons->len) return FALSE;
        SZFriendsGtkRowButton *entry = &g_array_index(actions->buttons, SZFriendsGtkRowButton, shown++);
        const SZFriendsGtkArm *arm = list[i].arm;
        if (entry->action != list[i].action || entry->icon != list[i].icon || g_strcmp0(entry->label, list[i].label) ||
            g_strcmp0(entry->title, list[i].title) ||
            entry->has_arm != (arm != NULL) ||
            (arm && (g_strcmp0(entry->arm_label, arm->label) ||
                     g_strcmp0(entry->arm_accessibility_label, arm->accessibility_label) ||
                     entry->seconds != (double)arm->seconds)))
            return FALSE;
    }
    return shown == actions->buttons->len;
}

static void add_button(SZFriendsGtkRowActions *actions, const SZFriendsGtkRowAction *action) {
    SZFriendsGtkRowButton entry = {0};
    entry.action = action->action;
    entry.icon = action->icon;
    entry.label = g_strdup(action->label);
    entry.title = g_strdup(action->title);
    entry.has_arm = action->arm != NULL;
    if (action->arm) {
        entry.arm_label = g_strdup(action->arm->label);
        entry.arm_accessibility_label = g_strdup(action->arm->accessibility_label);
        entry.seconds = (double)action->arm->seconds;
    }
    entry.n_press = 1;
    entry.button = gtk_button_new();
    gtk_widget_add_css_class(entry.button, "szfriends-row-action");
    gtk_widget_add_css_class(entry.button, action->icon == SZFRIENDS_GTK_ICON_ACCEPT    ? "accept"
                                           : action->icon == SZFRIENDS_GTK_ICON_DECLINE ? "decline"
                                                                                        : "block");
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 5);
    gtk_widget_set_halign(content, GTK_ALIGN_CENTER);
    entry.glyph = szfriends_gtk_glyph_new(glyph_for(action->icon), 14);
    entry.text = gtk_label_new(NULL);
    gtk_box_append(GTK_BOX(content), entry.glyph);
    gtk_box_append(GTK_BOX(content), entry.text);
    gtk_button_set_child(GTK_BUTTON(entry.button), content);
    GtkGesture *gesture = gtk_gesture_click_new();
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(gesture), GTK_PHASE_CAPTURE);
    g_signal_connect(gesture, "pressed", G_CALLBACK(pressed), actions);
    gtk_widget_add_controller(entry.button, GTK_EVENT_CONTROLLER(gesture));
    g_signal_connect(entry.button, "clicked", G_CALLBACK(clicked), actions);
    gtk_box_append(GTK_BOX(actions->box), entry.button);
    g_array_append_val(actions->buttons, entry);
    show_labels(&g_array_index(actions->buttons, SZFriendsGtkRowButton, actions->buttons->len - 1), FALSE);
}

gboolean szfriends_gtk_row_actions_apply(GtkWidget *box, const SZFriendsGtkRowAction *list, gsize count) {
    SZFriendsGtkRowActions *actions = actions_of(box);
    if (!actions) return FALSE;
    if (same_actions(actions, list, count)) return actions->buttons->len > 0;
    szfriends_gtk_row_actions_disarm(box);
    actions->busy = FALSE;
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(box))) gtk_box_remove(GTK_BOX(box), child);
    g_array_set_size(actions->buttons, 0);
    for (gsize i = 0; i < count; i++)
        if (szfriends_gtk_row_action_known(&list[i])) add_button(actions, &list[i]);
    update_sensitive(actions);
    return actions->buttons->len > 0;
}

void szfriends_gtk_row_actions_set_handler(GtkWidget *box, SZFriendsGtkRowActionFunc func, gpointer data) {
    SZFriendsGtkRowActions *actions = actions_of(box);
    if (!actions) return;
    actions->func = func;
    actions->func_data = data;
}

gboolean szfriends_gtk_row_actions_is_armed(GtkWidget *box) {
    SZFriendsGtkRowActions *actions = actions_of(box);
    return actions && actions->armed != NULL;
}

void szfriends_gtk_row_actions_set_busy(GtkWidget *box, gboolean busy) {
    SZFriendsGtkRowActions *actions = actions_of(box);
    if (!actions) return;
    actions->busy = busy;
    update_sensitive(actions);
}

void szfriends_gtk_row_actions_set_inactive(GtkWidget *box, gboolean inactive) {
    SZFriendsGtkRowActions *actions = actions_of(box);
    if (!actions || actions->inactive == inactive) return;
    actions->inactive = inactive;
    if (inactive) szfriends_gtk_row_actions_disarm(box);
    update_sensitive(actions);
}

GtkWidget *szfriends_gtk_row_actions_button(GtkWidget *box, SZFriendsGtkRowIcon icon) {
    SZFriendsGtkRowActions *actions = actions_of(box);
    for (guint i = 0; actions && i < actions->buttons->len; i++)
        if (g_array_index(actions->buttons, SZFriendsGtkRowButton, i).icon == icon)
            return g_array_index(actions->buttons, SZFriendsGtkRowButton, i).button;
    return NULL;
}

void szfriends_gtk_row_actions_click(GtkWidget *button, int n_press) {
    GtkWidget *box = button ? gtk_widget_get_parent(button) : NULL;
    SZFriendsGtkRowActions *actions = actions_of(box);
    for (guint i = 0; actions && i < actions->buttons->len; i++)
        if (g_array_index(actions->buttons, SZFriendsGtkRowButton, i).button == button)
            g_array_index(actions->buttons, SZFriendsGtkRowButton, i).n_press = n_press;
    /* As on screen, where an insensitive button takes no click; an emitted "clicked" would reach it regardless. */
    if (button && gtk_widget_is_sensitive(button)) g_signal_emit_by_name(button, "clicked");
}
