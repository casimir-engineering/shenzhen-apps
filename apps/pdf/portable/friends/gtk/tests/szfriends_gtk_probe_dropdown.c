/* The dropdown shell offscreen: the page stack, the back arrow at the top left with its count, the centred title,
 * Escape that closes the innermost thing and never goes back, reopening where it was left, drafts kept, a click
 * elsewhere in the window closing it, and the connection line. Pages are test builders fed from the fixtures. */

#include "szfriends_gtk_probe.h"

#include <string.h>

typedef struct {
    GString *log;
    gboolean picker_open;
} SZFGPages;

static void build_page(SZFriendsGtkPage *page, gpointer data) {
    (void)data;
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_vexpand(content, TRUE);
    SZFriendsGtkPageKind kind = szfriends_gtk_page_get_kind(page);
    if (kind == SZFRIENDS_GTK_PAGE_CONVERSATION) {
        /* The real fixture's words, so the render shows the shell as the person will see it. */
        JsonObject *frame = szfg_fixture("snapshots/conversation-kenji-offer.json");
        SZFriendsGtkConversationSnapshot *snapshot =
            szfriends_gtk_conversation_snapshot_parse(json_object_get_object_member(frame, "data"));
        szfriends_gtk_page_set_title(page, snapshot->header.title, snapshot->header.subtitle);
        szfriends_gtk_page_set_back(page, &snapshot->back);
        for (gsize i = 0; i < snapshot->n_items; i++)
            if (snapshot->items[i].kind == SZFRIENDS_GTK_ITEM_MESSAGE) {
                GtkWidget *label = gtk_label_new(snapshot->items[i].text);
                gtk_label_set_wrap(GTK_LABEL(label), TRUE);
                gtk_label_set_xalign(GTK_LABEL(label), 0);
                gtk_widget_set_margin_start(label, 12);
                gtk_box_append(GTK_BOX(content), label);
            }
        szfriends_gtk_conversation_snapshot_free(snapshot);
        json_object_unref(frame);
    } else if (kind == SZFRIENDS_GTK_PAGE_DETAILS) {
        szfriends_gtk_page_set_title(page, "Kenji Sato", NULL);
    }
    szfriends_gtk_page_set_content(page, content);
}

static void page_presented(SZFriendsGtkPage *page, gboolean presented, gpointer data) {
    SZFGPages *pages = data;
    static const char *kinds[] = {"list", "conversation", "details", "profile", "settings"};
    const char *argument = szfriends_gtk_page_get_argument(page);
    g_string_append_printf(pages->log, "%c%s%s%s ", presented ? '+' : '-', kinds[szfriends_gtk_page_get_kind(page)],
                           argument ? ":" : "", argument ? argument : "");
}

static gboolean page_escape(SZFriendsGtkPage *page, gpointer data) {
    SZFGPages *pages = data;
    (void)page;
    if (!pages->picker_open) return FALSE;
    pages->picker_open = FALSE; /* a page's own picker closes first */
    return TRUE;
}

typedef struct {
    int presents, dismisses;
} SZFGShown;

static void shown_present(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)dropdown;
    ((SZFGShown *)data)->presents++;
}

static void shown_dismiss(SZFriendsGtkDropdown *dropdown, gpointer data) {
    ((SZFGShown *)data)->dismisses++;
    szfriends_gtk_dropdown_presenter_closed(dropdown);
}

static void expect_log(SZFGPages *pages, const char *expected, const char *what) {
    EXPECT(strcmp(pages->log->str, expected) == 0, "%s: pages heard \"%s\", expected \"%s\"", what, pages->log->str,
           expected);
    g_string_truncate(pages->log, 0);
}

static gboolean activated(gpointer data) {
    return szfg_fake_frames(data, "activate", NULL, NULL) > 0;
}

static GtkGesture *outside_click(GtkWidget *window) {
    GListModel *controllers = gtk_widget_observe_controllers(window);
    GtkGesture *found = NULL;
    for (guint i = 0; i < g_list_model_get_n_items(controllers) && !found; i++) {
        GtkEventController *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_GESTURE_CLICK(controller) &&
            gtk_event_controller_get_propagation_phase(controller) == GTK_PHASE_CAPTURE)
            found = GTK_GESTURE(controller);
        g_object_unref(controller);
    }
    g_object_unref(controllers);
    return found;
}

static GtkShortcut *find_shortcut(GtkWidget *widget) {
    GListModel *controllers = gtk_widget_observe_controllers(widget);
    GtkShortcut *found = NULL;
    for (guint i = 0; i < g_list_model_get_n_items(controllers) && !found; i++) {
        GtkEventController *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_SHORTCUT_CONTROLLER(controller) && g_list_model_get_n_items(G_LIST_MODEL(controller)))
            found = g_list_model_get_item(G_LIST_MODEL(controller), 0);
        g_object_unref(controller);
    }
    g_object_unref(controllers);
    return found;
}

static GtkEventController *find_key_controller(GtkWidget *widget) {
    GListModel *controllers = gtk_widget_observe_controllers(widget);
    GtkEventController *found = NULL;
    for (guint i = 0; i < g_list_model_get_n_items(controllers) && !found; i++) {
        GtkEventController *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_EVENT_CONTROLLER_KEY(controller) &&
            gtk_event_controller_get_propagation_phase(controller) == GTK_PHASE_CAPTURE)
            found = controller;
        g_object_unref(controller);
    }
    g_object_unref(controllers);
    return found;
}

static void render_shell(SZFriendsGtkDropdown *dropdown, const char *name) {
    GtkWidget *content = szfriends_gtk_dropdown_get_content(dropdown);
    GtkWidget *window = szfg_probe_window(content);
    GdkTexture *texture = szfg_render(window, 400, 300, name);
    SZFriendsGtkPage *top = szfriends_gtk_dropdown_get_top_page(dropdown);
    GtkWidget *back = szfriends_gtk_page_get_back_button(top);
    graphene_rect_t bounds;
    EXPECT(back && gtk_widget_compute_bounds(back, content, &bounds) && bounds.origin.x < 24 && bounds.origin.y < 24,
           "%s: the back arrow sits at the top left", name);
    GtkWidget *title = adw_header_bar_get_title_widget(ADW_HEADER_BAR(gtk_widget_get_ancestor(back,
                                                                                            ADW_TYPE_HEADER_BAR)));
    EXPECT(title && gtk_widget_compute_bounds(title, content, &bounds) &&
               ABS(bounds.origin.x + bounds.size.width / 2 - 200) < 12, "%s: the title is centred", name);
    g_object_unref(texture);
    g_object_ref(content);
    gtk_window_set_child(GTK_WINDOW(window), NULL);
    gtk_window_destroy(GTK_WINDOW(window));
    g_object_unref(content);
}

/* Dark needs a dropdown built in dark: unmapped windows never restyle what already exists. */
static void render_fresh_shell(SZFGHarness *harness, SZFGPages *pages) {
    szfg_set_dark(TRUE);
    GtkWidget *window = gtk_window_new();
    GtkWidget *anchor = szfriends_gtk_button_new(harness->link, GTK_WINDOW(window));
    gtk_window_set_child(GTK_WINDOW(window), anchor);
    SZFriendsGtkDropdown *dropdown = szfriends_gtk_dropdown_for_button(anchor);
    SZFGShown shown = {0};
    SZFriendsGtkPresenter presenter = {shown_present, shown_dismiss};
    szfriends_gtk_dropdown_set_presenter(dropdown, &presenter, &shown);
    szfriends_gtk_dropdown_open(dropdown);
    szfriends_gtk_dropdown_open_conversation(dropdown, "c_kenji", NULL);
    render_shell(dropdown, "dropdown-conversation-dark");
    szfriends_gtk_dropdown_close(dropdown);
    gtk_window_destroy(GTK_WINDOW(window));
    szfg_set_dark(FALSE);
    g_string_truncate(pages->log, 0);
}

static void test_shell(SZFGHarness *harness) {
    SZFGPages pages = {g_string_new(""), FALSE};
    SZFriendsGtkPageClass klass = {build_page, page_presented, page_escape, NULL};
    for (int kind = 0; kind < SZFRIENDS_GTK_PAGE_SETTINGS; kind++)
        szfriends_gtk_register_page(harness->link, (SZFriendsGtkPageKind)kind, &klass, &pages);
    GtkWidget *window = gtk_window_new();
    GtkWidget *anchor = szfriends_gtk_button_new(harness->link, GTK_WINDOW(window));
    gtk_window_set_child(GTK_WINDOW(window), anchor);
    gtk_widget_realize(window);
    SZFriendsGtkDropdown *dropdown = szfriends_gtk_dropdown_for_button(anchor);
    SZFGShown shown = {0};
    SZFriendsGtkPresenter presenter = {shown_present, shown_dismiss};
    szfriends_gtk_dropdown_set_presenter(dropdown, &presenter, &shown);
    EXPECT(szfriends_gtk_dropdown_get_depth(dropdown) == 0, "nothing of the dropdown exists before it first opens");
    szfriends_gtk_dropdown_open(dropdown);
    EXPECT(shown.presents == 1 && szfriends_gtk_dropdown_is_open(dropdown), "opens through the presenter");
    EXPECT(szfg_pump_until(activated, harness, 2000), "opening tells the helper the person opened Friends");
    expect_log(&pages, "+list ", "open");
    szfriends_gtk_dropdown_open_conversation(dropdown, "c_kenji", NULL);
    expect_log(&pages, "-list +conversation:c_kenji ", "a conversation");
    EXPECT(szfriends_gtk_dropdown_get_depth(dropdown) == 2, "list, then the conversation");
    SZFriendsGtkPage *top = szfriends_gtk_dropdown_get_top_page(dropdown);
    GtkWidget *back = szfriends_gtk_page_get_back_button(top);
    GtkWidget *badge = back ? gtk_widget_get_next_sibling(back) : NULL;
    /* The fixture's count: rows waiting elsewhere, not Kenji's own offer (PROTOCOL.md § Views, conversation). */
    EXPECT(badge && GTK_IS_LABEL(badge) && strcmp(gtk_label_get_text(GTK_LABEL(badge)), "1") == 0 &&
               gtk_widget_get_visible(badge), "the back arrow carries the waiting count");
    EXPECT(g_strcmp0(gtk_widget_get_tooltip_text(back), "Back to Friends, 1 more waiting") == 0, "and says so");
    render_shell(dropdown, "dropdown-conversation-light");
    render_fresh_shell(harness, &pages);
    szfriends_gtk_dropdown_open_details(dropdown, "c_kenji");
    expect_log(&pages, "-conversation:c_kenji +details:c_kenji ", "details");
    pages.picker_open = TRUE;
    szfriends_gtk_dropdown_escape(dropdown);
    EXPECT(szfriends_gtk_dropdown_is_open(dropdown) && !pages.picker_open, "Escape closes the page's picker first");
    szfriends_gtk_dropdown_escape(dropdown);
    EXPECT(!szfriends_gtk_dropdown_is_open(dropdown) && szfriends_gtk_dropdown_get_depth(dropdown) == 3,
           "then the dropdown, never navigating back");
    expect_log(&pages, "-details:c_kenji ", "closing");
    SZFriendsGtkDraft *draft = szfriends_gtk_dropdown_get_draft(dropdown, "c_kenji");
    g_free(draft->text);
    draft->text = g_strdup("See you at the site");
    szfriends_gtk_dropdown_open(dropdown);
    expect_log(&pages, "+details:c_kenji ", "reopening returns to the view left");
    EXPECT(szfriends_gtk_dropdown_get_draft(dropdown, "c_kenji") == draft &&
               !strcmp(draft->text, "See you at the site"),
           "drafts are kept per window");
    /* Cmd+[ goes up one level, through the shortcut on the dropdown itself. */
    GtkWidget *content = szfriends_gtk_dropdown_get_content(dropdown);
    GtkShortcut *back_shortcut = find_shortcut(content);
    EXPECT(back_shortcut != NULL, "the dropdown carries the go-back shortcut");
    if (back_shortcut) {
        char *trigger = gtk_shortcut_trigger_to_string(gtk_shortcut_get_trigger(back_shortcut));
#ifdef __APPLE__
        EXPECT(strcmp(trigger, "<Meta>bracketleft") == 0, "on Cmd+[ (%s)", trigger);
#endif
        g_free(trigger);
        gtk_shortcut_action_activate(gtk_shortcut_get_action(back_shortcut), 0, content, NULL);
        g_object_unref(back_shortcut);
    } else {
        szfriends_gtk_dropdown_go_back(dropdown);
    }
    expect_log(&pages, "-details:c_kenji +conversation:c_kenji ", "back goes up one level");
    szfriends_gtk_dropdown_open_conversation(dropdown, "c_kenji", "m_1b7e44d9");
    EXPECT(!g_strcmp0(szfriends_gtk_page_get_message_id(szfriends_gtk_dropdown_get_top_page(dropdown)), "m_1b7e44d9"),
           "the same conversation highlights the message");
    expect_log(&pages, "-conversation:c_kenji +conversation:c_kenji ", "a highlight re-presents the page");
    szfriends_gtk_dropdown_open_conversation(dropdown, "c_mei", NULL);
    EXPECT(szfriends_gtk_dropdown_get_depth(dropdown) == 2, "another conversation: the back arrow still leads home");
    expect_log(&pages, "-conversation:c_kenji +list -list +conversation:c_mei ", "switching conversations");
    szfriends_gtk_dropdown_open_profile(dropdown);
    EXPECT(szfriends_gtk_page_get_kind(szfriends_gtk_dropdown_get_top_page(dropdown)) == SZFRIENDS_GTK_PAGE_PROFILE &&
               szfriends_gtk_dropdown_get_depth(dropdown) == 2, "the profile sits right below the list");
    g_string_truncate(pages.log, 0);
    szfriends_gtk_dropdown_set_overlay(dropdown, gtk_label_new(NULL));
    /* The Escape key itself, through the capture-phase controller the popover's content carries. */
    GtkEventController *keys = find_key_controller(content);
    gboolean handled = FALSE;
    EXPECT(keys != NULL, "the dropdown listens for Escape before its pages do");
    if (keys) g_signal_emit_by_name(keys, "key-pressed", GDK_KEY_Escape, 0, 0, &handled);
    else szfriends_gtk_dropdown_escape(dropdown);
    EXPECT(handled && szfriends_gtk_dropdown_get_overlay(dropdown) == NULL && szfriends_gtk_dropdown_is_open(dropdown),
           "Escape removes a card over the pages first");
    /* A click elsewhere in the window closes it; a click on the button is the button's own toggle. */
    szfg_layout(window, 48, 48);
    GtkGesture *click = outside_click(window);
    EXPECT(click != NULL, "the window carries the dropdown's click watch");
    if (click) {
        g_signal_emit_by_name(click, "pressed", 1, 20.0, 20.0);
        EXPECT(szfriends_gtk_dropdown_is_open(dropdown), "a press on the button leaves the toggle to it");
        g_signal_emit_by_name(click, "pressed", 1, 400.0, 400.0);
        EXPECT(!szfriends_gtk_dropdown_is_open(dropdown), "a press elsewhere in the window closes it");
    }
    gtk_window_destroy(GTK_WINDOW(window));
    g_string_free(pages.log, TRUE);
}

static gboolean status_shown(gpointer data) {
    GtkWidget *content = data;
    GtkWidget *box = gtk_overlay_get_child(GTK_OVERLAY(content)), *status = gtk_widget_get_last_child(box);
    return gtk_widget_get_visible(status) && *gtk_label_get_text(GTK_LABEL(status));
}

static gboolean status_hidden(gpointer data) {
    return !status_shown(data);
}

static void test_status_line(SZFGHarness *harness) {
    GtkWidget *window = gtk_window_new();
    GtkWidget *anchor = szfriends_gtk_button_new(harness->link, GTK_WINDOW(window));
    gtk_window_set_child(GTK_WINDOW(window), anchor);
    SZFriendsGtkDropdown *dropdown = szfriends_gtk_dropdown_for_button(anchor);
    GtkWidget *content = szfriends_gtk_dropdown_get_content(dropdown);
    EXPECT(status_hidden(content), "nothing to say while connected");
    szfriends_fake_helper_drop_clients(harness->fake);
    EXPECT(szfg_pump_until(status_shown, content, 3000), "the connection line shows while the helper is away");
    EXPECT(szfg_pump_until(status_hidden, content, 5000), "and goes once it answers again");
    gtk_window_destroy(GTK_WINDOW(window));
    EXPECT(szfriends_gtk_dropdown_height(1000, 640) == 640 && szfriends_gtk_dropdown_height(400, 640) == 376 &&
               szfriends_gtk_dropdown_height(100, 640) == 280, "it fits the window, between 280 and 640");
}

void szfg_run_dropdown_probes(void) {
    SZFGHarness *harness = szfg_probe_harness("dropdown");
    test_shell(harness);
    test_status_line(harness);
    szfg_harness_free(harness);
}
