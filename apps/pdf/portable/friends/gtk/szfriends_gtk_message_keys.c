/* The keyboard path to a bubble's links and mentions (szfriends_gtk_conversation.h).
 *
 * WHY: links and mentions in a bubble are words inside one selectable GtkLabel, hit-tested by hand because markup
 * links are not allowed there (a friend's "<b>" must stay "<b>"). GtkLabel's own link focus only knows markup links,
 * so without this a keyboard reached the bubble's words but none of what they open. Here the label keeps one marked
 * segment: focus arriving from the keyboard marks the first segment that acts, Tab and the arrow keys step through
 * those segments, Tab past the last (or Shift+Tab before the first) lets focus leave the bubble as usual, and Return
 * or Space does what a click on the marked segment does (szfriends_gtk_message_activate). The mark is a faint accent
 * fill with an underline, so it shows even where the accent cannot be read. */

#include "gtk/szfriends_gtk_conversation.h"

#include <string.h>

typedef struct {
    SZFriendsGtkConversation *conversation;
    GObject *holder; /* keeps the item alive after the snapshot moved on */
    const SZFriendsGtkConversationItem *item;
    GArray *ranges;            /* guint start and end per segment, in the full text */
    PangoAttrList *attributes; /* the words' own look, without the mark */
    gssize focused;
} SZFriendsGtkLinkKeys;

static void keys_free(gpointer data) {
    SZFriendsGtkLinkKeys *keys = data;
    g_array_unref(keys->ranges);
    pango_attr_list_unref(keys->attributes);
    g_object_unref(keys->holder);
    szfriends_gtk_conversation_unref(keys->conversation);
    g_free(keys);
}

static SZFriendsGtkLinkKeys *keys_of(GtkWidget *label) {
    return label ? g_object_get_data(G_OBJECT(label), "szfriends-keys") : NULL;
}

/* A segment acts when a click on it would (a link that may open, a friend's or a stranger's mention) and it is
 * shown: a long message cut before Show all keeps the rest out of reach until it shows. */
static gboolean acts(SZFriendsGtkLinkKeys *keys, GtkWidget *label, gssize segment) {
    if (segment < 0 || (gsize)segment >= keys->item->n_segments || 2 * (guint)segment + 1 >= keys->ranges->len)
        return FALSE;
    guint start = g_array_index(keys->ranges, guint, 2 * segment);
    guint end = g_array_index(keys->ranges, guint, 2 * segment + 1);
    return start < end && start < strlen(gtk_label_get_text(GTK_LABEL(label))) &&
           szfriends_gtk_link_hit(keys->item, (gsize)segment).kind != SZFRIENDS_GTK_HIT_NONE;
}

/* The next segment that acts from `from` in `direction` (+1 or -1); from -1, the first or the last one. */
static gssize step(SZFriendsGtkLinkKeys *keys, GtkWidget *label, gssize from, int direction) {
    gssize count = (gssize)keys->item->n_segments;
    gssize at = from < 0 ? (direction > 0 ? 0 : count - 1) : from + direction;
    for (; at >= 0 && at < count; at += direction)
        if (acts(keys, label, at)) return at;
    return -1;
}

static void insert(PangoAttrList *list, PangoAttribute *attribute, guint start, guint end) {
    attribute->start_index = start, attribute->end_index = end;
    pango_attr_list_insert(list, attribute);
}

static guint16 channel(float value) {
    return (guint16)(CLAMP(value, 0.f, 1.f) * 65535.f);
}

static void mark(SZFriendsGtkLinkKeys *keys, GtkWidget *label, gssize segment) {
    keys->focused = segment;
    PangoAttrList *list = pango_attr_list_copy(keys->attributes);
    if (segment >= 0) {
        guint start = g_array_index(keys->ranges, guint, 2 * segment);
        guint end = g_array_index(keys->ranges, guint, 2 * segment + 1);
        GdkRGBA accent;
        if (szfriends_gtk_conversation_accent(keys->conversation, &accent)) {
            insert(list, pango_attr_background_new(channel(accent.red), channel(accent.green), channel(accent.blue)),
                   start, end);
            insert(list, pango_attr_background_alpha_new(0x3000), start, end);
        }
        insert(list, pango_attr_underline_new(PANGO_UNDERLINE_SINGLE), start, end);
        /* What the marked words do, in the helper's words for a mention ("Open your chat with Mei") or the address
         * a link goes to; the words themselves are spoken as the mark reaches them. */
        SZFriendsGtkHit hit = szfriends_gtk_link_hit(keys->item, (gsize)segment);
        const char *about = hit.mention && hit.mention->tooltip && *hit.mention->tooltip ? hit.mention->tooltip
                                                                                         : hit.url;
        gtk_accessible_update_property(GTK_ACCESSIBLE(label), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION,
                                       about ? about : "", -1);
        const char *words = keys->item->segments[segment].text;
        if (words && *words)
            gtk_accessible_announce(GTK_ACCESSIBLE(label), words, GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
    } else {
        gtk_accessible_reset_property(GTK_ACCESSIBLE(label), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION);
    }
    gtk_label_set_attributes(GTK_LABEL(label), list);
    pango_attr_list_unref(list);
}

gssize szfriends_gtk_message_focused_segment(GtkWidget *label) {
    SZFriendsGtkLinkKeys *keys = keys_of(label);
    return keys ? keys->focused : -1;
}

gboolean szfriends_gtk_message_key(GtkWidget *label, guint keyval, GdkModifierType state) {
    SZFriendsGtkLinkKeys *keys = keys_of(label);
    if (!keys) return FALSE;
    gboolean back_tab = keyval == GDK_KEY_ISO_Left_Tab ||
                        ((keyval == GDK_KEY_Tab || keyval == GDK_KEY_KP_Tab) && (state & GDK_SHIFT_MASK));
    if (back_tab || keyval == GDK_KEY_Tab || keyval == GDK_KEY_KP_Tab) {
        gssize next = step(keys, label, keys->focused, back_tab ? -1 : 1);
        mark(keys, label, next);
        return next >= 0; /* none left that way: focus leaves the bubble as Tab always does */
    }
    int direction = 0;
    if (keyval == GDK_KEY_Right || keyval == GDK_KEY_KP_Right || keyval == GDK_KEY_Down || keyval == GDK_KEY_KP_Down)
        direction = 1;
    if (keyval == GDK_KEY_Left || keyval == GDK_KEY_KP_Left || keyval == GDK_KEY_Up || keyval == GDK_KEY_KP_Up)
        direction = -1;
    if (direction) {
        /* The arrows stay inside the bubble: at either end the mark stays where it is. */
        gssize next = step(keys, label, keys->focused, direction);
        if (next >= 0) mark(keys, label, next);
        return TRUE;
    }
    gboolean activate = keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter || keyval == GDK_KEY_ISO_Enter ||
                        keyval == GDK_KEY_space || keyval == GDK_KEY_KP_Space;
    if (!activate || keys->focused < 0) return FALSE;
    szfriends_gtk_message_activate(keys->conversation, keys->item, (gsize)keys->focused, label);
    return TRUE;
}

void szfriends_gtk_message_focus_changed(GtkWidget *label, gboolean focused) {
    SZFriendsGtkLinkKeys *keys = keys_of(label);
    if (!keys) return;
    if (!focused) {
        if (keys->focused >= 0) mark(keys, label, -1);
        return;
    }
    if (keys->focused >= 0) return;
    /* The words were selected whole by focusing them; the mark takes the selection's place, so one thing shows. */
    gtk_label_select_region(GTK_LABEL(label), 0, 0);
    mark(keys, label, step(keys, label, -1, 1));
}

/* GtkLabel selects all its words when focus reaches it other than by a click, after the focus change itself: that
 * selection is how this tells the keyboard from a click on the words, which must leave a text selection alone. */
static gboolean check_keyboard_focus(gpointer data) {
    GtkWidget *label = data;
    int start = 0, end = 0;
    glong length = g_utf8_strlen(gtk_label_get_text(GTK_LABEL(label)), -1);
    GtkRoot *root = gtk_widget_get_root(label);
    if (root && gtk_root_get_focus(root) == label && gtk_label_get_selection_bounds(GTK_LABEL(label), &start, &end) &&
        start == 0 && end == length)
        szfriends_gtk_message_focus_changed(label, TRUE);
    g_object_unref(label);
    return G_SOURCE_REMOVE;
}

static void focus_entered(GtkEventControllerFocus *focus, gpointer data) {
    (void)data;
    GtkWidget *label = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(focus));
    g_idle_add_full(G_PRIORITY_HIGH, check_keyboard_focus, g_object_ref(label), NULL);
}

static void focus_left(GtkEventControllerFocus *focus, gpointer data) {
    (void)data;
    szfriends_gtk_message_focus_changed(gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(focus)), FALSE);
}

static gboolean key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state,
                            gpointer data) {
    (void)keycode, (void)data;
    return szfriends_gtk_message_key(gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(controller)), keyval,
                                     state);
}

void szfriends_gtk_message_keys_attach(SZFriendsGtkConversation *conversation, GObject *holder,
                                       const SZFriendsGtkConversationItem *item, GtkWidget *label, GArray *ranges,
                                       PangoAttrList *attributes) {
    SZFriendsGtkLinkKeys *keys = g_new0(SZFriendsGtkLinkKeys, 1);
    keys->conversation = szfriends_gtk_conversation_ref(conversation);
    keys->holder = g_object_ref(holder);
    keys->item = item;
    keys->ranges = g_array_ref(ranges);
    keys->attributes = pango_attr_list_ref(attributes);
    keys->focused = -1;
    g_object_set_data_full(G_OBJECT(label), "szfriends-keys", keys, keys_free);
    /* Before the label's own keys, which would move its caret on the arrows and select on Shift. */
    GtkEventController *controller = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE);
    g_signal_connect(controller, "key-pressed", G_CALLBACK(key_pressed), NULL);
    gtk_widget_add_controller(label, controller);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(focus_entered), NULL);
    g_signal_connect(focus, "leave", G_CALLBACK(focus_left), NULL);
    gtk_widget_add_controller(label, focus);
}
