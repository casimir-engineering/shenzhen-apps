/* Buttons for PROTOCOL.md action objects, with `arm`, and the plain-text labels the details, profile and Settings
 * pages are made of (szfriends_gtk_details_page.h). Mirrors mac/SZFriendsArming.m through the one arming rule and
 * clock every Block in the views shares (szfriends_gtk_row.h).
 *
 * Styles are libadwaita's own classes, so the buttons look native in a GNOME host: primary is suggested-action,
 * link a flat accent-coloured label, destructive a flat red one, and an armed pill destructive-action, the tinted
 * red button with red text that the AppKit views draw for "Block?". */

#include "gtk/szfriends_gtk_details_page.h"

#include <adwaita.h>
#include <string.h>

#define BUTTON_KEY "szfriends-action-button"

typedef struct {
    SZFriendsGtkPage *page;
    GtkWidget *button;
    SZFriendsGtkDetailsHeld *held;
    const SZFriendsGtkAction *action; /* inside `held` */
    char *ids[6];
    SZFriendsGtkActionIds id_view;
    SZFriendsGtkArming *arming;
    int n_press; /* of the press that started the current click; 1 for the keyboard */
} SZFriendsGtkDetailsButton;

static void state_free(gpointer data) {
    SZFriendsGtkDetailsButton *state = data;
    szfriends_gtk_arming_free(state->arming); /* cancels its timer: it must never reach a freed button */
    szfriends_gtk_details_held_unref(state->held);
    for (gsize i = 0; i < G_N_ELEMENTS(state->ids); i++) g_free(state->ids[i]);
    g_free(state);
}

static void apply_style(SZFriendsGtkDetailsButton *state) {
    static const char *const classes[] = {"flat", "error", "accent", "suggested-action", "destructive-action",
                                          "szfriends-text-action"};
    for (gsize i = 0; i < G_N_ELEMENTS(classes); i++) gtk_widget_remove_css_class(state->button, classes[i]);
    if (szfriends_gtk_arming_is_armed(state->arming)) {
        gtk_widget_add_css_class(state->button, "destructive-action");
        return;
    }
    switch (state->action->style) {
    case SZFRIENDS_GTK_STYLE_PRIMARY: gtk_widget_add_css_class(state->button, "suggested-action"); break;
    case SZFRIENDS_GTK_STYLE_LINK:
    case SZFRIENDS_GTK_STYLE_DESTRUCTIVE:
        gtk_widget_add_css_class(state->button, "flat");
        gtk_widget_add_css_class(state->button, "szfriends-text-action");
        gtk_widget_add_css_class(state->button,
                                 state->action->style == SZFRIENDS_GTK_STYLE_LINK ? "accent" : "error");
        break;
    default: break;
    }
}

/* Called after the arming changed: the label, the accessible name and the style follow it. */
static void show_armed(SZFriendsGtkDetailsButton *state) {
    const SZFriendsGtkArm *arm = state->action->arm;
    GtkWidget *button = state->button;
    if (szfriends_gtk_arming_is_armed(state->arming)) {
        /* Never narrower than the label it replaces: the pointer that armed it must still be inside, or the pill
         * would turn back at once as the pointer "left" it. */
        int width = gtk_widget_get_width(button);
        if (width > 0) gtk_widget_set_size_request(button, width, -1);
        gtk_button_set_label(GTK_BUTTON(button), *arm->label ? arm->label : state->action->label);
        if (*arm->accessibility_label) {
            gtk_accessible_update_property(GTK_ACCESSIBLE(button), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                           arm->accessibility_label, -1);
            gtk_widget_set_tooltip_text(button, arm->accessibility_label);
        }
        szfriends_gtk_details_announce(button, arm->accessibility_label);
    } else {
        gtk_widget_set_size_request(button, -1, -1);
        gtk_button_set_label(GTK_BUTTON(button), state->action->label);
        gtk_accessible_reset_property(GTK_ACCESSIBLE(button), GTK_ACCESSIBLE_PROPERTY_LABEL);
        gtk_widget_set_tooltip_text(button, NULL);
    }
    apply_style(state);
}

static gboolean disarm(SZFriendsGtkDetailsButton *state) {
    if (!state || !szfriends_gtk_arming_disarm(state->arming)) return FALSE;
    show_armed(state);
    return TRUE;
}

/* The arming's timer ran out: only the latest arming's timer exists, so an old one never turns a new pill back. */
static void expired(gpointer data) {
    show_armed(data);
}

/* GtkButton's own gesture says nothing about the click count; this one, in the capture phase, only listens. */
static void pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
    (void)gesture, (void)x, (void)y;
    ((SZFriendsGtkDetailsButton *)data)->n_press = n_press;
}

/* Removed, the person is off the list, and their details and chat have nobody to show: back to the list, while the
 * page that asked is still there. */
typedef struct {
    GWeakRef page;
    SZFriendsGtkDropdown *dropdown;
} SZFriendsGtkRemoved;

static void removed(JsonObject *result, const SZFriendsGtkError *error, gpointer data) {
    SZFriendsGtkRemoved *then = data;
    GtkWidget *page = g_weak_ref_get(&then->page);
    /* A cancelled question answers with neither a result nor an error: nobody was removed. */
    if (result && !error && page) szfriends_gtk_dropdown_pop_to_list(then->dropdown);
    if (page) g_object_unref(page);
    g_weak_ref_clear(&then->page);
    g_free(then);
}

static void clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkDetailsButton *state = data;
    int n_press = state->n_press > 0 ? state->n_press : 1;
    state->n_press = 1; /* a keyboard activation has no press: one, now */
    const SZFriendsGtkArm *arm = state->action->arm;
    if (arm && !szfriends_gtk_arming_is_armed(state->arming)) {
        szfriends_gtk_arming_arm(state->arming, (double)arm->seconds, expired, state);
        show_armed(state);
        return;
    }
    /* The second half of a double-click, or a click too quick to have read the pill: stay armed, send nothing. */
    if (arm && !szfriends_gtk_arming_press_confirms(state->arming, n_press,
                                                    szfriends_gtk_double_click_us(GTK_WIDGET(button))))
        return;
    disarm(state);
    SZFriendsGtkPage *page = state->page;
    SZFriendsGtkDropdown *dropdown = szfriends_gtk_page_get_dropdown(page);
    SZFriendsGtkRemoved *then = NULL;
    if (state->action->action == SZFRIENDS_GTK_ACTION_REMOVE_FRIEND && dropdown) {
        then = g_new0(SZFriendsGtkRemoved, 1);
        g_weak_ref_init(&then->page, szfriends_gtk_page_get_widget(page));
        then->dropdown = dropdown;
    }
    szfriends_gtk_perform(szfriends_gtk_page_get_link(page), dropdown, GTK_WIDGET(button), state->action,
                          &state->id_view, then ? removed : NULL, then);
}

/* Leaving the button turns the pill back, so a "Block?" never waits for a click aimed at something else. */
static void left(GtkEventControllerMotion *motion, gpointer data) {
    (void)motion;
    disarm(data);
}

GtkWidget *szfriends_gtk_details_button_new(SZFriendsGtkPage *page, SZFriendsGtkDetailsHeld *held,
                                            const SZFriendsGtkAction *action, const SZFriendsGtkActionIds *ids) {
    if (!action || !szfriends_gtk_action_is_known(action->action)) return NULL;
    SZFriendsGtkDetailsButton *state = g_new0(SZFriendsGtkDetailsButton, 1);
    state->page = page;
    state->held = szfriends_gtk_details_held_ref(held);
    state->action = action;
    state->arming = szfriends_gtk_arming_new();
    state->n_press = 1;
    if (ids) {
        const char *values[6] = {ids->conversation_id, ids->nearby_id, ids->transfer_id, ids->item_id, ids->kind,
                                 ids->message_id};
        for (gsize i = 0; i < 6; i++) state->ids[i] = g_strdup(values[i]);
    }
    state->id_view = (SZFriendsGtkActionIds){state->ids[0], state->ids[1], state->ids[2], state->ids[3],
                                             state->ids[4], state->ids[5]};
    state->button = gtk_button_new_with_label(action->label);
    gtk_widget_set_halign(state->button, GTK_ALIGN_START);
    g_object_set_data_full(G_OBJECT(state->button), BUTTON_KEY, state, state_free);
    apply_style(state);
    GtkGesture *gesture = gtk_gesture_click_new();
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(gesture), GTK_PHASE_CAPTURE);
    g_signal_connect(gesture, "pressed", G_CALLBACK(pressed), state);
    gtk_widget_add_controller(state->button, GTK_EVENT_CONTROLLER(gesture));
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "leave", G_CALLBACK(left), state);
    gtk_widget_add_controller(state->button, motion);
    g_signal_connect(state->button, "clicked", G_CALLBACK(clicked), state);
    return state->button;
}

static gboolean same_confirm(const SZFriendsGtkConfirm *a, const SZFriendsGtkConfirm *b) {
    if (!a || !b) return a == b;
    return !g_strcmp0(a->title, b->title) && !g_strcmp0(a->body, b->body) &&
           !g_strcmp0(a->confirm_label, b->confirm_label) && !g_strcmp0(a->cancel_label, b->cancel_label) &&
           a->destructive == b->destructive;
}

static gboolean same_arm(const SZFriendsGtkArm *a, const SZFriendsGtkArm *b) {
    if (!a || !b) return a == b;
    return !g_strcmp0(a->label, b->label) && !g_strcmp0(a->accessibility_label, b->accessibility_label) &&
           a->seconds == b->seconds;
}

gboolean szfriends_gtk_details_button_matches(GtkWidget *button, const SZFriendsGtkAction *action,
                                              const SZFriendsGtkActionIds *ids) {
    SZFriendsGtkDetailsButton *state = button ? g_object_get_data(G_OBJECT(button), BUTTON_KEY) : NULL;
    if (!state || !action) return FALSE;
    const SZFriendsGtkAction *mine = state->action;
    if (mine->action != action->action || mine->style != action->style || g_strcmp0(mine->label, action->label) ||
        g_strcmp0(mine->note, action->note) || g_strcmp0(mine->path, action->path) ||
        mine->settings_target != action->settings_target || !same_arm(mine->arm, action->arm) ||
        !same_confirm(mine->confirm, action->confirm))
        return FALSE;
    /* The fields an action carries itself: two join rows' Deny, or two computers' Remove, are different buttons. */
    const char *own[][2] = {{mine->friends_id, action->friends_id}, {mine->identity_key, action->identity_key},
                            {mine->name, action->name}, {mine->payload, action->payload},
                            {mine->link_id, action->link_id}, {mine->device_id, action->device_id},
                            {mine->join_id, action->join_id}};
    for (gsize i = 0; i < G_N_ELEMENTS(own); i++)
        if (g_strcmp0(own[i][0], own[i][1])) return FALSE;
    static const SZFriendsGtkActionIds none = {0};
    if (!ids) ids = &none;
    const char *values[6] = {ids->conversation_id, ids->nearby_id, ids->transfer_id, ids->item_id, ids->kind,
                             ids->message_id};
    for (gsize i = 0; i < 6; i++)
        if (g_strcmp0(state->ids[i], values[i])) return FALSE;
    return TRUE;
}

gboolean szfriends_gtk_details_button_is_armed(GtkWidget *button) {
    SZFriendsGtkDetailsButton *state = button ? g_object_get_data(G_OBJECT(button), BUTTON_KEY) : NULL;
    return state && szfriends_gtk_arming_is_armed(state->arming);
}

gboolean szfriends_gtk_details_disarm(GtkWidget *root) {
    if (!root) return FALSE;
    gboolean any = disarm(g_object_get_data(G_OBJECT(root), BUTTON_KEY));
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child))
        any = szfriends_gtk_details_disarm(child) || any;
    return any;
}

/* ---- Labels ---------------------------------------------------------------------------------------------- */

GtkWidget *szfriends_gtk_details_label(const char *classes) {
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_widget_set_hexpand(label, TRUE);
    char **names = g_strsplit(classes ? classes : "", " ", -1);
    for (char **name = names; *name; name++)
        if (**name) gtk_widget_add_css_class(label, *name);
    g_strfreev(names);
    gtk_widget_set_visible(label, FALSE);
    return label;
}

void szfriends_gtk_details_label_set(GtkWidget *label, const char *text) {
    gtk_label_set_text(GTK_LABEL(label), text ? text : ""); /* never markup: names come from other people */
    gtk_widget_set_visible(label, text && *text);
}

/* ---- Intents the pages build from what was typed ----------------------------------------------------------- */

szfriends_intent *szfriends_gtk_details_name_intent(const char *typed, const char *current) {
    if (!typed || g_strcmp0(typed, current) == 0) return NULL;
    return szfriends_intent_set_name(typed); /* the helper trims and checks it, and says why when it refuses */
}

szfriends_intent *szfriends_gtk_details_add_intent(const char *typed) {
    /* A pasted ID often brings a space or a line break along; the helper reads U+2011 as "-" itself. */
    char *friends_id = g_strstrip(g_strdup(typed ? typed : ""));
    szfriends_intent *intent = *friends_id ? szfriends_intent_add_by_id(friends_id) : NULL;
    g_free(friends_id);
    return intent;
}
