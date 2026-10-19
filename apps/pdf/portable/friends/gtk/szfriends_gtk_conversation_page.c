/* The conversation page (szfriends_gtk_conversation.h; mirrors mac/SZFriendsConversationPage.m): the header with the
 * friend's name and route centred (a click opens details), conversation search under it, the history, the composer
 * at the bottom, and the request card in place of all that while a request is pending.
 *
 * The open_conversation subscription marks the conversation read while it exists, so it is held only while the page
 * is on screen (PROTOCOL.md open_conversation) and released when the dropdown closes or another page covers it.
 * Escape closes the innermost thing the page opened (an armed pill, the link menu or a card, a picker, the search
 * results) and never navigates back. */

#include "gtk/szfriends_gtk_conversation.h"
#include "gtk/szfriends_gtk_glyphs.h"

#include <string.h>

typedef struct {
    SZFriendsGtkConversation *conversation;
    SZFriendsGtkHistory *history;
    /* content and composer are held: the page's data goes at its widget's finalize, after GTK let go of its
     * children, and teardown still has to close what sits inside them. */
    GtkWidget *content, *title, *search_bar, *search_entry, *results, *stack, *request_card, *composer;
    GtkWidget *title_label, *subtitle_label, *route_line, *route_glyph; /* inside `title` */
    SZFriendsGtkConversationSnapshot *snapshot;
    guint subscription, search_request, restyle_source;
    char *last_query;
    int title_clickable; /* -1 before the first snapshot */
} SZFriendsGtkConversationPage;

/* ---- The header: name and route centred; a click opens details ----------------------------------------- */

/* The chevron after a name that opens details, as AppKit draws it (mac/SZFriendsIcons.m SZFriendsDrawChevronRight,
 * the same 16-unit path): pointing right because it navigates, where a chevron down would promise a menu. Without
 * it the name looks like a plain title until the pointer happens to cross it. */
static void draw_chevron(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)data;
    GdkRGBA color;
    gtk_widget_get_color(GTK_WIDGET(area), &color);
    double side = MIN(width, height);
    cairo_translate(cr, (width - side) / 2, (height - side) / 2);
    cairo_scale(cr, side / 16, side / 16);
    cairo_move_to(cr, 6, 4);
    cairo_line_to(cr, 10, 8);
    cairo_line_to(cr, 6, 12);
    cairo_set_line_width(cr, 1.8);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    gdk_cairo_set_source_rgba(cr, &color);
    cairo_stroke(cr);
}

static GtkWidget *chevron_new(void) {
    /* Decorative: the button's accessible label (the snapshot's) already says what it opens. */
    GtkWidget *chevron = g_object_new(GTK_TYPE_DRAWING_AREA, "accessible-role", GTK_ACCESSIBLE_ROLE_PRESENTATION,
                                      NULL);
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(chevron), 10);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(chevron), 10);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(chevron), draw_chevron, NULL, NULL);
    gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER);
    gtk_widget_add_css_class(chevron, "szfriends-header-chevron");
    return chevron;
}

static void title_clicked(GtkButton *button, gpointer data) {
    (void)button;
    SZFriendsGtkConversationPage *view = data;
    if (view->conversation->dropdown)
        szfriends_gtk_dropdown_open_details(view->conversation->dropdown, view->conversation->conversation_id);
}

static const char *route_class(SZFriendsGtkRouteKind kind) {
    switch (kind) {
    case SZFRIENDS_GTK_ROUTE_LOCAL: return "szfriends-route-local";
    case SZFRIENDS_GTK_ROUTE_ONLINE: return "szfriends-route-online";
    default: return "szfriends-route-offline";
    }
}

static void apply_header(SZFriendsGtkConversationPage *view, SZFriendsGtkPage *page, const SZFriendsGtkHeader *header) {
    if (view->title_clickable != header->details_available) {
        view->title_clickable = header->details_available;
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
        GtkWidget *name_line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 3);
        gtk_widget_set_halign(name_line, GTK_ALIGN_CENTER);
        view->title_label = gtk_label_new(NULL);
        view->subtitle_label = gtk_label_new(NULL);
        gtk_label_set_ellipsize(GTK_LABEL(view->title_label), PANGO_ELLIPSIZE_END);
        gtk_label_set_ellipsize(GTK_LABEL(view->subtitle_label), PANGO_ELLIPSIZE_END);
        gtk_widget_add_css_class(view->title_label, "szfriends-header-title");
        gtk_widget_add_css_class(view->subtitle_label, "szfriends-header-subtitle");
        gtk_box_append(GTK_BOX(name_line), view->title_label);
        if (header->details_available) gtk_box_append(GTK_BOX(name_line), chevron_new());
        gtk_box_append(GTK_BOX(box), name_line);
        /* The route line: the route's icon before the words, as rows show it, the two centred together. */
        view->route_line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
        gtk_widget_set_halign(view->route_line, GTK_ALIGN_CENTER);
        gtk_widget_set_name(view->route_line, "szfriends.header-route");
        view->route_glyph = szfriends_gtk_glyph_new(SZFRIENDS_GTK_GLYPH_NONE, 11);
        gtk_box_append(GTK_BOX(view->route_line), view->route_glyph);
        gtk_box_append(GTK_BOX(view->route_line), view->subtitle_label);
        gtk_box_append(GTK_BOX(box), view->route_line);
        view->title = box;
        if (header->details_available) {
            view->title = gtk_button_new();
            gtk_widget_add_css_class(view->title, "flat");
            gtk_button_set_child(GTK_BUTTON(view->title), box);
            g_signal_connect(view->title, "clicked", G_CALLBACK(title_clicked), view);
        }
        szfriends_gtk_page_set_title_widget(page, view->title);
    }
    GtkWidget *title = view->title_label, *subtitle = view->subtitle_label;
    gtk_label_set_text(GTK_LABEL(title), header->title);
    gtk_label_set_text(GTK_LABEL(subtitle), header->subtitle ? header->subtitle : "");
    gboolean has_line = header->subtitle && *header->subtitle;
    gtk_widget_set_visible(view->route_line, has_line);
    SZFriendsGtkGlyphKind glyph = szfriends_gtk_route_glyph(header->route.kind, header->route.method);
    szfriends_gtk_glyph_set_kind(view->route_glyph, glyph);
    gtk_widget_set_visible(view->route_glyph, glyph != SZFRIENDS_GTK_GLYPH_NONE);
    for (int kind = SZFRIENDS_GTK_ROUTE_UNKNOWN; kind <= SZFRIENDS_GTK_ROUTE_CONNECTING; kind++) {
        gtk_widget_remove_css_class(subtitle, route_class((SZFriendsGtkRouteKind)kind));
        gtk_widget_remove_css_class(view->route_glyph, route_class((SZFriendsGtkRouteKind)kind));
    }
    gtk_widget_add_css_class(subtitle, route_class(header->route.kind));
    gtk_widget_add_css_class(view->route_glyph, route_class(header->route.kind));
    gtk_widget_set_tooltip_text(view->route_line, header->route.label);
    gtk_accessible_update_property(GTK_ACCESSIBLE(view->title), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                   header->accessibility_label, -1);
    szfriends_gtk_page_set_name(page, header->title);
}

/* ---- Conversation search: excerpts, and choosing one jumps to that exact message --------------------------- */

static void close_results(SZFriendsGtkConversationPage *view) {
    if (!view->results) return;
    gtk_overlay_remove_overlay(GTK_OVERLAY(view->content), view->results);
    view->results = NULL;
}

static void result_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkConversationPage *view = data;
    char *conversation_id = g_strdup(g_object_get_data(G_OBJECT(button), "szfriends-conversation"));
    char *message_id = g_strdup(g_object_get_data(G_OBJECT(button), "szfriends-message"));
    close_results(view);
    /* This conversation highlights it in place; another one opens with it (szfriends_gtk_dropdown.h). */
    if (view->conversation->dropdown)
        szfriends_gtk_dropdown_open_conversation(view->conversation->dropdown, conversation_id, message_id);
    g_free(conversation_id);
    g_free(message_id);
}

static GtkWidget *result_row(SZFriendsGtkConversationPage *view, const SZFriendsGtkSearchHit *hit) {
    GtkWidget *row = gtk_button_new(), *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    GtkWidget *first = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *sender = gtk_label_new(hit->sender_label), *time = gtk_label_new(hit->time_label);
    gtk_widget_add_css_class(sender, "szfriends-row-title");
    gtk_label_set_xalign(GTK_LABEL(sender), 0);
    gtk_widget_set_hexpand(sender, TRUE);
    gtk_widget_add_css_class(time, "szfriends-caption");
    gtk_box_append(GTK_BOX(first), sender);
    gtk_box_append(GTK_BOX(first), time);
    PangoAttrList *attributes = NULL;
    char *text = szfriends_gtk_rich_text(hit->excerpt, hit->n_excerpt, &attributes);
    GtkWidget *excerpt = gtk_label_new(text);
    gtk_label_set_attributes(GTK_LABEL(excerpt), attributes);
    gtk_label_set_xalign(GTK_LABEL(excerpt), 0);
    gtk_label_set_ellipsize(GTK_LABEL(excerpt), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class(excerpt, "szfriends-secondary");
    gtk_box_append(GTK_BOX(box), first);
    gtk_box_append(GTK_BOX(box), excerpt);
    gtk_button_set_child(GTK_BUTTON(row), box);
    gtk_widget_add_css_class(row, "flat");
    gtk_widget_add_css_class(row, "szfriends-picker-row");
    /* Who and the matching words, as the snapshot gives them; the view composes no sentence of its own. */
    gtk_accessible_update_property(GTK_ACCESSIBLE(row), GTK_ACCESSIBLE_PROPERTY_LABEL, hit->sender_label,
                                   GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, text, -1);
    g_object_set_data_full(G_OBJECT(row), "szfriends-conversation", g_strdup(hit->conversation_id), g_free);
    g_object_set_data_full(G_OBJECT(row), "szfriends-message", g_strdup(hit->message_id), g_free);
    g_signal_connect(row, "clicked", G_CALLBACK(result_clicked), view);
    pango_attr_list_unref(attributes);
    g_free(text);
    return row;
}

static void searched(JsonObject *result, const SZFriendsGtkError *error, gpointer data) {
    SZFriendsGtkConversationPage *view = data;
    view->search_request = 0;
    if (error || !result || !view->conversation->page) return;
    SZFriendsGtkSearchResult *found = szfriends_gtk_search_result_parse(result);
    close_results(view);
    view->results = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_add_css_class(view->results, "szfriends-search-results");
    gtk_widget_set_valign(view->results, GTK_ALIGN_START);
    for (gsize i = 0; i < found->n_results && i < 6; i++)
        gtk_box_append(GTK_BOX(view->results), result_row(view, &found->results[i]));
    if (!found->n_results && found->empty_label && *found->empty_label) {
        GtkWidget *empty = gtk_label_new(found->empty_label);
        gtk_widget_add_css_class(empty, "szfriends-secondary");
        gtk_box_append(GTK_BOX(view->results), empty);
    }
    if (gtk_widget_get_first_child(view->results)) gtk_overlay_add_overlay(GTK_OVERLAY(view->content), view->results);
    else view->results = NULL;
    szfriends_gtk_search_result_free(found);
}

static void run_search(SZFriendsGtkConversationPage *view) {
    const char *query = gtk_editable_get_text(GTK_EDITABLE(view->search_entry));
    if (view->search_request) szfriends_gtk_link_forget_reply(view->conversation->link, view->search_request);
    view->search_request = 0;
    if (!*query) {
        close_results(view);
        return;
    }
    /* Local search costs nothing on the network; the entry's short pause keeps it off every keystroke. */
    view->search_request = szfriends_gtk_link_send(
        view->conversation->link,
        szfriends_intent_search_messages(query, view->conversation->conversation_id, 0), searched, view, NULL);
}

static void search_changed(GtkSearchEntry *entry, gpointer data) {
    (void)entry;
    run_search(data);
}

/* ---- Snapshots ------------------------------------------------------------------------------------------ */

static void apply_snapshot(JsonObject *data, gint64 rev, gpointer user_data) {
    (void)rev;
    SZFriendsGtkConversationPage *view = user_data;
    SZFriendsGtkPage *page = view->conversation->page;
    if (!page) return;
    SZFriendsGtkConversationSnapshot *snapshot = szfriends_gtk_conversation_snapshot_parse(data);
    apply_header(view, page, &snapshot->header);
    szfriends_gtk_page_set_back(page, &snapshot->back);
    const char *placeholder = *snapshot->search_placeholder ? snapshot->search_placeholder
                              : szfriends_gtk_link_string(view->conversation->link, "conversation_search_placeholder");
    gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(view->search_entry), placeholder);
    gboolean request = snapshot->request != NULL;
    gtk_widget_set_visible(view->search_bar, !request);
    if (request) {
        szfriends_gtk_request_card_apply(view->request_card, snapshot->request);
        close_results(view);
    }
    gtk_stack_set_visible_child_name(GTK_STACK(view->stack), request ? "request" : "history");
    gtk_widget_set_visible(view->composer, snapshot->composer.visible && !request);
    szfriends_gtk_composer_apply(szfriends_gtk_composer_from_widget(view->composer), &snapshot->composer);
    szfriends_gtk_history_apply(view->history, data, snapshot, view->subscription);
    szfriends_gtk_mention_card_follow(view->conversation, snapshot);
    if (view->snapshot) szfriends_gtk_conversation_snapshot_free(view->snapshot);
    view->snapshot = snapshot;
}

/* ---- The page class ------------------------------------------------------------------------------------ */

/* Mentions, links and a card's marks carry their colours as Pango attributes, which CSS does not restyle, so the
 * rows and an open card are drawn again for the new appearance. Not inside notify::dark: libadwaita puts its new
 * stylesheet in after notifying, so a colour read there is the old appearance's (a live switch to dark kept every
 * mention at the light #0461BE on the dark page, 2.2:1). An idle at high priority runs once the new stylesheet is
 * in and before GDK's redraw, so the first dark frame already has the dark accent. Everything else restyles through
 * CSS on that frame by itself, the pickers included (the conversation probes emulate that frame). */
static gboolean restyle(gpointer data) {
    SZFriendsGtkConversationPage *view = data;
    view->restyle_source = 0;
    szfriends_gtk_history_restyle(view->history);
    if (view->snapshot) szfriends_gtk_mention_card_follow(view->conversation, view->snapshot);
    return G_SOURCE_REMOVE;
}

static void appearance_changed(GObject *manager, GParamSpec *spec, gpointer data) {
    (void)manager, (void)spec;
    SZFriendsGtkConversationPage *view = data;
    if (!view->restyle_source) view->restyle_source = g_idle_add_full(G_PRIORITY_HIGH_IDLE, restyle, view, NULL);
}

static void view_free(gpointer data) {
    SZFriendsGtkConversationPage *view = data;
    SZFriendsGtkConversation *conversation = view->conversation;
    g_signal_handlers_disconnect_by_data(adw_style_manager_get_default(), view);
    if (view->restyle_source) g_source_remove(view->restyle_source);
    if (view->subscription) szfriends_gtk_link_unsubscribe(conversation->link, view->subscription);
    if (view->search_request) szfriends_gtk_link_forget_reply(conversation->link, view->search_request);
    if (conversation->composer) szfriends_gtk_composer_close_picker(conversation->composer);
    szfriends_gtk_conversation_close_popover(conversation);
    close_results(view);
    szfriends_gtk_conversation_detach(conversation);
    szfriends_gtk_history_free(view->history);
    if (view->snapshot) szfriends_gtk_conversation_snapshot_free(view->snapshot);
    g_free(view->last_query);
    g_signal_handlers_disconnect_by_data(view->search_entry, view); /* its delayed search-changed finds nothing */
    g_object_unref(view->search_entry);
    g_object_unref(view->composer);
    g_object_unref(view->content);
    szfriends_gtk_conversation_unref(conversation);
    g_free(view);
}

static void build(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    szfriends_gtk_conversation_style_ensure(gdk_display_get_default());
    SZFriendsGtkConversationPage *view = g_new0(SZFriendsGtkConversationPage, 1);
    SZFriendsGtkConversation *conversation = view->conversation = szfriends_gtk_conversation_new(page);
    view->title_clickable = -1;
    szfriends_gtk_page_set_data(page, view, view_free);
    GtkWidget *widget = szfriends_gtk_page_get_widget(page);
    gtk_widget_set_name(widget, "szfriends.conversation");
    /* Until the first snapshot names the friend, the page is the Friends dropdown's, as the button says. */
    szfriends_gtk_page_set_name(page, NULL);

    view->search_bar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(view->search_bar, "szfriends-search-bar");
    view->search_entry = g_object_ref_sink(gtk_search_entry_new()); /* held, so teardown can silence it */
    gtk_search_entry_set_search_delay(GTK_SEARCH_ENTRY(view->search_entry), 250);
    gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(view->search_entry),
        szfriends_gtk_link_string(conversation->link, "conversation_search_placeholder"));
    g_signal_connect(view->search_entry, "search-changed", G_CALLBACK(search_changed), view);
    g_signal_connect_swapped(view->search_entry, "activate", G_CALLBACK(run_search), view);
    gtk_box_append(GTK_BOX(view->search_bar), view->search_entry);
    szfriends_gtk_page_add_top_bar(page, view->search_bar);

    view->history = szfriends_gtk_history_new(conversation);
    view->request_card = szfriends_gtk_request_card_new(conversation);
    GtkWidget *request = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(request), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(request), view->request_card);
    view->stack = gtk_stack_new();
    gtk_stack_add_named(GTK_STACK(view->stack), szfriends_gtk_history_widget(view->history), "history");
    gtk_stack_add_named(GTK_STACK(view->stack), request, "request");
    GtkWidget *content = gtk_overlay_new();
    gtk_overlay_set_child(GTK_OVERLAY(content), view->stack);
    /* Resolve the accent and warning tokens for the Pango colours of mentions, links and marks; never seen. */
    conversation->color_probe = gtk_label_new(NULL);
    conversation->warning_probe = gtk_label_new(NULL);
    gtk_widget_add_css_class(conversation->color_probe, "szfriends-accent-probe");
    gtk_widget_add_css_class(conversation->warning_probe, "szfriends-warning-probe");
    for (GtkWidget *const *probe = (GtkWidget *const[]){conversation->color_probe, conversation->warning_probe, NULL};
         *probe; probe++) {
        gtk_widget_set_visible(*probe, FALSE);
        gtk_overlay_add_overlay(GTK_OVERLAY(content), *probe);
    }
    conversation->content = view->content = g_object_ref_sink(content);
    szfriends_gtk_page_set_content(page, content);
    view->composer = g_object_ref_sink(szfriends_gtk_composer_new(conversation));
    szfriends_gtk_page_add_bottom_bar(page, view->composer);
    g_signal_connect(adw_style_manager_get_default(), "notify::dark", G_CALLBACK(appearance_changed), view);
}

static void presented(SZFriendsGtkPage *page, gboolean on_screen, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkConversationPage *view = szfriends_gtk_page_get_data(page);
    SZFriendsGtkConversation *conversation = view->conversation;
    if (on_screen && !view->subscription) {
        view->subscription = szfriends_gtk_link_open_conversation(conversation->link, conversation->conversation_id,
                                                                  szfriends_gtk_page_get_message_id(page),
                                                                  apply_snapshot, view, NULL);
        /* A popover with autohide off takes no focus by itself: the composer takes it, so typing goes there. */
        if (conversation->composer && gtk_widget_get_visible(view->composer))
            gtk_widget_grab_focus(szfriends_gtk_composer_get_text_view(conversation->composer));
        return;
    }
    if (on_screen || !view->subscription) return;
    szfriends_gtk_link_unsubscribe(conversation->link, view->subscription);
    view->subscription = 0;
    szfriends_gtk_conversation_close_popover(conversation);
    if (conversation->composer) szfriends_gtk_composer_close_picker(conversation->composer);
    close_results(view);
    /* Still on top of an open dropdown: the same conversation was asked for again with a message to highlight, and
     * that message gets scrolled to even if it was the last one. Reopening later does not jump again. */
    SZFriendsGtkDropdown *dropdown = conversation->dropdown;
    if (dropdown && szfriends_gtk_dropdown_is_open(dropdown) && szfriends_gtk_dropdown_get_top_page(dropdown) == page)
        szfriends_gtk_history_forget_highlight(view->history);
}

static gboolean escape(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkConversationPage *view = szfriends_gtk_page_get_data(page);
    SZFriendsGtkConversation *conversation = view->conversation;
    if (szfriends_gtk_conversation_disarm(conversation)) return TRUE;
    if (szfriends_gtk_conversation_close_popover(conversation)) return TRUE;
    if (szfriends_gtk_composer_escape(conversation->composer)) return TRUE;
    if (view->results) {
        close_results(view);
        return TRUE;
    }
    return FALSE;
}

const SZFriendsGtkPageClass szfriends_gtk_conversation_page_class = {build, presented, escape, NULL};

/* For the suite: the parts of a page it drives. */
SZFriendsGtkHistory *szfriends_gtk_conversation_page_history(SZFriendsGtkPage *page) {
    SZFriendsGtkConversationPage *view = page ? szfriends_gtk_page_get_data(page) : NULL;
    return view ? view->history : NULL;
}

SZFriendsGtkConversation *szfriends_gtk_conversation_page_state(SZFriendsGtkPage *page) {
    SZFriendsGtkConversationPage *view = page ? szfriends_gtk_page_get_data(page) : NULL;
    return view ? view->conversation : NULL;
}

GtkWidget *szfriends_gtk_conversation_page_part(SZFriendsGtkPage *page, const char *name) {
    SZFriendsGtkConversationPage *view = page ? szfriends_gtk_page_get_data(page) : NULL;
    if (!view) return NULL;
    if (strcmp(name, "title") == 0) return view->title;
    if (strcmp(name, "search") == 0) return view->search_entry;
    if (strcmp(name, "results") == 0) return view->results;
    if (strcmp(name, "stack") == 0) return view->stack;
    if (strcmp(name, "request") == 0) return view->request_card;
    if (strcmp(name, "composer") == 0) return view->composer;
    return NULL;
}
