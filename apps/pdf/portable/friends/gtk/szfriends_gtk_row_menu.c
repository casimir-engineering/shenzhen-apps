/* A row's menu (szfriends_gtk_row.h; PROTOCOL.md list_row menu, client capability list.menu): Remove, or Cancel
 * request, opened by a right-click, a long press on a touch screen, the Menu key or Shift+F10. Delete on the focused
 * row chooses its first item (szfriends_gtk_row_key), with its confirmation. The row keeps only the items' words; what an item does is read
 * from the page's latest snapshot when it is chosen, so a menu left open never acts on an old one. */

#include "gtk/szfriends_gtk_actions.h"
#include "gtk/szfriends_gtk_row_private.h"

/* ---- The items ----------------------------------------------------------------------------------- */

static gboolean same_items(SZFriendsGtkRow *row, const SZFriendsGtkAction *menu, gsize count) {
    guint known = 0;
    for (gsize i = 0; i < count; i++) {
        if (!szfriends_gtk_action_is_known(menu[i].action) || !menu[i].label || !*menu[i].label) continue;
        if (known >= row->menu_labels->len ||
            g_strcmp0(g_ptr_array_index(row->menu_labels, known), menu[i].label) ||
            g_array_index(row->menu_index, guint, known) != i ||
            g_array_index(row->menu_destructive, gboolean, known) !=
                (menu[i].style == SZFRIENDS_GTK_STYLE_DESTRUCTIVE))
            return FALSE;
        known++;
    }
    return known == row->menu_labels->len;
}

void szfriends_gtk_row_set_menu(SZFriendsGtkRow *row, const SZFriendsGtkAction *menu, gsize count) {
    if (same_items(row, menu, count)) return;
    szfriends_gtk_row_close_menu(row); /* its words changed under it */
    g_ptr_array_set_size(row->menu_labels, 0);
    g_array_set_size(row->menu_index, 0);
    g_array_set_size(row->menu_destructive, 0);
    /* An action this view does not know is left out (PROTOCOL.md § Principles), and so is one without words. */
    for (gsize i = 0; i < count; i++) {
        if (!szfriends_gtk_action_is_known(menu[i].action) || !menu[i].label || !*menu[i].label) continue;
        guint index = (guint)i;
        gboolean destructive = menu[i].style == SZFRIENDS_GTK_STYLE_DESTRUCTIVE;
        g_ptr_array_add(row->menu_labels, g_strdup(menu[i].label));
        g_array_append_val(row->menu_index, index);
        g_array_append_val(row->menu_destructive, destructive);
    }
    /* Screen readers announce that the row has a menu, which Shift+F10 or the Menu key opens. */
    if (row->menu_labels->len)
        gtk_accessible_update_property(GTK_ACCESSIBLE(row), GTK_ACCESSIBLE_PROPERTY_HAS_POPUP, TRUE, -1);
    else gtk_accessible_reset_property(GTK_ACCESSIBLE(row), GTK_ACCESSIBLE_PROPERTY_HAS_POPUP);
}

static void choose(SZFriendsGtkRow *row, guint item) {
    if (item >= row->menu_index->len || !row->handlers.menu_chosen) return;
    row->handlers.menu_chosen(GTK_WIDGET(row), g_array_index(row->menu_index, guint, item), row->handlers_data);
}

/* ---- The menu ------------------------------------------------------------------------------------ */

static void menu_closed(GtkPopover *popover, gpointer data) {
    SZFriendsGtkRow *row = data;
    if (row->menu_popover == GTK_WIDGET(popover)) gtk_widget_grab_focus(GTK_WIDGET(row));
}

static gboolean unparent_later(gpointer data) {
    GtkWidget *popover = data;
    if (gtk_widget_get_parent(popover)) gtk_widget_unparent(popover);
    g_object_unref(popover);
    return G_SOURCE_REMOVE;
}

void szfriends_gtk_row_close_menu(SZFriendsGtkRow *row) {
    GtkWidget *popover = g_steal_pointer(&row->menu_popover);
    if (!popover) return;
    gtk_popover_popdown(GTK_POPOVER(popover));
    /* After the item's own activation has finished: a menu is closed from inside its click, too. */
    g_idle_add(unparent_later, g_object_ref(popover));
}

void szfriends_gtk_row_free_menu(SZFriendsGtkRow *row) {
    if (row->menu_popover) gtk_widget_unparent(g_steal_pointer(&row->menu_popover));
    g_clear_pointer(&row->menu_labels, g_ptr_array_unref);
    g_clear_pointer(&row->menu_index, g_array_unref);
    g_clear_pointer(&row->menu_destructive, g_array_unref);
}

/* GtkPopoverMenu draws its items itself; a destructive one gets the destructive colour, as the confirmation's button
 * does, by marking its item in the order the model lists them. */
static void mark_destructive(SZFriendsGtkRow *row, GtkWidget *widget, guint *item) {
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
        if (!g_strcmp0(gtk_widget_get_css_name(child), "modelbutton")) {
            if (*item < row->menu_destructive->len && g_array_index(row->menu_destructive, gboolean, *item))
                gtk_widget_add_css_class(child, "szfriends-menu-destructive");
            (*item)++;
            continue;
        }
        mark_destructive(row, child, item);
    }
}

gboolean szfriends_gtk_row_open_menu(GtkWidget *widget, double x, double y) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row || !row->menu_labels || !row->menu_labels->len || !row->clickable || row->dimmed) return FALSE;
    szfriends_gtk_row_close_menu(row);
    GMenu *model = g_menu_new();
    for (guint i = 0; i < row->menu_labels->len; i++) {
        GMenuItem *item = g_menu_item_new(g_ptr_array_index(row->menu_labels, i), NULL);
        g_menu_item_set_action_and_target_value(item, "row-menu.choose", g_variant_new_uint32(i));
        g_menu_append_item(model, item);
        g_object_unref(item);
    }
    GtkWidget *popover = gtk_popover_menu_new_from_model(G_MENU_MODEL(model));
    g_object_unref(model);
    gtk_widget_add_css_class(popover, "szfriends-row-menu");
    gtk_popover_set_has_arrow(GTK_POPOVER(popover), FALSE);
    gtk_widget_set_halign(popover, GTK_ALIGN_START);
    int width = gtk_widget_get_width(widget), height = gtk_widget_get_height(widget);
    GdkRectangle at = x < 0 ? (GdkRectangle){0, 0, MAX(width, 1), MAX(height, 1)}
                            : (GdkRectangle){(int)x, (int)y, 1, 1};
    gtk_popover_set_pointing_to(GTK_POPOVER(popover), &at);
    guint item = 0;
    mark_destructive(row, popover, &item);
    gtk_widget_set_parent(popover, widget);
    g_signal_connect(popover, "closed", G_CALLBACK(menu_closed), row);
    row->menu_popover = popover;
    row->menu_tenure = row->tenure;
    /* Shown once the row is on screen in a window; a row not yet in one (the suites' dropdown) keeps it unshown. */
    if (gtk_widget_get_native(widget)) gtk_popover_popup(GTK_POPOVER(popover));
    return TRUE;
}

GtkWidget *szfriends_gtk_row_get_menu(GtkWidget *widget) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    return row ? row->menu_popover : NULL;
}

static void menu_choose(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action;
    SZFriendsGtkRow *row = data;
    /* Chosen for the person the menu was opened for: someone else in the row now closes it without acting. */
    gboolean same = row->menu_tenure == row->tenure;
    szfriends_gtk_row_close_menu(row);
    if (same) choose(row, g_variant_get_uint32(parameter));
}

/* ---- Gestures and keys --------------------------------------------------------------------------- */

static void secondary_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
    (void)n_press;
    if (szfriends_gtk_row_open_menu(GTK_WIDGET(data), x, y))
        gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
}

/* A long press on a touch screen: claimed, so lifting the finger does not open the conversation as well. */
static void long_pressed(GtkGestureLongPress *gesture, double x, double y, gpointer data) {
    if (szfriends_gtk_row_open_menu(GTK_WIDGET(data), x, y))
        gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
}

gboolean szfriends_gtk_row_key(GtkWidget *widget, guint keyval, GdkModifierType state) {
    SZFriendsGtkRow *row = szfriends_gtk_row_of(widget);
    if (!row) return FALSE;
    GdkModifierType mods = state & (GDK_SHIFT_MASK | GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK);
    if (keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter || keyval == GDK_KEY_space) {
        szfriends_gtk_row_activate(widget);
        return TRUE;
    }
    if ((!mods && keyval == GDK_KEY_Menu) || (mods == GDK_SHIFT_MASK && keyval == GDK_KEY_F10))
        return szfriends_gtk_row_open_menu(widget, -1, -1);
    /* Delete, as in a file manager; Backspace stays harmless, since it is what someone typing a search presses. */
    if (!mods && (keyval == GDK_KEY_Delete || keyval == GDK_KEY_KP_Delete)) {
        if (!row->menu_labels->len || !row->clickable || row->dimmed) return FALSE;
        choose(row, 0);
        return TRUE;
    }
    return FALSE;
}

void szfriends_gtk_row_install_menu(SZFriendsGtkRow *row) {
    GtkWidget *widget = GTK_WIDGET(row);
    row->menu_labels = g_ptr_array_new_with_free_func(g_free);
    row->menu_index = g_array_new(FALSE, FALSE, sizeof(guint));
    row->menu_destructive = g_array_new(FALSE, FALSE, sizeof(gboolean));
    GSimpleActionGroup *group = g_simple_action_group_new();
    GSimpleAction *action = g_simple_action_new("choose", G_VARIANT_TYPE_UINT32);
    g_signal_connect(action, "activate", G_CALLBACK(menu_choose), row);
    g_action_map_add_action(G_ACTION_MAP(group), G_ACTION(action));
    g_object_unref(action);
    gtk_widget_insert_action_group(widget, "row-menu", G_ACTION_GROUP(group));
    g_object_unref(group);
    GtkGesture *secondary = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(secondary), GDK_BUTTON_SECONDARY);
    g_signal_connect(secondary, "pressed", G_CALLBACK(secondary_pressed), row);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(secondary));
    GtkGesture *hold = gtk_gesture_long_press_new();
    gtk_gesture_single_set_touch_only(GTK_GESTURE_SINGLE(hold), TRUE); /* a held mouse button still drags or clicks */
    g_signal_connect(hold, "pressed", G_CALLBACK(long_pressed), row);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(hold));
}
