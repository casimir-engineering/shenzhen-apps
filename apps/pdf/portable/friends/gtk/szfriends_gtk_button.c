/* The Friends button: two people (never a speech bubble, which is AI chat), the helper's badge, and a drop target
 * that spring-loads the dropdown open (brief § Interface; mirrors mac/SZFriendsTitleButton.m).
 *
 * What the host places is a GtkOverlay: the GtkMenuButton, with the badge over its top-right corner. The badge
 * takes no clicks, so the button keeps one hit area, and it sits inside the button's own frame, never over the
 * header bar next to it. Files dragged over it highlight it; resting there 500 ms opens the dropdown on the list so
 * the drop can land on a row (as Finder's folders spring open); releasing on the button opens "Send 2 files to…". */

#include "gtk/szfriends_gtk_drops.h"
#include "gtk/szfriends_gtk_internal.h"
#include "gtk/szfriends_gtk_link_private.h"

typedef struct {
    SZFriendsGtkLink *link;
    GtkWidget *anchor, *menu_button, *badge;
    SZFriendsGtkDropdown *dropdown;
    GtkDropTarget *drop;
    SZFriendsGtkDropVerdict verdict;
    gboolean value_loaded, highlighted;
    guint spring_source, spring_delay_ms, badge_watch, state_watch;
} SZFriendsGtkButton;

static SZFriendsGtkButton *button_of(GtkWidget *anchor) {
    return anchor ? g_object_get_data(G_OBJECT(anchor), "szfriends-button") : NULL;
}

/* ---- Badge and words ----------------------------------------------------------------------------- */

static void apply_labels(SZFriendsGtkButton *button) {
    const SZFriendsGtkBadgeSnapshot *badge = szfriends_gtk_link_badge(button->link);
    const char *label = badge ? badge->label : "";
    gtk_label_set_text(GTK_LABEL(button->badge), label);
    gtk_widget_set_visible(button->badge, *label != '\0');
    if (*label) gtk_widget_add_css_class(button->anchor, "szfriends-badged");
    else gtk_widget_remove_css_class(button->anchor, "szfriends-badged");
    /* "Friends, 2 waiting for you" from the helper; the static "Friends" before its first badge. Nothing invented. */
    const char *name = szfriends_gtk_link_string(button->link, "button_label");
    const char *spoken = badge && *badge->accessibility_label ? badge->accessibility_label : name;
    if (*spoken)
        gtk_accessible_update_property(GTK_ACCESSIBLE(button->menu_button), GTK_ACCESSIBLE_PROPERTY_LABEL, spoken, -1);
    /* "Friends (Beta)": the tooltip says Friends is a beta; a helper without button_tooltip gives the plain name. */
    const char *tooltip = szfriends_gtk_link_string(button->link, "button_tooltip");
    if (!*tooltip) tooltip = name;
    gtk_widget_set_tooltip_text(button->menu_button, *tooltip ? tooltip : NULL);
}

static void badge_changed(SZFriendsGtkLink *link, const SZFriendsGtkBadgeSnapshot *badge, gpointer data) {
    (void)link, (void)badge;
    apply_labels(data);
}

static void state_changed(SZFriendsGtkLink *link, SZFriendsGtkLinkState state, gpointer data) {
    (void)link, (void)state;
    apply_labels(data); /* the welcome brought the static strings */
}

/* ---- Drops --------------------------------------------------------------------------------------- */

static void set_highlight(SZFriendsGtkButton *button, gboolean on) {
    button->highlighted = on;
    if (on) gtk_widget_add_css_class(button->anchor, "szfriends-drop-accept");
    else gtk_widget_remove_css_class(button->anchor, "szfriends-drop-accept");
}

static gboolean host_accepts(SZFriendsGtkButton *button, GdkDrop *drop) {
    const SZFriendsGtkHost *host = szfriends_gtk_link_host(button->link);
    return !drop || !host->button_accepts_drop || host->button_accepts_drop(host->host_data, drop);
}

/* The value arrived (the drop target preloads it): folders, links and special files refuse here, before any
 * intent, as rows and the conversation refuse them. */
void szfriends_gtk_button_drag_value(GtkWidget *anchor, const GValue *value) {
    SZFriendsGtkButton *button = button_of(anchor);
    if (!button) return;
    button->value_loaded = value != NULL;
    button->verdict = szfriends_gtk_drop_verdict(szfriends_gtk_link_host(button->link), value);
    set_highlight(button, button->verdict == SZFRIENDS_GTK_DROP_ACCEPT);
    if (szfriends_gtk_drop_refused(button->verdict) && button->drop && gtk_drop_target_get_current_drop(button->drop))
        gtk_drop_target_reject(button->drop);
}

static gboolean spring_open(gpointer data) {
    SZFriendsGtkButton *button = data;
    button->spring_source = 0;
    /* Refused files spring the dropdown open too, so the refusal shows where the person is looking; they never get
     * drop_hint's "Drop on a friend to send", which would promise what cannot happen. Without the helper's words
     * for a refusal the list shows no hint at all. */
    const char *hint = szfriends_gtk_drop_refused(button->verdict)
                           ? szfriends_gtk_drop_refusal(button->link, button->verdict)
                           : szfriends_gtk_link_string(button->link, "drop_hint");
    szfriends_gtk_dropdown_open(button->dropdown);
    szfriends_gtk_dropdown_pop_to_list(button->dropdown);
    szfriends_gtk_dropdown_set_drop_hint(button->dropdown, hint);
    return G_SOURCE_REMOVE;
}

void szfriends_gtk_button_drag_enter(GtkWidget *anchor, GdkDrop *drop) {
    SZFriendsGtkButton *button = button_of(anchor);
    if (!button || !host_accepts(button, drop)) return;
    if (!button->spring_source)
        button->spring_source = g_timeout_add(button->spring_delay_ms, spring_open, button);
}

void szfriends_gtk_button_drag_leave(GtkWidget *anchor) {
    SZFriendsGtkButton *button = button_of(anchor);
    if (!button) return;
    if (button->spring_source) g_source_remove(button->spring_source);
    button->spring_source = 0;
    button->value_loaded = FALSE;
    button->verdict = SZFRIENDS_GTK_DROP_NONE;
    set_highlight(button, FALSE);
}

gboolean szfriends_gtk_button_drop(GtkWidget *anchor, const GValue *value) {
    SZFriendsGtkButton *button = button_of(anchor);
    if (!button) return FALSE;
    SZFriendsGtkDropVerdict verdict = SZFRIENDS_GTK_DROP_NONE;
    GPtrArray *items = szfriends_gtk_drop_items(szfriends_gtk_link_host(button->link), value, &verdict);
    szfriends_gtk_button_drag_leave(anchor);
    gboolean taken = verdict == SZFRIENDS_GTK_DROP_ACCEPT && items->len > 0;
    if (taken) szfriends_gtk_dropdown_begin_send_picker(button->dropdown, items); /* sends to the friend clicked next */
    g_ptr_array_unref(items);
    return taken;
}

static gboolean on_accept(GtkDropTarget *target, GdkDrop *drop, gpointer data) {
    SZFriendsGtkButton *button = data;
    return host_accepts(button, drop) &&
           gdk_content_formats_match(gtk_drop_target_get_formats(target), gdk_drop_get_formats(drop));
}

static GdkDragAction on_motion(GtkDropTarget *target, double x, double y, gpointer data) {
    (void)target, (void)x, (void)y;
    SZFriendsGtkButton *button = data;
    /* Until the value arrives nothing is known to be wrong; refused files are rejected as soon as it does. */
    return !button->value_loaded || button->verdict == SZFRIENDS_GTK_DROP_ACCEPT ? GDK_ACTION_COPY : 0;
}

static void on_value(GObject *target, GParamSpec *spec, gpointer data) {
    (void)spec;
    szfriends_gtk_button_drag_value(((SZFriendsGtkButton *)data)->anchor,
                                    gtk_drop_target_get_value(GTK_DROP_TARGET(target)));
}

static gboolean on_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
    (void)target, (void)x, (void)y;
    return szfriends_gtk_button_drop(((SZFriendsGtkButton *)data)->anchor, value);
}

static void on_drop_leave(GtkDropTarget *target, gpointer data) {
    (void)target;
    SZFriendsGtkButton *button = data;
    set_highlight(button, FALSE);
}

static void on_motion_enter(GtkDropControllerMotion *motion, double x, double y, gpointer data) {
    (void)x, (void)y;
    SZFriendsGtkButton *button = data;
    GdkDrop *drop = gtk_drop_controller_motion_get_drop(motion);
    GdkContentFormats *ours = gtk_drop_target_get_formats(button->drop);
    if (drop && gdk_content_formats_match(ours, gdk_drop_get_formats(drop)))
        szfriends_gtk_button_drag_enter(button->anchor, drop);
}

static void on_motion_leave(GtkDropControllerMotion *motion, gpointer data) {
    (void)motion;
    szfriends_gtk_button_drag_leave(((SZFriendsGtkButton *)data)->anchor);
}

static void install_drop_target(SZFriendsGtkButton *button) {
    gsize n_types = 0;
    GType *types = szfriends_gtk_drop_types(szfriends_gtk_link_host(button->link), &n_types);
    button->drop = gtk_drop_target_new(G_TYPE_INVALID, GDK_ACTION_COPY);
    gtk_drop_target_set_gtypes(button->drop, types, n_types);
    gtk_drop_target_set_preload(button->drop, TRUE); /* the value is needed while hovering, to refuse folders */
    g_free(types);
    g_signal_connect(button->drop, "accept", G_CALLBACK(on_accept), button);
    g_signal_connect(button->drop, "enter", G_CALLBACK(on_motion), button);
    g_signal_connect(button->drop, "motion", G_CALLBACK(on_motion), button);
    g_signal_connect(button->drop, "notify::value", G_CALLBACK(on_value), button);
    g_signal_connect(button->drop, "drop", G_CALLBACK(on_drop), button);
    g_signal_connect(button->drop, "leave", G_CALLBACK(on_drop_leave), button);
    gtk_widget_add_controller(button->anchor, GTK_EVENT_CONTROLLER(button->drop));
    GtkEventController *motion = gtk_drop_controller_motion_new();
    g_signal_connect(motion, "enter", G_CALLBACK(on_motion_enter), button);
    g_signal_connect(motion, "leave", G_CALLBACK(on_motion_leave), button);
    gtk_widget_add_controller(button->anchor, motion);
}

/* ---- Lifetime ------------------------------------------------------------------------------------ */

static void button_free(gpointer data) {
    SZFriendsGtkButton *button = data;
    if (button->spring_source) g_source_remove(button->spring_source);
    szfriends_gtk_link_remove_badge_watch(button->link, button->badge_watch);
    szfriends_gtk_link_remove_state_watch(button->link, button->state_watch);
    szfriends_gtk_dropdown_free(button->dropdown);
    szfriends_gtk_link_unref(button->link);
    g_free(button);
}

GtkWidget *szfriends_gtk_button_new(SZFriendsGtkLink *link, GtkWindow *window) {
    g_return_val_if_fail(link, NULL);
    const SZFriendsGtkHost *host = szfriends_gtk_link_host(link);
    GdkDisplay *display = window ? gtk_widget_get_display(GTK_WIDGET(window)) : gdk_display_get_default();
    szfriends_gtk_style_ensure(display, host);
    SZFriendsGtkButton *button = g_new0(SZFriendsGtkButton, 1);
    button->link = link;
    szfriends_gtk_link_ref(link);
    button->spring_delay_ms = 500;
    button->anchor = gtk_overlay_new();
    gtk_widget_set_name(button->anchor, "szfriends.title-button");
    gtk_widget_add_css_class(button->anchor, "szfriends-title-button");
    button->menu_button = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(button->menu_button), SZFRIENDS_GTK_ICON_PEOPLE);
    gtk_menu_button_set_always_show_arrow(GTK_MENU_BUTTON(button->menu_button), FALSE);
    gtk_widget_add_css_class(button->menu_button, "flat");
    if (host->title_bar_button_size > 0)
        gtk_widget_set_size_request(button->menu_button, host->title_bar_button_size, host->title_bar_button_size);
    gtk_overlay_set_child(GTK_OVERLAY(button->anchor), button->menu_button);
    button->badge = gtk_label_new(NULL);
    gtk_widget_add_css_class(button->badge, "szfriends-badge");
    gtk_widget_set_halign(button->badge, GTK_ALIGN_END);
    gtk_widget_set_valign(button->badge, GTK_ALIGN_START);
    gtk_widget_set_can_target(button->badge, FALSE);
    gtk_accessible_update_state(GTK_ACCESSIBLE(button->badge), GTK_ACCESSIBLE_STATE_HIDDEN, TRUE, -1);
    gtk_overlay_add_overlay(GTK_OVERLAY(button->anchor), button->badge);
    gtk_overlay_set_clip_overlay(GTK_OVERLAY(button->anchor), button->badge, TRUE);
    button->dropdown = szfriends_gtk_dropdown_new(link, window, button->anchor,
                                                  GTK_MENU_BUTTON(button->menu_button));
    install_drop_target(button);
    g_object_set_data_full(G_OBJECT(button->anchor), "szfriends-button", button, button_free);
    g_object_set_data(G_OBJECT(button->anchor), "szfriends-dropdown", button->dropdown);
    button->badge_watch = szfriends_gtk_link_add_badge_watch(link, badge_changed, button);
    button->state_watch = szfriends_gtk_link_add_state_watch(link, state_changed, button, NULL);
    apply_labels(button);
    return button->anchor;
}

/* ---- For the suite ------------------------------------------------------------------------------- */

GtkWidget *szfriends_gtk_button_get_menu_button(GtkWidget *anchor) {
    return button_of(anchor) ? button_of(anchor)->menu_button : NULL;
}

GtkWidget *szfriends_gtk_button_get_badge(GtkWidget *anchor) {
    return button_of(anchor) ? button_of(anchor)->badge : NULL;
}

gboolean szfriends_gtk_button_is_highlighted(GtkWidget *anchor) {
    return button_of(anchor) && button_of(anchor)->highlighted;
}

void szfriends_gtk_button_set_spring_delay(GtkWidget *anchor, guint milliseconds) {
    if (button_of(anchor)) button_of(anchor)->spring_delay_ms = milliseconds;
}
