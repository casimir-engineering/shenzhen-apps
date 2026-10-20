/* The list page around its rows: the footer (Copy copies the ASCII ID, the name edited in place, Add by ID), the
 * name field and banner of a fresh list, a banner action that asks first, search, the tabs and which view is held
 * while the page is on screen, and focus landing in the search field. */

#include "szfriends_gtk_list_probe.h"

#include <string.h>

static const char *text_of(GtkWidget *label) {
    return gtk_label_get_text(GTK_LABEL(label));
}

typedef struct {
    GtkWidget *label;
    const char *text;
} SZFGLabelWait;

static gboolean label_says(gpointer data) {
    SZFGLabelWait *wait = data;
    return !g_strcmp0(text_of(wait->label), wait->text) && gtk_widget_get_visible(wait->label);
}

/* The helper refusing a name, with its words. */
static void refuse_names(SZFGHarness *harness, const char *message) {
    char *reply = message ? g_strdup_printf("{\"type\":\"reply\",\"re\":\"0\",\"ok\":false,\"error\":{\"code\":"
                                            "\"name_invalid\",\"message\":\"%s\",\"retryable\":false,"
                                            "\"details\":{}}}", message)
                          : NULL;
    szfriends_fake_helper_set_reply(harness->fake, "set_name", reply);
    g_free(reply);
}

static void test_footer(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    szfg_list_wait_rows(list, 7);
    const SZFriendsGtkFooterParts *footer = szfriends_gtk_footer_parts(list->parts->footer);
    EXPECT(!g_strcmp0(text_of(footer->name_label), "Raph") && !g_strcmp0(text_of(footer->id_label),
           "ID cottage‑violet") && gtk_widget_get_visible(footer->note), "the name, the ID line and its note");
    EXPECT(!g_strcmp0(gtk_button_get_label(GTK_BUTTON(footer->add_button)), "Add by ID"), "Add by ID");
    EXPECT(!g_strcmp0(gtk_widget_get_tooltip_text(footer->copy_button), "Copy your ID") &&
               szfg_accessible_label_is(footer->copy_button, "Copy your ID") &&
               szfg_accessible_label_is(footer->name_button, "Change the name friends see"),
           "Copy and the name say what they do");
    g_clear_pointer(&szfg_copied, g_free);
    g_signal_emit_by_name(footer->copy_button, "clicked");
    EXPECT(!g_strcmp0(szfg_copied, "cottage-violet"), "Copy copies the ASCII ID, never the label (%s)", szfg_copied);
    EXPECT(gtk_widget_get_visible(footer->copy_label) && !g_strcmp0(text_of(footer->copy_label), "Copied"),
           "and says it did");
    EXPECT(szfg_clock_fire(1500) && !gtk_widget_get_visible(footer->copy_label), "for a moment");

    guint names = szfg_frames(harness, "set_name");
    g_signal_emit_by_name(footer->name_button, "clicked");
    EXPECT(szfriends_gtk_footer_is_editing(list->parts->footer) && gtk_widget_get_visible(footer->editor) &&
               !gtk_widget_get_visible(footer->name_button) &&
               !g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(footer->editor)), "Raph"), "the name edits in place");
    gtk_editable_set_text(GTK_EDITABLE(footer->editor), "Raph L.");
    g_signal_emit_by_name(footer->editor, "activate");
    EXPECT(szfg_wait_frames(harness, "set_name", names + 1) && !szfriends_gtk_footer_is_editing(list->parts->footer),
           "Return sends the new name");
    char *name = szfg_last_field(harness, "set_name", "name");
    EXPECT(!g_strcmp0(name, "Raph L."), "as typed (%s)", name);
    g_free(name);
    szfriends_gtk_footer_begin_edit(list->parts->footer);
    gtk_editable_set_text(GTK_EDITABLE(footer->editor), "Someone else");
    szfriends_gtk_dropdown_escape(list->dropdown);
    EXPECT(!szfriends_gtk_footer_is_editing(list->parts->footer) && szfriends_gtk_dropdown_is_open(list->dropdown),
           "Escape closes the field and nothing else");
    szfriends_gtk_footer_begin_edit(list->parts->footer);
    szfriends_gtk_footer_commit_edit(list->parts->footer);
    szfg_pump_for(100);
    EXPECT(szfg_frames(harness, "set_name") == names + 1, "neither Escape nor an unchanged name sends anything");

    refuse_names(harness, "Use 40 characters or fewer.");
    szfriends_gtk_footer_begin_edit(list->parts->footer);
    gtk_editable_set_text(GTK_EDITABLE(footer->editor), "A name far too long for anyone to read in a list");
    szfriends_gtk_footer_commit_edit(list->parts->footer);
    SZFGLabelWait wait = {footer->note, "Use 40 characters or fewer."};
    EXPECT(szfg_pump_until(label_says, &wait, 3000), "a refused name says why, where it was typed");
    refuse_names(harness, NULL);
    guint seen = list->parts->list_snapshots;
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    EXPECT(szfg_list_wait_snapshot(list, seen) && label_says(&wait), "and keeps saying it as snapshots arrive");
    szfriends_gtk_footer_begin_edit(list->parts->footer);
    EXPECT(g_str_has_prefix(text_of(footer->note), "Your ID works nearby now"), "until the person edits again");
    szfriends_gtk_footer_cancel_edit(list->parts->footer);

    g_signal_emit_by_name(footer->add_button, "clicked");
    EXPECT(szfriends_gtk_page_get_kind(szfriends_gtk_dropdown_get_top_page(list->dropdown)) ==
               SZFRIENDS_GTK_PAGE_PROFILE, "Add by ID opens the profile page");
    szfg_list_close(list);
}

static gboolean prompt_shown(gpointer data) {
    return gtk_widget_get_visible(((SZFGList *)data)->parts->prompt);
}

static GtkWidget *named(GtkWidget *root, const char *name) {
    if (!root || !g_strcmp0(gtk_widget_get_name(root), name)) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = named(child, name);
        if (found) return found;
    }
    return NULL;
}

/* The one confirmation card every page uses (szfriends_gtk_confirm), found by its buttons' names. */
static GtkWidget *overlay_button(SZFGList *list, gboolean confirm) {
    GtkWidget *card = szfriends_gtk_dropdown_get_overlay(list->dropdown);
    return named(card, confirm ? "szfriends.confirmation.confirm" : "szfriends.confirmation.cancel");
}

static void test_fresh_list(SZFGHarness *harness) {
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list-id-changed.json");
    SZFGList *list = szfg_list_open(harness);
    EXPECT(szfg_pump_until(prompt_shown, list, 3000), "until a name is chosen, the name field shows");
    const SZFriendsGtkListParts *parts = list->parts;
    EXPECT(!g_strcmp0(text_of(parts->prompt_title), "Choose the name friends see") &&
               !g_strcmp0(gtk_entry_get_placeholder_text(GTK_ENTRY(parts->prompt_entry)), "Your name") &&
               gtk_widget_get_visible(parts->prompt_note), "with its title, placeholder and note");
    EXPECT(gtk_widget_get_visible(parts->empty_title) && !g_strcmp0(text_of(parts->empty_title), "No friends yet"),
           "and the empty list says what to do");
    const SZFriendsGtkFooterParts *footer = szfriends_gtk_footer_parts(parts->footer);
    EXPECT(!g_strcmp0(text_of(footer->name_label), "Choose your name") &&
               !gtk_widget_has_css_class(footer->name_label, "szfriends-footer-name"),
           "the footer offers the name in plain weight");
    guint names = szfg_frames(harness, "set_name"), dismissals = szfg_frames(harness, "dismiss_banner");
    EXPECT(gtk_widget_get_visible(parts->prompt_save) &&
               !g_strcmp0(gtk_button_get_label(GTK_BUTTON(parts->prompt_save)), "Save") &&
               !gtk_widget_get_sensitive(parts->prompt_save), "Save beside the field, resting until a name is typed");
    gtk_editable_set_text(GTK_EDITABLE(parts->prompt_entry), "Mei");
    EXPECT(gtk_widget_get_sensitive(parts->prompt_save), "a name wakes Save");
    g_signal_emit_by_name(parts->prompt_entry, "activate");
    EXPECT(szfg_wait_frames(harness, "set_name", names + 1), "Return in the field sets the name");
    gtk_editable_set_text(GTK_EDITABLE(parts->prompt_entry), "Mei");
    g_signal_emit_by_name(parts->prompt_save, "clicked");
    EXPECT(szfg_wait_frames(harness, "set_name", names + 2), "and so does Save");
    /* Nothing but spaces: Save says what to type, and nothing reaches the helper. */
    gtk_editable_set_text(GTK_EDITABLE(parts->prompt_entry), "   ");
    EXPECT(!gtk_widget_get_sensitive(parts->prompt_save), "Save rests for spaces");
    szfriends_gtk_list_page_submit_name(list->page);
    SZFGLabelWait empty = {parts->prompt_note, "Type the name friends should see."};
    EXPECT(szfg_pump_until(label_says, &empty, 3000) && szfg_frames(harness, "set_name") == names + 2,
           "only spaces are refused before anything is sent");
    refuse_names(harness, "Use a name with letters in it.");
    gtk_editable_set_text(GTK_EDITABLE(parts->prompt_entry), "Mei, with a name the helper refuses");
    szfriends_gtk_list_page_submit_name(list->page);
    SZFGLabelWait refused = {parts->prompt_note, "Use a name with letters in it."};
    EXPECT(szfg_pump_until(label_says, &refused, 3000), "a refused name says why under the field");
    refuse_names(harness, NULL);
    guint seen = list->parts->list_snapshots;
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list-id-changed.json");
    EXPECT(szfg_list_wait_snapshot(list, seen) && label_says(&refused), "and keeps saying it as the list changes");
    gtk_editable_set_text(GTK_EDITABLE(parts->prompt_entry), "Mei Lin");
    EXPECT(g_str_has_prefix(text_of(parts->prompt_note), "Until you choose one"), "until the person types again");
    EXPECT(gtk_widget_get_visible(parts->banner) && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(parts->banner_button)),
           "OK"), "the banner shows with its OK");
    g_signal_emit_by_name(parts->banner_button, "clicked");
    EXPECT(szfg_wait_frames(harness, "dismiss_banner", dismissals + 1), "OK dismisses it");
    char *kind = szfg_last_field(harness, "dismiss_banner", "kind");
    EXPECT(!g_strcmp0(kind, "id_changed"), "by its kind (%s)", kind);
    g_free(kind);

    /* A banner action that asks first: nothing is sent until the card's own confirm. */
    szfriends_fake_helper_set_view_data(harness->fake, "list",
        "{\"query\":\"\",\"banner\":{\"kind\":\"identity_unavailable\","
        "\"text\":\"Friends can’t open your identity.\",\"action\":{\"action\":\"reset_friends\","
        "\"label\":\"Reset Friends\",\"style\":\"destructive\",\"confirm\":"
        "{\"title\":\"Reset Friends?\",\"body\":\"Everything goes.\",\"confirm_label\":\"Reset\",\"cancel_label\":"
        "\"Cancel\",\"destructive\":true}}},\"name_prompt\":null,\"rows\":[],\"empty\":null,\"footer\":{}}");
    SZFGLabelWait wait = {parts->banner_text, "Friends can’t open your identity."};
    EXPECT(szfg_pump_until(label_says, &wait, 3000), "the reset banner arrives");
    guint resets = szfg_frames(harness, "reset_friends");
    g_signal_emit_by_name(parts->banner_button, "clicked");
    EXPECT(szfriends_gtk_dropdown_get_overlay(list->dropdown) != NULL, "it asks first");
    g_signal_emit_by_name(overlay_button(list, FALSE), "clicked");
    szfg_pump_for(100);
    EXPECT(!szfriends_gtk_dropdown_get_overlay(list->dropdown) && szfg_frames(harness, "reset_friends") == resets,
           "Cancel sends nothing");
    g_signal_emit_by_name(parts->banner_button, "clicked");
    szfriends_gtk_dropdown_escape(list->dropdown);
    szfg_pump_for(100);
    EXPECT(!szfriends_gtk_dropdown_get_overlay(list->dropdown) && szfg_frames(harness, "reset_friends") == resets &&
               szfriends_gtk_dropdown_is_open(list->dropdown), "Escape takes the card away first, sending nothing");
    g_signal_emit_by_name(parts->banner_button, "clicked");
    GtkWidget *confirm = overlay_button(list, TRUE);
    EXPECT(confirm && gtk_widget_has_css_class(confirm, "destructive-action"), "the confirm is drawn destructive");
    if (confirm) g_signal_emit_by_name(confirm, "clicked");
    EXPECT(szfg_wait_frames(harness, "reset_friends", resets + 1), "the confirm sends it");
    char *confirmed = szfg_last_field(harness, "reset_friends", "confirm");
    EXPECT(!g_strcmp0(confirmed, "reset"), "with confirm \"reset\" (%s)", confirmed);
    g_free(confirmed);
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    szfg_list_close(list);
}

static guint views(SZFGHarness *harness, const char *view) {
    return szfg_fake_frames(harness, "subscribe", "view", view);
}

typedef struct {
    SZFGHarness *harness;
    const char *view;
    guint count;
} SZFGViewWait;

static gboolean subscribed(gpointer data) {
    SZFGViewWait *wait = data;
    return views(wait->harness, wait->view) >= wait->count;
}

static gboolean subscribe_wait(SZFGHarness *harness, const char *view, guint count) {
    SZFGViewWait wait = {harness, view, count};
    return szfg_pump_until(subscribed, &wait, 3000);
}

static void test_search_and_tabs(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    szfg_list_wait_rows(list, 7);
    const SZFriendsGtkListParts *parts = list->parts;
    EXPECT(!g_strcmp0(gtk_search_entry_get_placeholder_text(GTK_SEARCH_ENTRY(parts->search)), "Search names and IDs")
               && szfg_accessible_label_is(parts->search, "Search names and IDs"), "the panels' search field");
    guint filters = szfg_frames(harness, "set_filter");
    gtk_editable_set_text(GTK_EDITABLE(parts->search), "mei");
    EXPECT(szfg_wait_frames(harness, "set_filter", filters + 1) && szfg_list_wait_rows(list, 1),
           "typing filters the list as you type");
    char *query = szfg_last_field(harness, "set_filter", "query");
    EXPECT(!g_strcmp0(query, "mei"), "with what was typed (%s)", query);
    g_free(query);
    gtk_editable_set_text(GTK_EDITABLE(parts->search), "");
    EXPECT(szfg_list_wait_rows(list, 7), "and clearing it brings everyone back");

    guint nearby = views(harness, "nearby"), lists = views(harness, "list");
    guint unsubscribes = szfg_frames(harness, "unsubscribe");
    adw_toggle_group_set_active_name(ADW_TOGGLE_GROUP(parts->tabs), "nearby");
    /* The list stays held on Nearby: its name card and banner show above both tabs, and must follow the helper. */
    EXPECT(parts->showing_nearby && parts->nearby_token && parts->list_token, "Nearby: its view and the list's");
    EXPECT(subscribe_wait(harness, "nearby", nearby + 1) && szfg_frames(harness, "unsubscribe") == unsubscribes &&
               views(harness, "list") == lists,
           "it subscribes Nearby and keeps the list");
    adw_toggle_group_set_active_name(ADW_TOGGLE_GROUP(parts->tabs), "friends");
    EXPECT(!parts->showing_nearby && parts->list_token && !parts->nearby_token &&
               szfg_wait_frames(harness, "unsubscribe", unsubscribes + 1),
           "and back: Nearby's countdown stops with its tab");

    /* Only while on screen: a conversation on top lets the list go, and coming back holds it again. */
    lists = views(harness, "list");
    szfriends_gtk_dropdown_open_conversation(list->dropdown, "c_mei", NULL);
    EXPECT(!parts->list_token && !parts->nearby_token, "nothing held under a conversation");
    szfriends_gtk_dropdown_go_back(list->dropdown);
    EXPECT(parts->list_token && subscribe_wait(harness, "list", lists + 1), "the list again once it shows");
    szfriends_gtk_dropdown_close(list->dropdown);
    EXPECT(!parts->list_token, "and nothing while the dropdown is closed");
    szfriends_gtk_list_page_show_nearby(list->page, TRUE);
    EXPECT(!parts->list_token && !parts->nearby_token, "not even when the tab changes while closed");
    szfriends_gtk_dropdown_open(list->dropdown);
    EXPECT(parts->nearby_token && parts->list_token, "opening holds the tab that shows, and the list");
    szfriends_gtk_list_page_show_nearby(list->page, FALSE);
    szfriends_gtk_dropdown_close(list->dropdown);

    /* A popover with autohide off takes no focus by itself: the page puts it in the search field. */
    GtkWidget *content = szfriends_gtk_dropdown_get_content(list->dropdown);
    GtkWidget *window = szfg_probe_window(content);
    szfriends_gtk_dropdown_open(list->dropdown);
    GtkWidget *focus = gtk_root_get_focus(GTK_ROOT(window));
    EXPECT(focus && (focus == parts->search || gtk_widget_is_ancestor(focus, parts->search)),
           "opening puts the focus in the search field");
    szfriends_gtk_dropdown_close(list->dropdown);
    g_object_ref(content);
    gtk_window_set_child(GTK_WINDOW(window), NULL);
    gtk_window_destroy(GTK_WINDOW(window));
    g_object_unref(content);
    szfg_list_close(list);
}

/* A page destroyed while on screen hears it left after its widgets went, and must still let its view go without
 * touching them (an edit was open in its footer). */
static void test_destroyed_on_screen(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    szfg_list_wait_rows(list, 7);
    SZFriendsGtkPage *page = szfriends_gtk_page_new(harness->link, list->dropdown, SZFRIENDS_GTK_PAGE_LIST, NULL,
                                                    NULL);
    GtkWidget *widget = g_object_ref_sink(szfriends_gtk_page_get_widget(page));
    szfriends_gtk_page_set_presented(page, TRUE);
    const SZFriendsGtkListParts *parts = szfriends_gtk_list_page_parts(page);
    EXPECT(parts && parts->list_token, "a second list page holds the list while on screen");
    if (parts) szfriends_gtk_footer_begin_edit(parts->footer);
    guint unsubscribes = szfg_frames(harness, "unsubscribe");
    g_object_unref(widget);
    EXPECT(szfg_wait_frames(harness, "unsubscribe", unsubscribes + 1), "destroyed on screen, it lets the list go");
    szfg_list_close(list);
}

void szfg_run_list_page_probes(SZFGHarness *harness) {
    test_destroyed_on_screen(harness);
    test_footer(harness);
    test_fresh_list(harness);
    test_search_and_tabs(harness);
}
