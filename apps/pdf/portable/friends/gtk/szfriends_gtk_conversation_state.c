/* The conversation's shared state, its popovers and its stylesheet (szfriends_gtk_conversation.h).
 *
 * Rows, buttons and replies hold the state by reference, and its `page` goes NULL when the page goes, so a reply or a
 * preview arriving later changes nothing. At most one popover (the link menu or a mention card) is open per page; it
 * goes with the widget it points at. */

#include "gtk/szfriends_gtk_conversation.h"

#include <string.h>

SZFriendsGtkConversation *szfriends_gtk_conversation_new(SZFriendsGtkPage *page) {
    SZFriendsGtkConversation *conversation = g_rc_box_new0(SZFriendsGtkConversation);
    conversation->page = page;
    conversation->link = szfriends_gtk_page_get_link(page);
    conversation->dropdown = szfriends_gtk_page_get_dropdown(page);
    conversation->conversation_id = g_strdup(szfriends_gtk_page_get_argument(page));
    conversation->expanded = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    conversation->armed = g_ptr_array_new();
    conversation->cancellable = g_cancellable_new();
    /* Previews load only from the helper's own cache in this state directory (szfriends_gtk_thumbnail_load). */
    char state[4096];
    if (szfriends_default_state_dir(state, sizeof state) == SZFRIENDS_OK) conversation->state_dir = g_strdup(state);
    return conversation;
}

static void conversation_release(gpointer data) {
    SZFriendsGtkConversation *conversation = data;
    g_free(conversation->conversation_id);
    g_free(conversation->state_dir);
    g_hash_table_unref(conversation->expanded);
    if (conversation->thumbnails) g_hash_table_unref(conversation->thumbnails);
    g_ptr_array_unref(conversation->armed);
    g_object_unref(conversation->cancellable);
}

SZFriendsGtkConversation *szfriends_gtk_conversation_ref(SZFriendsGtkConversation *conversation) {
    return g_rc_box_acquire(conversation);
}

void szfriends_gtk_conversation_unref(SZFriendsGtkConversation *conversation) {
    g_rc_box_release_full(conversation, conversation_release);
}

void szfriends_gtk_conversation_detach(SZFriendsGtkConversation *conversation) {
    szfriends_gtk_conversation_close_popover(conversation);
    conversation->page = NULL;
    conversation->content = conversation->color_probe = conversation->warning_probe = NULL;
    g_cancellable_cancel(conversation->cancellable);
    g_clear_pointer(&conversation->thumbnails, g_hash_table_unref);
    g_ptr_array_set_size(conversation->armed, 0);
}

gboolean szfriends_gtk_conversation_helper_cancels(SZFriendsGtkConversation *conversation) {
    return szfriends_gtk_link_helper_has_capability(conversation->link, "messages.cancel");
}

/* ---- Colours drawn as Pango attributes ----------------------------------------------------------------- */

/* Read from a hidden label each time rather than kept: GTK computes a style it has not computed yet when asked, so
 * this is the current appearance's colour, and a host's appearance_css colours mentions and marks too. */
static gboolean probe_color(GtkWidget *probe, GdkRGBA *rgba) {
    if (!probe || !gtk_widget_get_root(probe)) return FALSE;
    gtk_widget_get_color(probe, rgba);
    return TRUE;
}

gboolean szfriends_gtk_conversation_accent(SZFriendsGtkConversation *conversation, GdkRGBA *rgba) {
    return probe_color(conversation->color_probe, rgba);
}

gboolean szfriends_gtk_conversation_warning(SZFriendsGtkConversation *conversation, GdkRGBA *rgba) {
    return probe_color(conversation->warning_probe, rgba);
}

/* ---- Opening links ------------------------------------------------------------------------------------ */

static SZFriendsGtkUriOpener uri_opener;
static gpointer uri_opener_data;

void szfriends_gtk_conversation_set_uri_opener(SZFriendsGtkUriOpener opener, gpointer data) {
    uri_opener = opener, uri_opener_data = data;
}

void szfriends_gtk_conversation_open_uri(SZFriendsGtkConversation *conversation, const char *uri) {
    if (!szfriends_gtk_link_may_open(uri)) return; /* the web and email only, whatever asked */
    if (uri_opener) {
        uri_opener(uri, uri_opener_data);
        return;
    }
    GtkUriLauncher *launcher = gtk_uri_launcher_new(uri);
    GtkWindow *window = conversation->dropdown ? szfriends_gtk_dropdown_get_window(conversation->dropdown) : NULL;
    gtk_uri_launcher_launch(launcher, window, NULL, NULL, NULL);
    g_object_unref(launcher);
}

/* ---- Popovers ----------------------------------------------------------------------------------------- */

/* Tests record instead: popping one up would put a surface on the screen. */
static void (*popup_func)(GtkPopover *popover) = gtk_popover_popup;

void szfriends_gtk_conversation_set_popup(void (*popup)(GtkPopover *popover)) {
    popup_func = popup ? popup : gtk_popover_popup;
}

static void owner_destroyed(GtkWidget *owner, gpointer data) {
    SZFriendsGtkConversation *conversation = data;
    if (conversation->popover_owner == owner) szfriends_gtk_conversation_close_popover(conversation);
}

static gboolean unparent_later(gpointer data) {
    GtkWidget *popover = data;
    if (gtk_widget_get_parent(popover) && !gtk_widget_get_visible(popover)) gtk_widget_unparent(popover);
    g_object_unref(popover);
    return G_SOURCE_REMOVE;
}

static void popover_closed(GtkPopover *popover, gpointer data) {
    SZFriendsGtkConversation *conversation = data;
    if (conversation->popover != GTK_WIDGET(popover)) return;
    g_signal_handlers_disconnect_by_data(conversation->popover_owner, conversation);
    g_signal_handlers_disconnect_by_data(popover, conversation);
    conversation->popover = conversation->popover_owner = NULL;
    g_idle_add(unparent_later, g_object_ref(popover)); /* not while it is still closing */
}

gboolean szfriends_gtk_conversation_close_popover(SZFriendsGtkConversation *conversation) {
    GtkWidget *popover = conversation->popover;
    if (!popover) return FALSE;
    g_signal_handlers_disconnect_by_data(popover, conversation);
    g_signal_handlers_disconnect_by_data(conversation->popover_owner, conversation);
    conversation->popover = conversation->popover_owner = NULL;
    gtk_popover_popdown(GTK_POPOVER(popover));
    gtk_widget_unparent(popover);
    return TRUE;
}

void szfriends_gtk_conversation_show_popover(SZFriendsGtkConversation *conversation, GtkWidget *owner,
                                             GtkWidget *popover, const GdkRectangle *rect) {
    szfriends_gtk_conversation_close_popover(conversation);
    gtk_widget_set_parent(popover, owner);
    gtk_popover_set_pointing_to(GTK_POPOVER(popover), rect);
    gtk_popover_set_position(GTK_POPOVER(popover), GTK_POS_BOTTOM);
    conversation->popover = popover;
    conversation->popover_owner = owner;
    g_signal_connect(owner, "destroy", G_CALLBACK(owner_destroyed), conversation);
    g_signal_connect(popover, "closed", G_CALLBACK(popover_closed), conversation);
    popup_func(GTK_POPOVER(popover));
}

/* ---- The stylesheet --------------------------------------------------------------------------------- */

/* Colours are the views' tokens only (szfriends_gtk.css), so a host's appearance_css restyles the conversation too,
 * and dark mode follows the tokens without rules of its own. libadwaita draws every label inside a button bold
 * (`button { font-weight: bold }`, inherited): the rules marked "weight" give such labels their own weight back, so a
 * picker row's detail, the header's route line and an attachment chip read as regular text, as in AppKit. */
static const char stylesheet[] =
    ".szfriends-accent-probe { color: @szfriends_accent; }\n"
    ".szfriends-warning-probe { color: @szfriends_warning; }\n"
    ".szfriends-secondary { color: @szfriends_secondary_text; font-size: 0.92em; }\n"
    ".szfriends-caption { color: @szfriends_secondary_text; font-size: 0.85em; }\n"
    ".szfriends-success { color: @szfriends_success; font-size: 0.92em; }\n"
    ".szfriends-failure { color: @szfriends_destructive; font-size: 0.92em; }\n"
    ".szfriends-history { background: none; }\n"
    ".szfriends-history-row { padding: 5px 14px; }\n"
    ".szfriends-day { color: @szfriends_secondary_text; font-size: 0.85em; font-weight: 600; }\n"
    ".szfriends-event { color: @szfriends_secondary_text; font-size: 0.92em; padding: 0 20px; }\n"
    ".szfriends-bubble { border-radius: 12px; padding: 8px 11px; border: 1px solid transparent; }\n"
    ".szfriends-bubble.szfriends-incoming { background-color: @szfriends_incoming_bubble; }\n"
    ".szfriends-bubble.szfriends-outgoing { background-color: @szfriends_outgoing_bubble; }\n"
    ".szfriends-bubble.szfriends-highlighted, .szfriends-transfer-card.szfriends-highlighted"
    " { border-color: @szfriends_accent; }\n"
    ".szfriends-time-line { color: @szfriends_secondary_text; font-size: 0.85em; padding: 0 4px; }\n"
    ".szfriends-transfer-card { background-color: @szfriends_field_background; border: 1px solid"
    " @szfriends_separator; border-radius: 10px; padding: 10px 12px; }\n"
    ".szfriends-file-name { font-weight: 600; }\n"
    ".szfriends-preview { border-radius: 4px; background-color: @szfriends_separator; }\n"
    ".szfriends-preview.szfriends-preview-loaded { background-color: transparent; }\n"
    ".szfriends-file-glyph { min-width: 24px; min-height: 30px; padding: 0 2px 3px; border-radius: 4px;"
    " background-color: #e9e9ee; color: #3a3a46; font-size: 8px; font-weight: 700; }\n"
    "button.szfriends-link { padding: 0 3px; min-height: 0; min-width: 0; color: @szfriends_accent;"
    " font-size: 0.92em; font-weight: normal; }\n"
    "button.szfriends-link.szfriends-destructive { color: @szfriends_destructive; }\n"
    "button.szfriends-armed, button.szfriends-armed.szfriends-link { color: @szfriends_destructive;"
    " background-color: alpha(@szfriends_destructive, 0.12); border-radius: 999px; padding: 0 10px;"
    " box-shadow: inset 0 0 0 1px alpha(@szfriends_destructive, 0.6); }\n"
    ".szfriends-mention-card { padding: 6px; }\n"
    ".szfriends-card-title, .szfriends-row-title, .szfriends-header-title { font-weight: 600; }\n"
    ".szfriends-request-card { padding: 26px 22px 22px; }\n"
    ".szfriends-request-title { font-size: 16px; font-weight: 600; }\n"
    ".szfriends-code-box { background-color: @szfriends_field_background; border: 1px solid @szfriends_separator;"
    " border-radius: 10px; padding: 14px; margin-top: 12px; }\n"
    ".szfriends-code { font-size: 26px; font-weight: 600; }\n"
    ".szfriends-composer { padding: 10px 10px 12px; border-top: 1px solid @szfriends_separator; }\n"
    ".szfriends-composer-input { background-color: @szfriends_field_background; border: 1px solid"
    " @szfriends_separator; border-radius: 10px; padding: 3px 4px; }\n"
    ".szfriends-composer-input:focus-within { border-color: @szfriends_accent; }\n"
    ".szfriends-composer-input.szfriends-disabled { opacity: 0.5; }\n"
    ".szfriends-composer-input.szfriends-drop-accept { box-shadow: 0 0 0 2px @szfriends_accent; }\n"
    ".szfriends-composer-input.szfriends-drop-refuse { box-shadow: 0 0 0 2px @szfriends_warning; }\n"
    "textview.szfriends-composer-text, textview.szfriends-composer-text > text { background: none; }\n"
    ".szfriends-composer-placeholder { color: @szfriends_secondary_text; margin: 6px 6px; }\n"
    ".szfriends-hint { color: @szfriends_secondary_text; font-size: 0.85em; }\n"
    ".szfriends-mention-chip { background-color: alpha(@szfriends_accent, 0.15); color: @szfriends_accent;"
    " border-radius: 6px; padding: 0 4px; font-weight: 600; }\n"
    "button.szfriends-chip { padding: 2px 8px; font-size: 0.92em; border-radius: 8px; }\n"
    "button.szfriends-chip label { font-weight: normal; }\n" /* weight */
    "button.szfriends-chip image { -gtk-icon-size: 12px; color: @szfriends_secondary_text; }\n"
    ".szfriends-picker, .szfriends-search-results { background-color: @szfriends_background; border: 1px solid"
    " @szfriends_separator; border-radius: 10px; padding: 8px; margin: 6px 10px;"
    " box-shadow: 0 8px 24px alpha(black, 0.25); }\n"
    "button.szfriends-picker-row { padding: 6px 8px; border-radius: 7px; }\n"
    "button.szfriends-picker-row.szfriends-selected { background-color: @szfriends_selection; }\n"
    "button.szfriends-picker-row label.szfriends-secondary, button.szfriends-picker-row label.szfriends-caption"
    " { font-weight: normal; }\n" /* weight: the title above keeps its 600 */
    ".szfriends-search-bar { padding: 8px 10px; border-bottom: 1px solid @szfriends_separator; }\n"
    ".szfriends-history-drop { border: 2px solid @szfriends_accent; border-radius: 10px; margin: 6px;"
    " background-color: alpha(@szfriends_accent, 0.08); }\n"
    ".szfriends-history-drop.szfriends-refuse { border-color: @szfriends_warning;"
    " background-color: alpha(@szfriends_warning, 0.2); }\n"
    ".szfriends-history-drop-words { background-color: @szfriends_background; color: @szfriends_text;"
    " border: 1px solid @szfriends_separator; border-radius: 8px; padding: 8px 12px; margin: 24px;"
    " font-weight: 600; box-shadow: 0 2px 8px alpha(black, 0.2); }\n"
    ".szfriends-header-subtitle { font-size: 0.85em; font-weight: normal; }\n" /* weight */
    ".szfriends-header-chevron { color: @szfriends_secondary_text; }\n"
    ".szfriends-route-local { color: @szfriends_local_route; }\n"
    ".szfriends-route-online { color: @szfriends_online_route; }\n"
    ".szfriends-route-offline, .szfriends-route-none { color: @szfriends_offline_route; }\n"
    ".szfriends-link-warning { padding: 4px 8px; }\n"
    ".szfriends-link-warning image { color: @szfriends_warning; }\n"
    ".szfriends-link-address { color: @szfriends_secondary_text; font-size: 0.92em; padding: 4px 8px; }\n"
    "button.szfriends-menu-item { padding: 4px 8px; }\n"
    "button.szfriends-menu-item label { font-weight: normal; }\n"; /* weight: a menu item, as the reader's menus */

static void log_css_error(GtkCssProvider *provider, GtkCssSection *section, GError *error, gpointer data) {
    (void)provider, (void)data;
    char *where = gtk_css_section_to_string(section);
    /* Developer-facing: a stylesheet that fails to parse is a bug in the views, never the person's. */
    g_warning("Shenzhen Friends conversation stylesheet: %s: %s", where, error->message);
    g_free(where);
}

void szfriends_gtk_conversation_style_ensure(GdkDisplay *display) {
    if (!display || g_object_get_data(G_OBJECT(display), "szfriends-conversation-style")) return;
    GtkCssProvider *provider = gtk_css_provider_new();
    g_signal_connect(provider, "parsing-error", G_CALLBACK(log_css_error), NULL);
    gtk_css_provider_load_from_string(provider, stylesheet);
    /* Beside the views' own sheet; the host's appearance_css, one priority higher, still wins. */
    gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(provider),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_set_data_full(G_OBJECT(display), "szfriends-conversation-style", provider, g_object_unref);
}
