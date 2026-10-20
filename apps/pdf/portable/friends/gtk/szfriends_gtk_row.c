/* SZFriendsGtkRow: a person's row, one contiguous hit area and one drop target (szfriends_gtk_row.h; mirrors
 * mac/SZFriendsRowView.m). Rows are reused by position as snapshots arrive (up to ten a second), so everything is
 * created once and updated in place, and an armed pill survives a refresh that leaves its person in place. Drags,
 * drops and whose row a press belongs to are in szfriends_gtk_row_drops.c. */

#include "gtk/szfriends_gtk_avatars.h"
#include "gtk/szfriends_gtk_glyphs.h"
#include "gtk/szfriends_gtk_row_private.h"

#include <string.h>

G_DEFINE_FINAL_TYPE(SZFriendsGtkRow, szfriends_gtk_row, GTK_TYPE_WIDGET)

SZFriendsGtkRow *szfriends_gtk_row_of(GtkWidget *widget) {
    return widget && SZFRIENDS_GTK_IS_ROW(widget) ? SZFRIENDS_GTK_ROW(widget) : NULL;
}

/* ---- Showing the look ---------------------------------------------------------------------------- */

static void set_class(GtkWidget *widget, const char *name, gboolean on) {
    if (on) gtk_widget_add_css_class(widget, name);
    else gtk_widget_remove_css_class(widget, name);
}

void szfriends_gtk_row_refresh(SZFriendsGtkRow *row) {
    row->facts.drop_label = row->drop_label;
    row->facts.drop_refusal = row->drop_refusal;
    row->facts.refusal_above = row->refusal_above;
    /* The words for what is over the row: a folder's, or a link's or special file's (drop_not_a_file). */
    SZFriendsGtkRowLook look = szfriends_gtk_row_look_for(&row->facts, row->drop, row->dimmed, row->hovered,
                                                          szfriends_gtk_drop_refusal(row->link, row->verdict));
    row->look = look;
    GtkWidget *widget = GTK_WIDGET(row);
    /* Opacity, not visibility, so the avatar never moves when the bar or the dot comes and goes. */
    gtk_widget_set_opacity(row->bar, look.waiting_bar ? 1 : 0);
    gtk_widget_set_opacity(row->dot, look.unread_dot ? 1 : 0);
    gtk_widget_set_visible(row->check, look.id_check);
    set_class(widget, "muted", look.muted);
    set_class(widget, "dimmed", row->dimmed);
    set_class(widget, "clickable", row->clickable && !row->dimmed);
    set_class(widget, "drop-accept", row->drop == SZFRIENDS_GTK_ROW_DROP_ACCEPT);
    set_class(widget, "drop-refuse", row->drop == SZFRIENDS_GTK_ROW_DROP_REFUSE && row->drop_label);
    set_class(row->subtitle, "waiting", row->facts.waiting);
    gtk_widget_set_visible(row->time_box, look.right == SZFRIENDS_GTK_ROW_RIGHT_TIME);
    gtk_widget_set_visible(row->pill, look.waiting_pill);
    /* The route line keeps its height without an icon, so the time stays on the title's line in every row. */
    gtk_widget_set_visible(row->route, !look.waiting_pill);
    gtk_widget_set_opacity(row->route, look.route_icon ? 1 : 0);
    gtk_widget_set_tooltip_text(row->route, look.route_icon ? row->route_label : NULL);
    gtk_widget_set_visible(row->actions, look.right == SZFRIENDS_GTK_ROW_RIGHT_ACTIONS);
    if (row->accessory) gtk_widget_set_visible(row->accessory, look.right == SZFRIENDS_GTK_ROW_RIGHT_ACCESSORY);
    gtk_widget_set_visible(row->status, look.right == SZFRIENDS_GTK_ROW_RIGHT_STATUS);
    gtk_widget_set_visible(row->drop_pill, look.right == SZFRIENDS_GTK_ROW_RIGHT_PILL);
    gtk_label_set_text(GTK_LABEL(row->drop_pill), look.pill ? look.pill : "");
    /* A refusal can be a sentence ("Links and special files can't be sent. Drop the original file instead."): it
     * wraps to two lines 30 characters wide, which leaves the name its room, rather than one line cut short of the
     * reason. Anything shorter ("Send to Mei") stays on one line at its own width. */
    gboolean sentence = look.pill && g_utf8_strlen(look.pill, -1) > 30;
    gtk_label_set_wrap(GTK_LABEL(row->drop_pill), sentence);
    gtk_label_set_width_chars(GTK_LABEL(row->drop_pill), sentence ? 30 : -1);
    gtk_label_set_max_width_chars(GTK_LABEL(row->drop_pill), sentence ? 30 : -1);
    set_class(row->drop_pill, "warning", look.pill_warning);
    szfriends_gtk_glyph_set_kind(row->route, szfriends_gtk_route_glyph(row->facts.route, row->facts.route_method));
    set_class(row->route, "local", row->facts.route == SZFRIENDS_GTK_ROUTE_LOCAL);
    set_class(row->route, "online", row->facts.route == SZFRIENDS_GTK_ROUTE_ONLINE);
}

static void replace(char **slot, const char *value) {
    char *copy = g_strdup(value);
    g_free(*slot);
    *slot = copy;
}

static void set_name(SZFriendsGtkRow *row, const char *accessibility_label, const char *title) {
    const char *name = accessibility_label && *accessibility_label ? accessibility_label : title;
    gtk_accessible_update_property(GTK_ACCESSIBLE(row), GTK_ACCESSIBLE_PROPERTY_LABEL, name ? name : "", -1);
}

static void row_action(GtkWidget *actions, SZFriendsGtkActionKind action, gpointer data) {
    (void)actions;
    SZFriendsGtkRow *row = data;
    if (row->handlers.action) row->handlers.action(GTK_WIDGET(row), action, row->handlers_data);
}

/* Someone else now holds the row: whatever a press, a drag or an armed pill began belongs to the one before. */
static void take_person(SZFriendsGtkRow *row, const char *conversation_id, const char *nearby_id) {
    if (!g_strcmp0(row->conversation_id, conversation_id) && !g_strcmp0(row->nearby_id, nearby_id)) return;
    row->tenure++;
    /* The old person's buttons go, not only their pill: two requests can carry the same words, and a press on a
     * kept button would answer for whoever took the row. A destroyed button never completes a click. */
    szfriends_gtk_row_actions_apply(row->actions, NULL, 0);
    szfriends_gtk_row_close_menu(row);
    replace(&row->conversation_id, conversation_id);
    replace(&row->nearby_id, nearby_id);
}

void szfriends_gtk_row_set_list_row(GtkWidget *widget, const SZFriendsGtkListRow *list_row) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row || !list_row) return;
    take_person(row, list_row->conversation_id, NULL);
    replace(&row->drop_label, list_row->drop_label);
    replace(&row->drop_refusal, list_row->drop_refusal);
    row->facts = szfriends_gtk_row_facts(list_row);
    row->clickable = row->conversation_id && *row->conversation_id;
    gtk_widget_set_size_request(row->lead, 22, -1);
    gtk_widget_set_visible(row->bar, TRUE);
    gtk_widget_set_visible(row->dot, TRUE);
    szfriends_gtk_avatar_set(row->avatar, &list_row->avatar);
    gtk_label_set_text(GTK_LABEL(row->title), list_row->title);
    gtk_label_set_text(GTK_LABEL(row->subtitle), list_row->subtitle);
    gtk_label_set_text(GTK_LABEL(row->time), list_row->time_label);
    gtk_label_set_text(GTK_LABEL(row->pill), list_row->waiting ? list_row->waiting->label : "");
    replace(&row->route_label, list_row->route.label);
    gtk_widget_set_tooltip_text(row->check, list_row->id_confirmed ? list_row->id_confirmed_label : NULL);
    szfriends_gtk_row_actions_apply(row->actions, list_row->actions, list_row->n_actions);
    szfriends_gtk_row_actions_set_inactive(row->actions, row->dimmed);
    szfriends_gtk_row_set_menu(row, list_row->menu, list_row->n_menu);
    g_clear_pointer(&row->accessory, gtk_widget_unparent);
    gtk_widget_set_focusable(widget, row->clickable);
    set_name(row, list_row->accessibility_label, list_row->title);
    row->drop = szfriends_gtk_row_drop_now(row); /* a drag that began over someone else promises nothing here */
    szfriends_gtk_row_refresh(row);
}

static void accessory_clicked(GtkButton *button, gpointer data) {
    (void)button;
    SZFriendsGtkRow *row = data;
    if (row->handlers.accessory) row->handlers.accessory(GTK_WIDGET(row), row->handlers_data);
}

static const char *button_style_class(SZFriendsGtkActionStyle style) {
    return style == SZFRIENDS_GTK_STYLE_PRIMARY ? "suggested-action"
           : style == SZFRIENDS_GTK_STYLE_DESTRUCTIVE ? "destructive-action" : NULL;
}

void szfriends_gtk_row_set_nearby_person(GtkWidget *widget, const SZFriendsGtkNearbyPerson *person) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row || !person) return;
    take_person(row, person->conversation_id, person->nearby_id);
    replace(&row->drop_label, NULL);
    replace(&row->drop_refusal, NULL);
    memset(&row->facts, 0, sizeof row->facts);
    /* No marker column in Nearby: the avatar starts 8 px in, as AppKit draws it. */
    gtk_widget_set_size_request(row->lead, 8, -1);
    gtk_widget_set_visible(row->bar, FALSE);
    gtk_widget_set_visible(row->dot, FALSE);
    szfriends_gtk_avatar_set(row->avatar, &person->avatar);
    gtk_label_set_text(GTK_LABEL(row->title), person->title);
    gtk_label_set_text(GTK_LABEL(row->subtitle), person->subtitle);
    gtk_label_set_text(GTK_LABEL(row->status), person->status_label ? person->status_label : "");
    row->facts.has_status = person->status_label && *person->status_label;
    szfriends_gtk_row_actions_apply(row->actions, NULL, 0);
    szfriends_gtk_row_set_menu(row, NULL, 0);
    g_clear_pointer(&row->accessory, gtk_widget_unparent);
    const SZFriendsGtkAction *action = person->action;
    /* Only the Request this view knows how to send; any other action is hidden (PROTOCOL.md § Principles). */
    if (action && action->action == SZFRIENDS_GTK_ACTION_SEND_REQUEST && person->nearby_id) {
        row->accessory = gtk_button_new_with_label(action->label);
        gtk_widget_set_valign(row->accessory, GTK_ALIGN_CENTER);
        gtk_widget_set_margin_start(row->accessory, 10);
        gtk_widget_add_css_class(row->accessory, "szfriends-row-accessory");
        if (button_style_class(action->style)) gtk_widget_add_css_class(row->accessory,
                                                                        button_style_class(action->style));
        g_signal_connect(row->accessory, "clicked", G_CALLBACK(accessory_clicked), row);
        gtk_widget_insert_before(row->accessory, widget, row->status);
        row->facts.has_accessory = TRUE;
    }
    /* A stranger with no conversation yet is not clickable; only their Request is. */
    row->clickable = row->conversation_id && *row->conversation_id;
    gtk_widget_set_focusable(widget, row->clickable);
    gtk_accessible_update_state(GTK_ACCESSIBLE(row), GTK_ACCESSIBLE_STATE_DISABLED, !row->clickable, -1);
    set_name(row, person->accessibility_label, person->title);
    szfriends_gtk_row_refresh(row);
}

/* ---- Clicks, keys and the pointer ---------------------------------------------------------------- */

void szfriends_gtk_row_activate(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (row && row->clickable && row->handlers.activated) row->handlers.activated(widget, row->handlers_data);
}

static gboolean key_pressed(GtkEventControllerKey *keys, guint keyval, guint keycode, GdkModifierType state,
                            gpointer data) {
    (void)keys, (void)keycode;
    return szfriends_gtk_row_key(data, keyval, state); /* szfriends_gtk_row_menu.c */
}

static void pointer_entered(GtkEventControllerMotion *motion, double x, double y, gpointer data) {
    (void)motion, (void)x, (void)y;
    SZFriendsGtkRow *row = data;
    row->hovered = TRUE;
    if (row->dimmed) szfriends_gtk_row_refresh(row);
}

void szfriends_gtk_row_pointer_left(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row) return;
    row->hovered = FALSE;
    szfriends_gtk_row_actions_disarm(row->actions);
    szfriends_gtk_row_refresh(row);
}

static void pointer_left(GtkEventControllerMotion *motion, gpointer data) {
    (void)motion;
    szfriends_gtk_row_pointer_left(data);
}

/* ---- Construction -------------------------------------------------------------------------------- */

static GtkWidget *label(const char *css_class, float xalign) {
    GtkWidget *widget = gtk_label_new(NULL);
    gtk_label_set_ellipsize(GTK_LABEL(widget), PANGO_ELLIPSIZE_END);
    gtk_label_set_single_line_mode(GTK_LABEL(widget), TRUE);
    gtk_label_set_xalign(GTK_LABEL(widget), xalign);
    gtk_widget_add_css_class(widget, css_class);
    return widget;
}

static void build(SZFriendsGtkRow *row) {
    GtkWidget *widget = GTK_WIDGET(row);
    row->lead = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    row->bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(row->bar, "szfriends-row-bar");
    gtk_widget_set_margin_start(row->bar, 1);
    gtk_widget_set_margin_top(row->bar, 9);
    gtk_widget_set_margin_bottom(row->bar, 9);
    row->dot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(row->dot, "szfriends-row-dot");
    gtk_widget_set_valign(row->dot, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_start(row->dot, 4);
    gtk_box_append(GTK_BOX(row->lead), row->bar);
    gtk_box_append(GTK_BOX(row->lead), row->dot);
    row->avatar = szfriends_gtk_avatar_new(row->link, 34);
    gtk_widget_set_valign(row->avatar, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_end(row->avatar, 10);
    GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
    gtk_widget_set_hexpand(text, TRUE);
    gtk_widget_set_valign(text, GTK_ALIGN_CENTER);
    GtkWidget *title_line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 3);
    row->title = label("szfriends-row-title", 0);
    row->check = szfriends_gtk_glyph_new(SZFRIENDS_GTK_GLYPH_CHECK, 11);
    gtk_widget_add_css_class(row->check, "szfriends-id-check");
    gtk_widget_set_can_target(row->check, TRUE); /* for its tooltip; a click still reaches the row */
    gtk_box_append(GTK_BOX(title_line), row->title);
    gtk_box_append(GTK_BOX(title_line), row->check);
    row->subtitle = label("szfriends-row-subtitle", 0);
    gtk_box_append(GTK_BOX(text), title_line);
    gtk_box_append(GTK_BOX(text), row->subtitle);
    row->time_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_widget_set_valign(row->time_box, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_start(row->time_box, 10);
    row->time = label("szfriends-row-time", 1);
    row->pill = label("szfriends-pill", 0.5f);
    gtk_widget_set_halign(row->pill, GTK_ALIGN_END);
    row->route = szfriends_gtk_glyph_new(SZFRIENDS_GTK_GLYPH_ROUTE_OFFLINE, 13);
    gtk_widget_add_css_class(row->route, "szfriends-route");
    gtk_widget_set_halign(row->route, GTK_ALIGN_END);
    gtk_widget_set_can_target(row->route, TRUE);
    gtk_box_append(GTK_BOX(row->time_box), row->time);
    gtk_box_append(GTK_BOX(row->time_box), row->pill);
    gtk_box_append(GTK_BOX(row->time_box), row->route);
    row->actions = szfriends_gtk_row_actions_new();
    gtk_widget_set_margin_start(row->actions, 10);
    szfriends_gtk_row_actions_set_handler(row->actions, row_action, row);
    row->status = label("szfriends-row-status", 1);
    gtk_widget_set_margin_start(row->status, 10);
    row->drop_pill = label("szfriends-pill", 0.5f);
    gtk_widget_add_css_class(row->drop_pill, "drop");
    gtk_widget_set_valign(row->drop_pill, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_start(row->drop_pill, 10);
    /* Two lines at most when it wraps (szfriends_gtk_row_refresh decides), centred like the one-line pill. */
    gtk_label_set_single_line_mode(GTK_LABEL(row->drop_pill), FALSE);
    gtk_label_set_wrap_mode(GTK_LABEL(row->drop_pill), PANGO_WRAP_WORD);
    gtk_label_set_lines(GTK_LABEL(row->drop_pill), 2);
    gtk_label_set_justify(GTK_LABEL(row->drop_pill), GTK_JUSTIFY_CENTER);
    /* Everything but the drag pill fades with a faded row; the pill is the reason, so it keeps full strength. */
    GtkWidget *fading[] = {row->lead, row->avatar, text, row->time_box, row->actions, row->status};
    for (gsize i = 0; i < G_N_ELEMENTS(fading); i++) gtk_widget_add_css_class(fading[i], "szfriends-row-fade");
    GtkWidget *children[] = {row->lead, row->avatar, text, row->time_box, row->actions, row->status, row->drop_pill};
    for (gsize i = 0; i < G_N_ELEMENTS(children); i++) gtk_widget_set_parent(children[i], widget);
}

static void row_dispose(GObject *object) {
    SZFriendsGtkRow *row = SZFRIENDS_GTK_ROW(object);
    szfriends_gtk_row_free_menu(row);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(GTK_WIDGET(row)))) gtk_widget_unparent(child);
    row->accessory = NULL;
    G_OBJECT_CLASS(szfriends_gtk_row_parent_class)->dispose(object);
}

static void row_finalize(GObject *object) {
    SZFriendsGtkRow *row = SZFRIENDS_GTK_ROW(object);
    g_free(row->conversation_id);
    g_free(row->nearby_id);
    g_free(row->drop_label);
    g_free(row->drop_refusal);
    g_free(row->route_label);
    G_OBJECT_CLASS(szfriends_gtk_row_parent_class)->finalize(object);
}

/* The box lays out the row's own children; an open menu is placed again whenever the row moves. */
static void row_size_allocate(GtkWidget *widget, int width, int height, int baseline) {
    GTK_WIDGET_CLASS(szfriends_gtk_row_parent_class)->size_allocate(widget, width, height, baseline);
    SZFriendsGtkRow *row = SZFRIENDS_GTK_ROW(widget);
    if (row->menu_popover && gtk_widget_get_visible(row->menu_popover))
        gtk_popover_present(GTK_POPOVER(row->menu_popover));
}

static void szfriends_gtk_row_class_init(SZFriendsGtkRowClass *klass) {
    G_OBJECT_CLASS(klass)->dispose = row_dispose;
    GTK_WIDGET_CLASS(klass)->size_allocate = row_size_allocate;
    G_OBJECT_CLASS(klass)->finalize = row_finalize;
    gtk_widget_class_set_css_name(GTK_WIDGET_CLASS(klass), "szfriends-row");
    gtk_widget_class_set_layout_manager_type(GTK_WIDGET_CLASS(klass), GTK_TYPE_BOX_LAYOUT);
    gtk_widget_class_set_accessible_role(GTK_WIDGET_CLASS(klass), GTK_ACCESSIBLE_ROLE_BUTTON);
}

static void szfriends_gtk_row_init(SZFriendsGtkRow *row) {
    (void)row;
}

GtkWidget *szfriends_gtk_row_new(SZFriendsGtkLink *link) {
    SZFriendsGtkRow *row = g_object_new(SZFRIENDS_GTK_TYPE_ROW, NULL);
    row->link = link;
    GtkWidget *widget = GTK_WIDGET(row);
    gtk_widget_set_size_request(widget, -1, 50);
    build(row);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), row);
    gtk_widget_add_controller(widget, keys);
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "enter", G_CALLBACK(pointer_entered), row);
    g_signal_connect(motion, "leave", G_CALLBACK(pointer_left), row);
    gtk_widget_add_controller(widget, motion);
    szfriends_gtk_row_install_targets(row);
    szfriends_gtk_row_install_menu(row);
    szfriends_gtk_row_refresh(row);
    return widget;
}

void szfriends_gtk_row_set_handlers(GtkWidget *widget, const SZFriendsGtkRowHandlers *handlers, gpointer data) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row) return;
    if (handlers) row->handlers = *handlers;
    else memset(&row->handlers, 0, sizeof row->handlers);
    row->handlers_data = data;
}

void szfriends_gtk_row_set_dimmed(GtkWidget *widget, gboolean dimmed) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row || row->dimmed == dimmed) return;
    row->dimmed = dimmed;
    if (dimmed) szfriends_gtk_row_close_menu(row);
    /* Faded rows take no answer either; their buttons fade with them. */
    szfriends_gtk_row_actions_set_inactive(row->actions, dimmed);
    szfriends_gtk_row_refresh(row);
}

void szfriends_gtk_row_set_refusal_above(GtkWidget *widget, gboolean refusal_above) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row || row->refusal_above == refusal_above) return;
    row->refusal_above = refusal_above;
    szfriends_gtk_row_refresh(row);
}

const char *szfriends_gtk_row_get_conversation_id(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    return row && row->conversation_id && *row->conversation_id ? row->conversation_id : NULL;
}

const char *szfriends_gtk_row_get_nearby_id(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    return row && row->nearby_id && *row->nearby_id ? row->nearby_id : NULL;
}

const char *szfriends_gtk_row_get_drop_label(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    return row ? row->drop_label : NULL;
}

GtkWidget *szfriends_gtk_row_get_actions(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    return row && row->facts.has_actions ? row->actions : NULL;
}

GtkWidget *szfriends_gtk_row_get_accessory(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    return row ? row->accessory : NULL;
}

GtkWidget *szfriends_gtk_row_get_part(GtkWidget *widget, SZFriendsGtkRowPart part) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row) return NULL;
    GtkWidget *parts[] = {row->title, row->subtitle, row->time, row->pill, row->route, row->check, row->status,
                          row->drop_pill};
    return (gsize)part < G_N_ELEMENTS(parts) ? parts[part] : NULL;
}

SZFriendsGtkRowLook szfriends_gtk_row_get_look(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    SZFriendsGtkRowLook none = {0};
    return row ? row->look : none;
}
