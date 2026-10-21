/* SZFriendsGtkDropdown: one window's popover, its navigation stack and its state (szfriends_gtk_dropdown.h).
 *
 * WHY autohide off: an autohide popover grabs input and closes when focus leaves the app, but the dropdown must stay
 * open while files are dragged in from Finder (brief § Interface; lead decision for friends-integration.md § 3.6.5).
 * So the shell closes it itself: Escape (a capture-phase key controller), a click on the button (GtkMenuButton
 * toggles), and a click anywhere else in the window (a capture-phase click gesture on the window). */

#include "gtk/szfriends_gtk_dropdown_private.h"

int szfriends_gtk_dropdown_height(int space_below_button, int max_height) {
    /* 24 px for the popover's arrow and a margin above the window's bottom edge; 280 keeps a short window usable
     * (header, a few rows, the composer) rather than shrinking to nothing. Same numbers as the AppKit dropdown. */
    return MAX(280, MIN(max_height, space_below_button - 24));
}

/* ---- Which page is on screen --------------------------------------------------------------------- */

static SZFriendsGtkPage *visible_page(SZFriendsGtkDropdown *dropdown) {
    if (!dropdown->nav) return NULL;
    AdwNavigationPage *page = adw_navigation_view_get_visible_page(ADW_NAVIGATION_VIEW(dropdown->nav));
    return szfriends_gtk_page_from_widget(GTK_WIDGET(page));
}

static void forget_presented(gpointer data, GObject *where_the_page_was) {
    SZFriendsGtkDropdown *dropdown = data;
    (void)where_the_page_was;
    dropdown->presented_page = NULL;
}

/* Exactly one page is presented while the dropdown is open, none while it is closed; a page that leaves the screen
 * hears so before the next one appears, so its subscriptions are released first. */
static void sync_presented(SZFriendsGtkDropdown *dropdown) {
    SZFriendsGtkPage *target = dropdown->open ? visible_page(dropdown) : NULL;
    SZFriendsGtkPage *current = dropdown->presented_page;
    if (target == current) return;
    if (current) {
        g_object_weak_unref(G_OBJECT(szfriends_gtk_page_get_widget(current)), forget_presented, dropdown);
        dropdown->presented_page = NULL;
        szfriends_gtk_page_set_presented(current, FALSE);
    }
    if (target) {
        dropdown->presented_page = target;
        g_object_weak_ref(G_OBJECT(szfriends_gtk_page_get_widget(target)), forget_presented, dropdown);
        szfriends_gtk_page_set_presented(target, TRUE);
    }
    /* What the person is looking at changed, so may the conversation notifications leave out (set_focus). */
    szfriends_gtk_focus_update(dropdown->link);
}

/* "pushed" and "replaced" carry no page; "popped" carries the page that left. */
static void stack_grew(AdwNavigationView *view, gpointer data) {
    (void)view;
    sync_presented(data);
}

static void stack_popped(AdwNavigationView *view, AdwNavigationPage *page, gpointer data) {
    (void)view, (void)page;
    sync_presented(data);
}

/* ---- The shell ----------------------------------------------------------------------------------- */

static void update_status(SZFriendsGtkLink *link, SZFriendsGtkLinkState state, gpointer data) {
    SZFriendsGtkDropdown *dropdown = data;
    (void)state;
    /* Not READY: every page keeps its last snapshot, and this one line says why nothing changes. */
    const char *text = szfriends_gtk_link_status_text(link);
    gtk_label_set_text(GTK_LABEL(dropdown->status), text ? text : "");
    gtk_widget_set_visible(dropdown->status, text && *text);
}

static gboolean key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state,
                            gpointer data) {
    (void)controller, (void)keycode, (void)state;
    if (keyval != GDK_KEY_Escape) return FALSE;
    szfriends_gtk_dropdown_escape(data);
    return TRUE; /* GtkPopover would close on Escape too, before a page could close its picker */
}

static gboolean go_back_shortcut(GtkWidget *widget, GVariant *args, gpointer data) {
    (void)widget, (void)args;
    szfriends_gtk_dropdown_go_back(data);
    return TRUE;
}

static void ensure_content(SZFriendsGtkDropdown *dropdown) {
    if (dropdown->content) return;
    const SZFriendsGtkHost *host = szfriends_gtk_link_host(dropdown->link);
    dropdown->content = g_object_ref_sink(gtk_overlay_new());
    gtk_widget_set_name(dropdown->content, "szfriends.dropdown");
    gtk_widget_add_css_class(dropdown->content, "szfriends-dropdown");
    gtk_widget_set_size_request(dropdown->content, host->dropdown_width > 0 ? host->dropdown_width : 400, -1);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    dropdown->nav = adw_navigation_view_new();
    adw_navigation_view_set_pop_on_escape(ADW_NAVIGATION_VIEW(dropdown->nav), FALSE); /* Escape closes, never back */
    adw_navigation_view_set_animate_transitions(ADW_NAVIGATION_VIEW(dropdown->nav), FALSE);
    gtk_widget_set_vexpand(dropdown->nav, TRUE);
    g_signal_connect(dropdown->nav, "pushed", G_CALLBACK(stack_grew), dropdown);
    g_signal_connect(dropdown->nav, "popped", G_CALLBACK(stack_popped), dropdown);
    g_signal_connect(dropdown->nav, "replaced", G_CALLBACK(stack_grew), dropdown);
    dropdown->status = gtk_label_new(NULL);
    gtk_widget_add_css_class(dropdown->status, "szfriends-status");
    gtk_label_set_wrap(GTK_LABEL(dropdown->status), TRUE);
    gtk_label_set_justify(GTK_LABEL(dropdown->status), GTK_JUSTIFY_CENTER);
    gtk_box_append(GTK_BOX(box), dropdown->nav);
    gtk_box_append(GTK_BOX(box), dropdown->status);
    gtk_overlay_set_child(GTK_OVERLAY(dropdown->content), box);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), dropdown);
    gtk_widget_add_controller(dropdown->content, keys);
    /* Cmd+[ on macOS, as the AppKit dropdown; GTK reads <Primary> as Control even there, so Command is spelled out.
     * Elsewhere the GNOME convention for back. */
#ifdef __APPLE__
    const char *back_keys = "<Meta>bracketleft";
#else
    const char *back_keys = "<Alt>Left";
#endif
    GtkEventController *shortcuts = gtk_shortcut_controller_new();
    gtk_shortcut_controller_add_shortcut(GTK_SHORTCUT_CONTROLLER(shortcuts),
        gtk_shortcut_new(gtk_shortcut_trigger_parse_string(back_keys),
                         gtk_callback_action_new(go_back_shortcut, dropdown, NULL)));
    gtk_widget_add_controller(dropdown->content, shortcuts);
    dropdown->state_watch = szfriends_gtk_link_add_state_watch(dropdown->link, update_status, dropdown, NULL);
    update_status(dropdown->link, szfriends_gtk_link_get_state(dropdown->link), dropdown);
    SZFriendsGtkPage *list = szfriends_gtk_page_new(dropdown->link, dropdown, SZFRIENDS_GTK_PAGE_LIST, NULL, NULL);
    adw_navigation_view_push(ADW_NAVIGATION_VIEW(dropdown->nav),
                             ADW_NAVIGATION_PAGE(szfriends_gtk_page_get_widget(list)));
}

GtkWidget *szfriends_gtk_dropdown_get_content(SZFriendsGtkDropdown *dropdown) {
    ensure_content(dropdown);
    return dropdown->content;
}

static void fit_height(SZFriendsGtkDropdown *dropdown) {
    const SZFriendsGtkHost *host = szfriends_gtk_link_host(dropdown->link);
    int max = host->dropdown_max_height > 0 ? host->dropdown_max_height : 640, space = max + 24;
    graphene_rect_t bounds;
    if (dropdown->window && gtk_widget_get_height(GTK_WIDGET(dropdown->window)) > 0 &&
        gtk_widget_compute_bounds(dropdown->anchor, GTK_WIDGET(dropdown->window), &bounds))
        space = gtk_widget_get_height(GTK_WIDGET(dropdown->window)) - (int)(bounds.origin.y + bounds.size.height);
    gtk_widget_set_size_request(dropdown->content, host->dropdown_width > 0 ? host->dropdown_width : 400,
                                szfriends_gtk_dropdown_height(space, max));
}

/* ---- The app's presenter: the menu button's popover ---------------------------------------------- */

static void popover_closed(GtkPopover *popover, gpointer data) {
    (void)popover;
    szfriends_gtk_dropdown_presenter_closed(data);
}

static void create_popup(GtkMenuButton *button, gpointer data) {
    SZFriendsGtkDropdown *dropdown = data;
    szfriends_gtk_dropdown_prepare_open(dropdown);
    if (dropdown->popover) return;
    /* Held: the menu button disposes its popover before the button's own data (this dropdown) is freed. */
    dropdown->popover = g_object_ref_sink(gtk_popover_new());
    gtk_popover_set_autohide(GTK_POPOVER(dropdown->popover), FALSE);
    gtk_popover_set_has_arrow(GTK_POPOVER(dropdown->popover), TRUE);
    gtk_widget_add_css_class(dropdown->popover, "szfriends-popover");
    gtk_popover_set_child(GTK_POPOVER(dropdown->popover), dropdown->content);
    g_signal_connect(dropdown->popover, "closed", G_CALLBACK(popover_closed), dropdown);
    gtk_menu_button_set_popover(button, dropdown->popover);
}

static void popover_present(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)data;
    gtk_menu_button_popup(dropdown->menu_button); /* runs create_popup first */
}

static void popover_dismiss(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)data;
    if (dropdown->popover) gtk_menu_button_popdown(dropdown->menu_button); /* "closed" reports it */
    else szfriends_gtk_dropdown_presenter_closed(dropdown);
}

static const SZFriendsGtkPresenter popover_presenter = {popover_present, popover_dismiss};

static void window_pressed(GtkGestureClick *gesture, int presses, double x, double y, gpointer data) {
    SZFriendsGtkDropdown *dropdown = data;
    (void)gesture, (void)presses;
    if (!dropdown->open || !dropdown->window) return;
    /* A press on the button is the button's own: GtkMenuButton toggles, and closing here first would reopen. */
    graphene_point_t point, press = GRAPHENE_POINT_INIT((float)x, (float)y);
    if (gtk_widget_compute_point(GTK_WIDGET(dropdown->window), dropdown->anchor, &press, &point) &&
        gtk_widget_contains(dropdown->anchor, point.x, point.y))
        return;
    szfriends_gtk_dropdown_close(dropdown);
}

/* ---- Lifetime ------------------------------------------------------------------------------------ */

static void draft_free(gpointer data) {
    SZFriendsGtkDraft *draft = data;
    g_free(draft->text);
    g_ptr_array_unref(draft->items);
    g_free(draft);
}

SZFriendsGtkDropdown *szfriends_gtk_dropdown_new(SZFriendsGtkLink *link, GtkWindow *window, GtkWidget *anchor,
                                                 GtkMenuButton *menu_button) {
    SZFriendsGtkDropdown *dropdown = g_new0(SZFriendsGtkDropdown, 1);
    dropdown->link = link;
    dropdown->window = window;
    dropdown->anchor = anchor;
    dropdown->menu_button = menu_button;
    dropdown->presenter = popover_presenter;
    dropdown->drafts = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, draft_free);
    dropdown->scroll = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    dropdown->watches = g_array_new(FALSE, TRUE, sizeof(SZFriendsGtkDropdownWatch));
    gtk_menu_button_set_create_popup_func(menu_button, create_popup, dropdown, NULL);
    if (window) {
        g_object_add_weak_pointer(G_OBJECT(window), (gpointer *)&dropdown->window);
        dropdown->outside_click = gtk_gesture_click_new();
        gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(dropdown->outside_click), 0);
        gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(dropdown->outside_click), GTK_PHASE_CAPTURE);
        g_signal_connect(dropdown->outside_click, "pressed", G_CALLBACK(window_pressed), dropdown);
        gtk_widget_add_controller(GTK_WIDGET(window), GTK_EVENT_CONTROLLER(dropdown->outside_click));
    }
    szfriends_gtk_focus_add_dropdown(link, dropdown);
    return dropdown;
}

void szfriends_gtk_dropdown_free(SZFriendsGtkDropdown *dropdown) {
    if (!dropdown) return;
    dropdown->open = FALSE;
    sync_presented(dropdown);
    szfriends_gtk_focus_remove_dropdown(dropdown->link, dropdown);
    if (dropdown->window) {
        gtk_widget_remove_controller(GTK_WIDGET(dropdown->window), GTK_EVENT_CONTROLLER(dropdown->outside_click));
        g_object_remove_weak_pointer(G_OBJECT(dropdown->window), (gpointer *)&dropdown->window);
    }
    if (dropdown->state_watch) szfriends_gtk_link_remove_state_watch(dropdown->link, dropdown->state_watch);
    if (dropdown->popover) g_signal_handlers_disconnect_by_data(dropdown->popover, dropdown);
    g_clear_object(&dropdown->popover);
    if (dropdown->nav) g_signal_handlers_disconnect_by_data(dropdown->nav, dropdown);
    g_clear_object(&dropdown->content);
    g_hash_table_unref(dropdown->drafts);
    g_hash_table_unref(dropdown->scroll);
    if (dropdown->send_items) g_ptr_array_unref(dropdown->send_items);
    g_free(dropdown->send_title);
    g_free(dropdown->drop_hint);
    g_array_free(dropdown->watches, TRUE);
    g_free(dropdown);
}

void szfriends_gtk_dropdown_set_presenter(SZFriendsGtkDropdown *dropdown, const SZFriendsGtkPresenter *presenter,
                                          gpointer data) {
    dropdown->presenter = presenter ? *presenter : popover_presenter;
    dropdown->presenter_data = data;
}

/* ---- Opening and closing ------------------------------------------------------------------------- */

void szfriends_gtk_dropdown_prepare_open(SZFriendsGtkDropdown *dropdown) {
    if (dropdown->open) return;
    ensure_content(dropdown);
    fit_height(dropdown);
    dropdown->open = TRUE;
    /* The person opened Friends: the helper may start Nearby now, the only time it may ask for permission. */
    szfriends_gtk_link_send(dropdown->link, szfriends_intent_activate(), NULL, NULL, NULL);
    sync_presented(dropdown);
}

void szfriends_gtk_dropdown_open(SZFriendsGtkDropdown *dropdown) {
    if (!dropdown || dropdown->open) return;
    szfriends_gtk_dropdown_prepare_open(dropdown);
    dropdown->presenter.present(dropdown, dropdown->presenter_data);
}

void szfriends_gtk_dropdown_close(SZFriendsGtkDropdown *dropdown) {
    if (!dropdown || !dropdown->open) return;
    dropdown->presenter.dismiss(dropdown, dropdown->presenter_data);
}

void szfriends_gtk_dropdown_toggle(SZFriendsGtkDropdown *dropdown) {
    if (dropdown && dropdown->open) szfriends_gtk_dropdown_close(dropdown);
    else szfriends_gtk_dropdown_open(dropdown);
}

void szfriends_gtk_dropdown_presenter_closed(SZFriendsGtkDropdown *dropdown) {
    if (!dropdown->open) return;
    dropdown->open = FALSE;
    szfriends_gtk_dropdown_set_overlay(dropdown, NULL);
    szfriends_gtk_dropdown_finish_send_picker(dropdown);
    szfriends_gtk_dropdown_set_drop_hint(dropdown, NULL);
    sync_presented(dropdown);
}

gboolean szfriends_gtk_dropdown_is_open(SZFriendsGtkDropdown *dropdown) {
    return dropdown && dropdown->open;
}

void szfriends_gtk_dropdown_escape(SZFriendsGtkDropdown *dropdown) {
    if (dropdown->overlay) {
        szfriends_gtk_dropdown_set_overlay(dropdown, NULL);
        return;
    }
    if (szfriends_gtk_page_escape(visible_page(dropdown))) return;
    if (dropdown->send_items) {
        szfriends_gtk_dropdown_finish_send_picker(dropdown);
        return;
    }
    szfriends_gtk_dropdown_close(dropdown); /* never back: with nothing open inside, Escape closes */
}

/* ---- Navigation ---------------------------------------------------------------------------------- */

static void push(SZFriendsGtkDropdown *dropdown, SZFriendsGtkPageKind kind, const char *argument, const char *message) {
    SZFriendsGtkPage *page = szfriends_gtk_page_new(dropdown->link, dropdown, kind, argument, message);
    adw_navigation_view_push(ADW_NAVIGATION_VIEW(dropdown->nav),
                             ADW_NAVIGATION_PAGE(szfriends_gtk_page_get_widget(page)));
}

void szfriends_gtk_dropdown_pop_to_list(SZFriendsGtkDropdown *dropdown) {
    ensure_content(dropdown);
    szfriends_gtk_dropdown_set_overlay(dropdown, NULL);
    AdwNavigationView *nav = ADW_NAVIGATION_VIEW(dropdown->nav);
    while (szfriends_gtk_dropdown_get_depth(dropdown) > 1 && adw_navigation_view_pop(nav))
        ;
}

void szfriends_gtk_dropdown_open_conversation(SZFriendsGtkDropdown *dropdown, const char *conversation_id,
                                              const char *message_id) {
    g_return_if_fail(conversation_id);
    ensure_content(dropdown);
    SZFriendsGtkPage *top = visible_page(dropdown);
    if (top && szfriends_gtk_page_get_kind(top) == SZFRIENDS_GTK_PAGE_CONVERSATION &&
        g_strcmp0(szfriends_gtk_page_get_argument(top), conversation_id) == 0) {
        szfriends_gtk_page_highlight(top, message_id);
        return;
    }
    szfriends_gtk_dropdown_pop_to_list(dropdown);
    push(dropdown, SZFRIENDS_GTK_PAGE_CONVERSATION, conversation_id, message_id);
}

void szfriends_gtk_dropdown_open_details(SZFriendsGtkDropdown *dropdown, const char *conversation_id) {
    g_return_if_fail(conversation_id);
    ensure_content(dropdown);
    SZFriendsGtkPage *top = visible_page(dropdown);
    if (top && szfriends_gtk_page_get_kind(top) == SZFRIENDS_GTK_PAGE_DETAILS) return;
    push(dropdown, SZFRIENDS_GTK_PAGE_DETAILS, conversation_id, NULL);
}

void szfriends_gtk_dropdown_open_profile(SZFriendsGtkDropdown *dropdown) {
    szfriends_gtk_dropdown_pop_to_list(dropdown);
    push(dropdown, SZFRIENDS_GTK_PAGE_PROFILE, NULL, NULL);
}

void szfriends_gtk_dropdown_open_link(SZFriendsGtkDropdown *dropdown, const char *payload) {
    g_return_if_fail(payload);
    szfriends_gtk_dropdown_pop_to_list(dropdown);
    push(dropdown, SZFRIENDS_GTK_PAGE_LINK, payload, NULL);
}

void szfriends_gtk_dropdown_open_join(SZFriendsGtkDropdown *dropdown) {
    szfriends_gtk_dropdown_pop_to_list(dropdown);
    push(dropdown, SZFRIENDS_GTK_PAGE_JOIN, NULL, NULL);
}

void szfriends_gtk_dropdown_go_back(SZFriendsGtkDropdown *dropdown) {
    if (!dropdown->nav) return;
    szfriends_gtk_dropdown_set_overlay(dropdown, NULL);
    adw_navigation_view_pop(ADW_NAVIGATION_VIEW(dropdown->nav));
}

SZFriendsGtkPage *szfriends_gtk_dropdown_get_top_page(SZFriendsGtkDropdown *dropdown) {
    return visible_page(dropdown);
}

guint szfriends_gtk_dropdown_get_depth(SZFriendsGtkDropdown *dropdown) {
    if (!dropdown->nav) return 0;
    GListModel *stack = adw_navigation_view_get_navigation_stack(ADW_NAVIGATION_VIEW(dropdown->nav));
    guint depth = g_list_model_get_n_items(stack);
    g_object_unref(stack);
    return depth;
}
