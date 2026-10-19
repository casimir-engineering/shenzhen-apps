/* Day separators, events and message bubbles (szfriends_gtk_conversation.h; mirrors SZFriendsMessageItemView and
 * SZFriendsMessageBody in mac/).
 *
 * A bubble shows the item's segments as plain text with a PangoAttrList, never markup: a "<b>" a friend typed stays
 * "<b>". Links are underlined, mentions take the accent colour (the reader's own one is highlighted), and a click
 * never opens anything by itself: a web or email link shows the link menu, a friend's mention opens their
 * conversation, a stranger's shows their card (PROTOCOL.md § Mentions); the keyboard reaches the same segments
 * (szfriends_gtk_message_keys.c). Under the bubble the time line carries "Via the assistant", the time, the status
 * and the actions (Try again, Cancel). */

#include "gtk/szfriends_gtk_conversation.h"

#include <string.h>

/* A plain bubble keeps to chat width: 280 points, as the AppKit bubble. */
#define SZFRIENDS_GTK_BUBBLE_WIDTH 280
#define SZFRIENDS_GTK_CANCELLED_OPACITY 0.45

typedef struct {
    SZFriendsGtkConversation *conversation;
    GObject *holder;     /* keeps the item alive for clicks after the snapshot moved on */
    const SZFriendsGtkConversationItem *item;
    GArray *ranges;      /* guint pairs: each segment's byte range in the full text */
    char *text;          /* the full text */
    PangoAttrList *attributes;
    gssize pressed;      /* the segment a click started on, -1 for none */
} SZFriendsGtkBody;

static void body_free(gpointer data) {
    SZFriendsGtkBody *body = data;
    g_array_unref(body->ranges);
    g_free(body->text);
    pango_attr_list_unref(body->attributes);
    g_object_unref(body->holder);
    szfriends_gtk_conversation_unref(body->conversation);
    g_free(body);
}

static GtkWidget *plain_label(const char *text, const char *css_class) {
    GtkWidget *label = gtk_label_new(text ? text : "");
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    if (css_class) gtk_widget_add_css_class(label, css_class);
    return label;
}

GtkWidget *szfriends_gtk_simple_row_new(const SZFriendsGtkConversationItem *item) {
    if (item->kind == SZFRIENDS_GTK_ITEM_DAY) return plain_label(item->label, "szfriends-day");
    /* An event: its words, then its time in the caption size beside them, like a message's time under its bubble. */
    GString *text = g_string_new(item->text);
    gsize words = text->len;
    if (item->time_label && *item->time_label) g_string_append_printf(text, "  %s", item->time_label);
    GtkWidget *label = plain_label(text->str, "szfriends-event");
    gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
    PangoAttrList *attributes = pango_attr_list_new();
    PangoAttribute *smaller = pango_attr_scale_new(0.85);
    smaller->start_index = (guint)words, smaller->end_index = (guint)text->len;
    pango_attr_list_insert(attributes, smaller);
    gtk_label_set_attributes(GTK_LABEL(label), attributes);
    pango_attr_list_unref(attributes);
    g_string_free(text, TRUE);
    return label;
}

/* ---- The words: segments, links and mentions ------------------------------------------------------- */

static void insert(PangoAttrList *list, PangoAttribute *attribute, guint start, guint end) {
    attribute->start_index = start, attribute->end_index = end;
    pango_attr_list_insert(list, attribute);
}

static guint16 channel(float value) {
    return (guint16)(CLAMP(value, 0.f, 1.f) * 65535.f);
}

static void style_segments(SZFriendsGtkBody *body) {
    GdkRGBA color;
    gboolean colored = szfriends_gtk_conversation_accent(body->conversation, &color);
    for (gsize i = 0; i < body->item->n_segments; i++) {
        guint start = g_array_index(body->ranges, guint, 2 * i), end = g_array_index(body->ranges, guint, 2 * i + 1);
        SZFriendsGtkHit hit = szfriends_gtk_link_hit(body->item, i);
        const SZFriendsGtkSegment *segment = &body->item->segments[i];
        const SZFriendsGtkMention *mention = NULL;
        if (segment->mention.set && segment->mention.value >= 0 && (guint64)segment->mention.value <
                                                                       body->item->n_mentions)
            mention = &body->item->mentions[segment->mention.value];
        if (start == end || (!mention && hit.kind == SZFRIENDS_GTK_HIT_NONE)) continue;
        if (mention) insert(body->attributes, pango_attr_weight_new(PANGO_WEIGHT_SEMIBOLD), start, end);
        if (colored && (hit.kind != SZFRIENDS_GTK_HIT_NONE))
            insert(body->attributes, pango_attr_foreground_new(channel(color.red), channel(color.green),
                                                               channel(color.blue)), start, end);
        if (mention && mention->kind == SZFRIENDS_GTK_MENTION_YOU && colored) {
            /* The reader's own name, highlighted: nothing to click, so no link colour. */
            insert(body->attributes, pango_attr_background_new(channel(color.red), channel(color.green),
                                                               channel(color.blue)), start, end);
            insert(body->attributes, pango_attr_background_alpha_new(0x3000), start, end);
        }
    }
}

static SZFriendsGtkBody *body_new(SZFriendsGtkConversation *conversation, GObject *holder,
                                  const SZFriendsGtkConversationItem *item) {
    SZFriendsGtkBody *body = g_new0(SZFriendsGtkBody, 1);
    body->conversation = szfriends_gtk_conversation_ref(conversation);
    body->holder = g_object_ref(holder);
    body->item = item;
    body->pressed = -1;
    body->ranges = g_array_new(FALSE, FALSE, sizeof(guint));
    body->text = szfriends_gtk_rich_text(item->segments, item->n_segments, &body->attributes);
    guint offset = 0;
    for (gsize i = 0; i < item->n_segments; i++) {
        guint end = offset + (guint)strlen(item->segments[i].text ? item->segments[i].text : "");
        g_array_append_val(body->ranges, offset);
        g_array_append_val(body->ranges, end);
        offset = end;
    }
    style_segments(body);
    return body;
}

gssize szfriends_gtk_message_segment_at(GtkWidget *label, double x, double y) {
    SZFriendsGtkBody *body = label ? g_object_get_data(G_OBJECT(label), "szfriends-body") : NULL;
    if (!body) return -1;
    PangoLayout *layout = gtk_label_get_layout(GTK_LABEL(label));
    int ox = 0, oy = 0, index = 0, trailing = 0;
    gtk_label_get_layout_offsets(GTK_LABEL(label), &ox, &oy);
    if (!pango_layout_xy_to_index(layout, (int)((x - ox) * PANGO_SCALE), (int)((y - oy) * PANGO_SCALE), &index,
                                  &trailing))
        return -1;
    for (guint i = 0; i + 1 < body->ranges->len; i += 2)
        if ((guint)index >= g_array_index(body->ranges, guint, i) && (guint)index < g_array_index(body->ranges, guint,
                                                                                                i + 1))
            return (gssize)(i / 2);
    return -1;
}

static GdkRectangle segment_rect(GtkWidget *label, SZFriendsGtkBody *body, gsize segment) {
    PangoRectangle position;
    int ox = 0, oy = 0;
    pango_layout_index_to_pos(gtk_label_get_layout(GTK_LABEL(label)),
                              (int)g_array_index(body->ranges, guint, 2 * segment), &position);
    gtk_label_get_layout_offsets(GTK_LABEL(label), &ox, &oy);
    return (GdkRectangle){ox + PANGO_PIXELS(position.x), oy + PANGO_PIXELS(position.y),
                          MAX(1, PANGO_PIXELS(position.width)), MAX(1, PANGO_PIXELS(position.height))};
}

typedef struct {
    SZFriendsGtkConversation *conversation;
    char *conversation_id;
} SZFriendsGtkNavigation;

/* The page that drew the mention goes away when the friend's conversation opens, so that happens after the click. */
static gboolean navigate(gpointer data) {
    SZFriendsGtkNavigation *navigation = data;
    if (navigation->conversation->page && navigation->conversation->dropdown)
        szfriends_gtk_dropdown_open_conversation(navigation->conversation->dropdown, navigation->conversation_id,
                                                 NULL);
    szfriends_gtk_conversation_unref(navigation->conversation);
    g_free(navigation->conversation_id);
    g_free(navigation);
    return G_SOURCE_REMOVE;
}

SZFriendsGtkHitKind szfriends_gtk_message_activate(SZFriendsGtkConversation *conversation,
                                                    const SZFriendsGtkConversationItem *item, gsize segment,
                                                    GtkWidget *label) {
    SZFriendsGtkHit hit = szfriends_gtk_link_hit(item, segment);
    SZFriendsGtkBody *body = label ? g_object_get_data(G_OBJECT(label), "szfriends-body") : NULL;
    if (hit.kind == SZFRIENDS_GTK_HIT_FRIEND) {
        SZFriendsGtkNavigation *navigation = g_new0(SZFriendsGtkNavigation, 1);
        navigation->conversation = szfriends_gtk_conversation_ref(conversation);
        navigation->conversation_id = g_strdup(hit.mention->conversation_id);
        g_idle_add(navigate, navigation);
    } else if (hit.kind != SZFRIENDS_GTK_HIT_NONE && body) {
        GtkWidget *popover, *owner = label;
        GdkRectangle rect = segment_rect(label, body, segment);
        if (hit.kind == SZFRIENDS_GTK_HIT_CARD) {
            popover = gtk_popover_new();
            gtk_popover_set_child(GTK_POPOVER(popover), szfriends_gtk_mention_card_new(conversation, item,
                                                                                       hit.mention));
            /* The card follows new snapshots (Request sent), and a snapshot that changes this message makes its row
             * anew, which would take a popover pointing from the old words with it: the card points from the page
             * instead, at the same place. */
            graphene_point_t at;
            if (conversation->content &&
                gtk_widget_compute_point(label, conversation->content, &GRAPHENE_POINT_INIT(rect.x, rect.y), &at)) {
                owner = conversation->content;
                rect.x = (int)at.x, rect.y = (int)at.y;
            }
        } else {
            popover = szfriends_gtk_link_menu_new(conversation, hit.url, item->segments[segment].text);
        }
        szfriends_gtk_conversation_show_popover(conversation, owner, popover, &rect);
    }
    return hit.kind;
}

static void pressed(GtkGestureClick *gesture, int presses, double x, double y, gpointer data) {
    (void)presses;
    SZFriendsGtkBody *body = data;
    GtkWidget *label = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    gssize segment = szfriends_gtk_message_segment_at(label, x, y);
    gboolean link = segment >= 0 && szfriends_gtk_link_hit(body->item, (gsize)segment).kind != SZFRIENDS_GTK_HIT_NONE;
    body->pressed = link ? segment : -1;
    /* A press on a link is the link's; anywhere else it selects text, as the label always does. */
    gtk_gesture_set_state(GTK_GESTURE(gesture), link ? GTK_EVENT_SEQUENCE_CLAIMED : GTK_EVENT_SEQUENCE_DENIED);
}

static void released(GtkGestureClick *gesture, int presses, double x, double y, gpointer data) {
    (void)presses;
    SZFriendsGtkBody *body = data;
    GtkWidget *label = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    gssize segment = body->pressed;
    body->pressed = -1;
    if (segment >= 0 && szfriends_gtk_message_segment_at(label, x, y) == segment)
        szfriends_gtk_message_activate(body->conversation, body->item, (gsize)segment, label);
}

static void moved(GtkEventControllerMotion *motion, double x, double y, gpointer data) {
    SZFriendsGtkBody *body = data;
    GtkWidget *label = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(motion));
    gssize segment = szfriends_gtk_message_segment_at(label, x, y);
    gboolean link = segment >= 0 && szfriends_gtk_link_hit(body->item, (gsize)segment).kind != SZFRIENDS_GTK_HIT_NONE;
    gtk_widget_set_cursor_from_name(label, link ? "pointer" : NULL);
}

static gboolean query_tooltip(GtkWidget *label, int x, int y, gboolean keyboard, GtkTooltip *tooltip, gpointer data) {
    (void)keyboard;
    SZFriendsGtkBody *body = data;
    gssize segment = szfriends_gtk_message_segment_at(label, x, y);
    SZFriendsGtkHit hit = segment >= 0 ? szfriends_gtk_link_hit(body->item, (gsize)segment)
                                           : (SZFriendsGtkHit){SZFRIENDS_GTK_HIT_NONE, NULL, NULL};
    /* A mention says in a few words what a click does ("Open your chat with Mei"); a link's menu says where it goes. */
    const SZFriendsGtkSegment *seg = segment >= 0 ? &body->item->segments[segment] : NULL;
    const SZFriendsGtkMention *mention = hit.mention;
    if (!mention && seg && seg->mention.set && seg->mention.value >= 0 &&
        (guint64)seg->mention.value < body->item->n_mentions)
        mention = &body->item->mentions[seg->mention.value];
    if (!mention || !mention->tooltip || !*mention->tooltip) return FALSE;
    gtk_tooltip_set_text(tooltip, mention->tooltip);
    return TRUE;
}

static void show_all(GtkButton *button, gpointer data) {
    GtkWidget *label = data;
    SZFriendsGtkBody *body = g_object_get_data(G_OBJECT(label), "szfriends-body");
    g_hash_table_add(body->conversation->expanded, g_strdup(body->item->item_id));
    gtk_label_set_text(GTK_LABEL(label), body->text);
    gtk_label_set_attributes(GTK_LABEL(label), body->attributes);
    gtk_widget_set_visible(GTK_WIDGET(button), FALSE);
}

static GtkWidget *body_label(SZFriendsGtkConversation *conversation, GObject *holder,
                             const SZFriendsGtkConversationItem *item, GtkWidget **show_all_button) {
    SZFriendsGtkBody *body = body_new(conversation, holder, item);
    GtkWidget *label = plain_label(NULL, "szfriends-message-text");
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    /* A wrapping label asks for a few dozen characters by default; this one asks for its whole line, and the clamp
     * around the bubble keeps it to chat width. */
    gtk_label_set_max_width_chars(GTK_LABEL(label), 400);
    gtk_label_set_selectable(GTK_LABEL(label), TRUE);
    g_object_set_data_full(G_OBJECT(label), "szfriends-body", body, body_free);
    gboolean whole = g_hash_table_contains(conversation->expanded, item->item_id);
    gssize cut = whole ? -1 : szfriends_gtk_plain_cut(body->text);
    char *shown = cut < 0 ? g_strdup(body->text) : g_strndup(body->text, (gsize)cut);
    gtk_label_set_text(GTK_LABEL(label), shown);
    gtk_label_set_attributes(GTK_LABEL(label), body->attributes);
    g_free(shown);
    *show_all_button = NULL;
    const char *more = szfriends_gtk_link_string(conversation->link, "show_all");
    if (cut >= 0 && *more) {
        *show_all_button = gtk_button_new_with_label(more);
        gtk_widget_add_css_class(*show_all_button, "flat");
        gtk_widget_add_css_class(*show_all_button, "szfriends-link");
        gtk_widget_set_halign(*show_all_button, GTK_ALIGN_START);
        g_signal_connect(*show_all_button, "clicked", G_CALLBACK(show_all), label);
    }
    GtkGesture *click = gtk_gesture_click_new();
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(click), GTK_PHASE_CAPTURE);
    g_signal_connect(click, "pressed", G_CALLBACK(pressed), body);
    g_signal_connect(click, "released", G_CALLBACK(released), body);
    gtk_widget_add_controller(label, GTK_EVENT_CONTROLLER(click));
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(moved), body);
    gtk_widget_add_controller(label, motion);
    gtk_widget_set_has_tooltip(label, TRUE);
    g_signal_connect(label, "query-tooltip", G_CALLBACK(query_tooltip), body);
    gboolean links = FALSE;
    for (gsize i = 0; i < item->n_segments && !links; i++)
        links = szfriends_gtk_link_hit(item, i).kind != SZFRIENDS_GTK_HIT_NONE;
    if (links) szfriends_gtk_message_keys_attach(conversation, holder, item, label, body->ranges, body->attributes);
    return label;
}

/* ---- The bubble and its time line ------------------------------------------------------------------ */

/* The assistant's spark, drawn so it stays sharp and needs no image; the same mark as the host's AI chat. */
static void draw_spark(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)data;
    GdkRGBA color;
    gtk_widget_get_color(GTK_WIDGET(area), &color);
    double cx = width / 2.0, cy = height / 2.0, r = MIN(width, height) / 2.0;
    cairo_move_to(cr, cx, cy - r);
    cairo_curve_to(cr, cx + r * 0.15, cy - r * 0.15, cx + r * 0.15, cy - r * 0.15, cx + r, cy);
    cairo_curve_to(cr, cx + r * 0.15, cy + r * 0.15, cx + r * 0.15, cy + r * 0.15, cx, cy + r);
    cairo_curve_to(cr, cx - r * 0.15, cy + r * 0.15, cx - r * 0.15, cy + r * 0.15, cx - r, cy);
    cairo_curve_to(cr, cx - r * 0.15, cy - r * 0.15, cx - r * 0.15, cy - r * 0.15, cx, cy - r);
    gdk_cairo_set_source_rgba(cr, &color);
    cairo_fill(cr);
}

GtkWidget *szfriends_gtk_assistant_label_new(const char *text) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_add_css_class(box, "szfriends-assistant-label");
    GtkWidget *spark = gtk_drawing_area_new();
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(spark), 10);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(spark), 10);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(spark), draw_spark, NULL, NULL);
    gtk_widget_set_valign(spark, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(box), spark);
    gtk_box_append(GTK_BOX(box), gtk_label_new(text));
    return box;
}

GtkWidget *szfriends_gtk_message_row_new(SZFriendsGtkConversation *conversation, GObject *holder,
                                         const SZFriendsGtkConversationItem *item) {
    gboolean outgoing = item->direction == SZFRIENDS_GTK_DIRECTION_OUT;
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_widget_set_halign(row, outgoing ? GTK_ALIGN_END : GTK_ALIGN_START);
    GtkWidget *clamp = adw_clamp_new();
    adw_clamp_set_maximum_size(ADW_CLAMP(clamp), SZFRIENDS_GTK_BUBBLE_WIDTH);
    adw_clamp_set_tightening_threshold(ADW_CLAMP(clamp), SZFRIENDS_GTK_BUBBLE_WIDTH);
    adw_clamp_set_unit(ADW_CLAMP(clamp), ADW_LENGTH_UNIT_PX); /* the dropdown's own unit; sp grows with the font */
    gtk_widget_set_halign(clamp, outgoing ? GTK_ALIGN_END : GTK_ALIGN_START);
    GtkWidget *bubble = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_add_css_class(bubble, "szfriends-bubble");
    gtk_widget_add_css_class(bubble, outgoing ? "szfriends-outgoing" : "szfriends-incoming");
    if (item->highlighted) gtk_widget_add_css_class(bubble, "szfriends-highlighted");
    gtk_widget_set_halign(bubble, outgoing ? GTK_ALIGN_END : GTK_ALIGN_START);
    /* A message the person cancelled never left: its bubble fades, so it reads as not sent at a glance. */
    if (item->status && item->status->state == SZFRIENDS_GTK_MESSAGE_CANCELLED)
        gtk_widget_set_opacity(bubble, SZFRIENDS_GTK_CANCELLED_OPACITY);
    GtkWidget *show_all_button = NULL;
    gtk_box_append(GTK_BOX(bubble), body_label(conversation, holder, item, &show_all_button));
    if (show_all_button) gtk_box_append(GTK_BOX(bubble), show_all_button);
    adw_clamp_set_child(ADW_CLAMP(clamp), bubble);
    gtk_box_append(GTK_BOX(row), clamp);

    /* "Via the assistant" leads the time line, then the time, the status and the actions; a message within minutes
     * of the one before has no time and, with nothing else to say, no line at all. */
    GtkWidget *line = adw_wrap_box_new();
    adw_wrap_box_set_child_spacing(ADW_WRAP_BOX(line), 6);
    adw_wrap_box_set_align(ADW_WRAP_BOX(line), outgoing ? 1 : 0);
    gtk_widget_add_css_class(line, "szfriends-time-line");
    if (item->assistant_label && *item->assistant_label)
        adw_wrap_box_append(ADW_WRAP_BOX(line), szfriends_gtk_assistant_label_new(item->assistant_label));
    if (item->time_label && *item->time_label) adw_wrap_box_append(ADW_WRAP_BOX(line), gtk_label_new(item->time_label));
    if (item->status && *item->status->label) {
        GtkWidget *status = gtk_label_new(item->status->label);
        gtk_label_set_wrap(GTK_LABEL(status), TRUE);
        if (item->status->state == SZFRIENDS_GTK_MESSAGE_FAILED) gtk_widget_add_css_class(status, "szfriends-failure");
        adw_wrap_box_append(ADW_WRAP_BOX(line), status);
    }
    /* A message item's id is the message_id that cancel_message takes (PROTOCOL.md § Intents). */
    SZFriendsGtkActionIds ids = {.item_id = item->item_id, .message_id = item->item_id};
    gboolean cancels = szfriends_gtk_conversation_helper_cancels(conversation);
    for (gsize i = 0; i < item->n_actions; i++)
        if (szfriends_gtk_item_shows_action(&item->actions[i], cancels))
            adw_wrap_box_append(ADW_WRAP_BOX(line), szfriends_gtk_action_button_new(conversation, &item->actions[i],
                                                                                   &ids, NULL, NULL, NULL));
    gtk_widget_set_visible(line, gtk_widget_get_first_child(line) != NULL);
    gtk_box_append(GTK_BOX(row), line);
    return row;
}

/* ---- The link menu ---------------------------------------------------------------------------------- */

typedef struct {
    SZFriendsGtkConversation *conversation;
    char *url;
} SZFriendsGtkLinkTarget;

static void link_target_free(gpointer data) {
    SZFriendsGtkLinkTarget *target = data;
    szfriends_gtk_conversation_unref(target->conversation);
    g_free(target->url);
    g_free(target);
}

static void open_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkLinkTarget *target = data;
    GtkWidget *popover = gtk_widget_get_ancestor(GTK_WIDGET(button), GTK_TYPE_POPOVER);
    if (popover) gtk_popover_popdown(GTK_POPOVER(popover));
    szfriends_gtk_conversation_open_uri(target->conversation, target->url);
}

GtkWidget *szfriends_gtk_link_menu_new(SZFriendsGtkConversation *conversation, const char *url, const char *words) {
    SZFriendsGtkLink *link = conversation->link;
    SZFriendsGtkLinkMenuText *text = szfriends_gtk_link_menu_text(
        url, words, szfriends_gtk_link_string(link, "link_elsewhere"), szfriends_gtk_link_string(link, "link_open"),
        szfriends_gtk_link_string(link, "link_open_email"));
    GtkWidget *popover = gtk_popover_new();
    gtk_widget_add_css_class(popover, "szfriends-link-menu");
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_size_request(box, 220, -1);
    if (text->warning) {
        GtkWidget *warning = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        gtk_widget_add_css_class(warning, "szfriends-link-warning");
        GtkWidget *icon = gtk_image_new_from_icon_name("dialog-warning-symbolic");
        gtk_widget_set_valign(icon, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(warning), icon);
        GtkWidget *words_label = plain_label(text->warning, NULL);
        gtk_label_set_xalign(GTK_LABEL(words_label), 0);
        gtk_box_append(GTK_BOX(warning), words_label);
        gtk_box_append(GTK_BOX(box), warning);
    }
    SZFriendsGtkLinkTarget *target = g_new0(SZFriendsGtkLinkTarget, 1);
    target->conversation = szfriends_gtk_conversation_ref(conversation);
    target->url = g_strdup(url);
    g_object_set_data_full(G_OBJECT(popover), "szfriends-link-target", target, link_target_free);
    GtkWidget *address = plain_label(text->address, "szfriends-link-address");
    gtk_label_set_xalign(GTK_LABEL(address), 0);
    /* Without the catalog's words the address itself opens the link: views never invent text, and the destination
     * is still what the person reads and chooses. */
    GtkWidget *open = gtk_button_new();
    gtk_widget_add_css_class(open, "flat");
    gtk_widget_add_css_class(open, "szfriends-menu-item");
    if (*text->open_label) {
        gtk_box_append(GTK_BOX(box), address);
        gtk_button_set_label(GTK_BUTTON(open), text->open_label);
        gtk_widget_set_halign(gtk_button_get_child(GTK_BUTTON(open)), GTK_ALIGN_START);
    } else {
        gtk_button_set_child(GTK_BUTTON(open), address);
    }
    g_signal_connect(open, "clicked", G_CALLBACK(open_clicked), target);
    gtk_box_append(GTK_BOX(box), open);
    gtk_popover_set_child(GTK_POPOVER(popover), box);
    szfriends_gtk_link_menu_text_free(text);
    return popover;
}
