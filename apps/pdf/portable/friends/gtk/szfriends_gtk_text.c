/* PROTOCOL.md rich text as GTK shows it: the segments' text concatenated, with a PangoAttrList for emphasis,
 * search matches and links (szfriends_gtk_actions.h). Never markup: a segment's text is someone's words, so it is
 * placed as text and styled by byte ranges, and a "<b>" a friend typed stays "<b>". */

#include "gtk/szfriends_gtk_actions.h"

#include <pango/pango.h>

char *szfriends_gtk_rich_text(const SZFriendsGtkSegment *segments, gsize count, PangoAttrList **attributes) {
    GString *text = g_string_new(NULL);
    PangoAttrList *list = attributes ? pango_attr_list_new() : NULL;
    for (gsize i = 0; i < count; i++) {
        const SZFriendsGtkSegment *segment = &segments[i];
        guint start = (guint)text->len;
        g_string_append(text, segment->text ? segment->text : "");
        guint end = (guint)text->len;
        if (!list || start == end) continue;
        PangoAttribute *attribute;
        if (segment->emphasis) {
            attribute = pango_attr_weight_new(PANGO_WEIGHT_BOLD);
            attribute->start_index = start, attribute->end_index = end;
            pango_attr_list_insert(list, attribute);
        }
        if (segment->match) {
            /* A search match reads as highlighted on any background: a translucent yellow, as text selections do. */
            attribute = pango_attr_background_new(0xffff, 0xe000, 0x5000);
            attribute->start_index = start, attribute->end_index = end;
            pango_attr_list_insert(list, attribute);
            attribute = pango_attr_background_alpha_new(0x7000);
            attribute->start_index = start, attribute->end_index = end;
            pango_attr_list_insert(list, attribute);
        }
        if (segment->url) {
            attribute = pango_attr_underline_new(PANGO_UNDERLINE_SINGLE);
            attribute->start_index = start, attribute->end_index = end;
            pango_attr_list_insert(list, attribute);
        }
    }
    if (attributes) *attributes = list;
    return g_string_free(text, FALSE);
}
