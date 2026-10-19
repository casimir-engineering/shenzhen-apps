/* The conversation's look offscreen (szfriends_gtk_conversation_probe.h), wave 6c: incoming bubbles stand out from
 * the dark page; a live switch to dark gives mentions and the `#` picker exactly the fresh dark look; labels inside
 * buttons keep their own weight; the name that opens details carries a chevron; the `@` picker lists plain names
 * under the helper's search words; and an @ chip's words sit on the line's baseline. */

#include "szfriends_gtk_conversation_probe.h"

#include <math.h>
#include <string.h>

static SZFriendsGtkComposerView *composer_of(SZFGConv *conv) {
    return szfriends_gtk_conversation_page_state(szfg_conv_page(conv))->composer;
}

static GtkTextBuffer *buffer_of(SZFGConv *conv) {
    return gtk_text_view_get_buffer(GTK_TEXT_VIEW(szfriends_gtk_composer_get_text_view(composer_of(conv))));
}

static void type(SZFGConv *conv, const char *text) {
    for (const char *p = text; *p; p = g_utf8_next_char(p))
        gtk_text_buffer_insert_at_cursor(buffer_of(conv), p, (int)(g_utf8_next_char(p) - p));
}

static gboolean picker_shows_rows(gpointer data) {
    GtkWidget *picker = szfriends_gtk_composer_get_picker(composer_of(data));
    return picker && szfriends_gtk_picker_row_count(picker) > 0;
}

static GtkWidget *open_picker(SZFGConv *conv, const char *key) {
    type(conv, key);
    EXPECT(szfg_pump_until(picker_shows_rows, conv, 3000), "%s opens its picker", key);
    szfg_conv_layout(conv);
    return szfriends_gtk_composer_get_picker(composer_of(conv));
}

/* What GTK does on the frame after a style change: it validates the CSS of the whole window. The probe window is
 * never shown, so its frame clock never runs (GDK's macOS backend keeps an unshown surface's clock frozen), and
 * emitting its update phase is that frame. Without it, a live switch left parts of the page in the old colours in
 * the probe only, which made a picker look as if it did not restyle (UX verification, wave 6b). */
static void next_frame(SZFGConv *conv) {
    GdkFrameClock *clock = gtk_widget_get_frame_clock(conv->probe_window);
    EXPECT(clock != NULL, "the probe window has a frame clock to emulate");
    if (clock) g_signal_emit_by_name(clock, "update");
    szfg_conv_layout(conv);
}

static gboolean bounds(GtkWidget *widget, SZFGConv *conv, graphene_rect_t *box) {
    return widget && gtk_widget_compute_bounds(widget, szfg_conv_content(conv), box);
}

/* WCAG relative luminance and contrast of two 8-bit sRGB pixels. */
static double luminance(const guint8 *p) {
    double linear[3];
    for (int i = 0; i < 3; i++) {
        double c = p[i] / 255.0;
        linear[i] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

static double contrast(const guint8 *a, const guint8 *b) {
    double la = luminance(a), lb = luminance(b);
    return (MAX(la, lb) + 0.05) / (MIN(la, lb) + 0.05);
}

/* ---- Bubbles on the page ------------------------------------------------------------------------------------ */

static void test_bubble_contrast(SZFGHarness *harness, gboolean dark) {
    szfg_set_dark(dark);
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    GtkWidget *words = szfg_find_label(szfg_conv_root(conv), "Or ask @Kenji");
    GtkWidget *bubble = words ? gtk_widget_get_parent(words) : NULL;
    graphene_rect_t box;
    gboolean placed = bubble && gtk_widget_has_css_class(bubble, "szfriends-incoming") && bounds(bubble, conv, &box);
    GdkTexture *texture = szfg_render(conv->probe_window, 400, 640, dark ? "bubble-contrast-dark"
                                                                          : "bubble-contrast-light");
    SZFGPixels pixels = szfg_pixels(texture);
    /* Render pixels are twice the points: just inside the bubble's left edge, and the page just outside it. */
    int y = placed ? (int)((box.origin.y + box.size.height / 2) * 2) : 0;
    const guint8 *inside = szfg_pixel(&pixels, placed ? (int)((box.origin.x + 4) * 2) : 0, y);
    const guint8 *page = szfg_pixel(&pixels, placed ? (int)((box.origin.x - 4) * 2) : 0, y);
    double ratio = contrast(inside, page);
    /* Light keeps AppKit's #efeff1 on white (1.15:1); dark measured 1.0:1 before wave 6c, so its edge vanished. */
    EXPECT(placed && ratio >= (dark ? 1.25 : 1.1), "%s: an incoming bubble stands out from the page "
           "(#%02x%02x%02x on #%02x%02x%02x, %.2f:1)", dark ? "dark" : "light", inside[0], inside[1], inside[2],
           page[0], page[1], page[2], ratio);
    szfg_pixels_free(&pixels);
    g_object_unref(texture);
    szfg_conv_close(conv);
    szfg_set_dark(FALSE);
}

/* ---- A live switch to dark ------------------------------------------------------------------------------------ */

/* The colour drawn over the first `length` bytes of the label starting with `prefix`, as 0xRRGGBB, or 0. */
static guint32 drawn_colour(SZFGConv *conv, const char *prefix, guint length) {
    GtkWidget *label = szfg_find_label(szfg_conv_root(conv), prefix);
    PangoAttrList *attributes = label ? gtk_label_get_attributes(GTK_LABEL(label)) : NULL;
    guint32 colour = 0;
    GSList *all = attributes ? pango_attr_list_get_attributes(attributes) : NULL;
    for (GSList *a = all; a; a = a->next) {
        PangoAttribute *attribute = a->data;
        if (attribute->klass->type != PANGO_ATTR_FOREGROUND || attribute->start_index != 0 ||
            attribute->end_index != length)
            continue;
        PangoColor c = ((PangoAttrColor *)attribute)->color;
        colour = (guint32)(c.red >> 8) << 16 | (guint32)(c.green >> 8) << 8 | (c.blue >> 8);
    }
    g_slist_free_full(all, (GDestroyNotify)pango_attribute_destroy);
    return colour;
}

typedef struct {
    guint32 mention;
    guint8 panel[3], entry[3], selected[3];
} SZFGDarkLook;

static void copy_pixel(guint8 *to, const SZFGPixels *pixels, double x, double y) {
    memcpy(to, szfg_pixel(pixels, (int)(x * 2), (int)(y * 2)), 3);
}

/* The mention's colour, and the `#` picker's panel, search field and chosen row where nothing is written. */
static SZFGDarkLook dark_look(SZFGConv *conv, const char *name) {
    SZFGDarkLook look = {drawn_colour(conv, "@Leo Park can review", strlen("@Leo Park")), {0}, {0}, {0}};
    GtkWidget *picker = szfriends_gtk_composer_get_picker(composer_of(conv));
    GtkWidget *entry = picker ? gtk_widget_get_first_child(picker) : NULL;
    GtkWidget *rows = entry ? gtk_widget_get_next_sibling(entry) : NULL;
    graphene_rect_t panel_box, entry_box, row_box;
    gboolean placed = bounds(picker, conv, &panel_box) && bounds(entry, conv, &entry_box) &&
                      bounds(rows ? gtk_widget_get_first_child(rows) : NULL, conv, &row_box);
    EXPECT(placed, "%s: the # picker is laid out", name);
    GdkTexture *texture = szfg_render(conv->probe_window, 400, 640, name);
    SZFGPixels pixels = szfg_pixels(texture);
    if (placed) {
        copy_pixel(look.panel, &pixels, panel_box.origin.x + panel_box.size.width / 2,
                   panel_box.origin.y + panel_box.size.height - 3);
        copy_pixel(look.entry, &pixels, entry_box.origin.x + entry_box.size.width - 8,
                   entry_box.origin.y + entry_box.size.height / 2);
        copy_pixel(look.selected, &pixels, row_box.origin.x + row_box.size.width - 8,
                   row_box.origin.y + row_box.size.height / 2);
    }
    szfg_pixels_free(&pixels);
    g_object_unref(texture);
    return look;
}

static gboolean same_pixel(const guint8 *a, const guint8 *b) {
    return ABS(a[0] - b[0]) + ABS(a[1] - b[1]) + ABS(a[2] - b[2]) <= 6;
}

static void test_live_switch(SZFGHarness *harness) {
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    guint32 light = drawn_colour(conv, "@Leo Park can review", strlen("@Leo Park"));
    open_picker(conv, "#");
    szfg_set_dark(TRUE); /* the switch, with the page and its picker open */
    next_frame(conv);
    SZFGDarkLook live = dark_look(conv, "live-switch-dark");
    szfg_conv_close(conv);
    conv = szfg_conv_open(harness, "c_daniel");
    open_picker(conv, "#");
    SZFGDarkLook fresh = dark_look(conv, "fresh-dark");
    szfg_conv_close(conv);
    szfg_set_dark(FALSE);
    EXPECT(light && fresh.mention && fresh.mention != light, "dark mentions take the dark accent (#%06x, light #%06x)",
           fresh.mention, light);
    EXPECT(live.mention == fresh.mention, "after a live switch, mentions take the dark accent too (#%06x, fresh "
           "#%06x): read once the dark stylesheet is in, not inside notify::dark", live.mention, fresh.mention);
    EXPECT(same_pixel(live.panel, fresh.panel) && same_pixel(live.entry, fresh.entry) &&
               same_pixel(live.selected, fresh.selected),
           "the # picker open across the switch looks as one opened in dark: panel #%02x%02x%02x (#%02x%02x%02x), "
           "field #%02x%02x%02x (#%02x%02x%02x), chosen row #%02x%02x%02x (#%02x%02x%02x)", live.panel[0],
           live.panel[1], live.panel[2], fresh.panel[0], fresh.panel[1], fresh.panel[2], live.entry[0], live.entry[1],
           live.entry[2], fresh.entry[0], fresh.entry[1], fresh.entry[2], live.selected[0], live.selected[1],
           live.selected[2], fresh.selected[0], fresh.selected[1], fresh.selected[2]);
}

/* ---- Weights, the chevron and the `@` picker's words ----------------------------------------------------- */

static int weight_of(GtkWidget *label) {
    const PangoFontDescription *font = label ? pango_context_get_font_description(gtk_widget_get_pango_context(label))
                                             : NULL;
    return font ? (int)pango_font_description_get_weight(font) : -1;
}

static GtkWidget *find_type(GtkWidget *root, GType type) {
    if (!root || G_TYPE_CHECK_INSTANCE_TYPE(root, type)) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = find_type(child, type);
        if (found) return found;
    }
    return NULL;
}

static void test_weights_and_header(SZFGHarness *harness) {
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    GtkWidget *title = szfriends_gtk_conversation_page_part(szfg_conv_page(conv), "title");
    GtkWidget *name = szfg_find_label(title, "Daniel Ortiz"), *route = szfg_find_label(title, "Nearby");
    EXPECT(GTK_IS_BUTTON(title) && weight_of(name) == 600 && weight_of(route) == 400,
           "the header's name keeps 600 and its route line reads regular inside the button (%d, %d)",
           weight_of(name), weight_of(route));
    GtkWidget *chevron = find_type(title, GTK_TYPE_DRAWING_AREA);
    graphene_rect_t name_box, chevron_box;
    EXPECT(chevron && gtk_widget_has_css_class(chevron, "szfriends-header-chevron") && bounds(name, conv, &name_box) &&
               bounds(chevron, conv, &chevron_box) &&
               chevron_box.origin.x >= name_box.origin.x + name_box.size.width &&
               chevron_box.origin.x < name_box.origin.x + name_box.size.width + 8,
           "a chevron follows the name that opens details, as in AppKit");
    GtkWidget *picker = open_picker(conv, "#");
    EXPECT(weight_of(szfg_find_label(picker, "Selected in Downloads")) == 400 &&
               weight_of(szfg_find_label(picker, "Site photos.pdf")) == 600,
           "a # picker row: the detail regular under its 600 title (%d, %d)",
           weight_of(szfg_find_label(picker, "Selected in Downloads")),
           weight_of(szfg_find_label(picker, "Site photos.pdf")));
    szfriends_gtk_picker_key(picker, GDK_KEY_Return);
    szfg_conv_layout(conv);
    GtkWidget *chip = szfg_find_label(szfriends_gtk_composer_get_chips(composer_of(conv)), "Site photos.pdf");
    EXPECT(chip && weight_of(chip) == 400, "an attachment chip reads regular, as AppKit's (%d)", weight_of(chip));
    szfg_conv_render(conv, "composer-chip-weights-light");
    GtkWidget *menu = szfriends_gtk_link_menu_new(szfriends_gtk_conversation_page_state(szfg_conv_page(conv)),
                                                  "https://example.com/plan", "the plan");
    GtkWidget *content = g_object_ref(gtk_popover_get_child(GTK_POPOVER(menu)));
    gtk_popover_set_child(GTK_POPOVER(menu), NULL);
    GtkWidget *window = szfg_probe_window(content);
    szfg_layout(window, 240, -1);
    GtkWidget *open = szfg_find_button(content, "Open in Browser");
    int open_weight = open ? weight_of(gtk_button_get_child(GTK_BUTTON(open))) : -1;
    EXPECT(open_weight == 400, "the link menu's item reads as a menu item, regular (%d)", open_weight);
    gtk_window_destroy(GTK_WINDOW(window));
    g_object_unref(content);
    g_object_ref_sink(menu);
    g_object_unref(menu);
    szfg_conv_close(conv);
    conv = szfg_conv_open(harness, "c_lena");
    title = szfriends_gtk_conversation_page_part(szfg_conv_page(conv), "title");
    EXPECT(!GTK_IS_BUTTON(title) && !find_type(title, GTK_TYPE_DRAWING_AREA),
           "a name that opens nothing has no chevron");
    szfg_conv_close(conv);
}

/* ---- The `@` picker and its chip ------------------------------------------------------------------------- */

static char *mentionable_list(void) {
    JsonObject *frame = szfg_fixture("snapshots/list.json");
    JsonObject *data = json_object_get_object_member(frame, "data");
    JsonArray *rows = json_object_get_array_member(data, "rows");
    for (guint i = 0; i < json_array_get_length(rows); i++) {
        JsonObject *row = json_array_get_object_element(rows, i);
        const char *id = json_object_get_string_member(row, "conversation_id");
        json_object_set_boolean_member(row, "mentionable", !strcmp(id, "c_mei") || !strcmp(id, "c_priya"));
    }
    JsonNode *root = json_node_init_object(json_node_alloc(), data);
    char *json = json_to_string(root, FALSE);
    json_node_unref(root);
    json_object_unref(frame);
    return json;
}

/* The baseline of the words around the chip, in buffer coordinates: the bottom of the line's box less the descent
 * of the text view's font for those words. */
static int line_baseline(GtkTextView *view, GtkTextIter *at, const char *words) {
    GdkRectangle rect;
    gtk_text_view_get_iter_location(view, at, &rect);
    PangoLayout *layout = gtk_widget_create_pango_layout(GTK_WIDGET(view), words);
    PangoRectangle logical;
    pango_layout_line_get_extents(pango_layout_get_line_readonly(layout, 0), NULL, &logical);
    g_object_unref(layout);
    return rect.y + rect.height - PANGO_PIXELS(logical.y + logical.height);
}

static void test_mention_picker_and_chip(SZFGHarness *harness) {
    char *list = mentionable_list();
    szfriends_fake_helper_set_view_data(harness->fake, "list", list);
    g_free(list);
    SZFGConv *conv = szfg_conv_open(harness, "c_daniel");
    type(conv, "Ask ");
    GtkWidget *picker = open_picker(conv, "@"), *entry = picker ? gtk_widget_get_first_child(picker) : NULL;
    char *placeholder = NULL;
    if (entry) g_object_get(entry, "placeholder-text", &placeholder, NULL);
    EXPECT(g_strcmp0(placeholder, "Search names and IDs") == 0, "the @ picker's field says what it searches, in the "
           "helper's words (%s)", placeholder ? placeholder : "(none)");
    g_free(placeholder);
    EXPECT(szfg_find_label(picker, "Priya Raman") && !szfg_find_label(picker, "@"),
           "its rows are plain names, as AppKit's; the @ goes on the chip");
    szfriends_gtk_picker_key(picker, GDK_KEY_Down);
    szfriends_gtk_picker_key(picker, GDK_KEY_Return); /* Priya, second in the list's order */
    type(conv, "has it");
    szfg_conv_layout(conv);
    szfg_conv_render(conv, "composer-chip-baseline-light");
    GtkTextView *view = GTK_TEXT_VIEW(szfriends_gtk_composer_get_text_view(composer_of(conv)));
    GtkTextIter iter;
    gtk_text_buffer_get_start_iter(buffer_of(conv), &iter);
    while (!gtk_text_iter_get_child_anchor(&iter) && gtk_text_iter_forward_char(&iter)) continue;
    GtkTextChildAnchor *anchor = gtk_text_iter_get_child_anchor(&iter);
    guint n_widgets = 0;
    GtkWidget **widgets = anchor ? gtk_text_child_anchor_get_widgets(anchor, &n_widgets) : NULL;
    GtkWidget *words = n_widgets ? find_type(widgets[0], GTK_TYPE_LABEL) : NULL;
    g_free(widgets);
    EXPECT(words && strcmp(gtk_label_get_text(GTK_LABEL(words)), "@Priya Raman") == 0,
           "the chip shows @ and the name");
    char *problem = words ? gtk_test_accessible_check_property(GTK_ACCESSIBLE(words), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                                                "@Priya Raman") : g_strdup("no chip");
    EXPECT(!problem, "and its accessible name is the same (%s)", problem ? problem : "");
    g_free(problem);
    /* The chip's baseline in the text view's buffer, against the baseline of "has it" after it. */
    int ox = 0, oy = 0;
    if (words) gtk_label_get_layout_offsets(GTK_LABEL(words), &ox, &oy);
    double chip_y = words ? oy + pango_layout_get_baseline(gtk_label_get_layout(GTK_LABEL(words))) / PANGO_SCALE : 0;
    graphene_point_t in_view;
    int bx = 0, by = 0;
    gboolean mapped = words && gtk_widget_compute_point(words, GTK_WIDGET(view), &GRAPHENE_POINT_INIT(0, chip_y),
                                                        &in_view);
    if (mapped)
        gtk_text_view_window_to_buffer_coords(view, GTK_TEXT_WINDOW_WIDGET, (int)in_view.x, (int)lround(in_view.y),
                                              &bx, &by);
    gtk_text_iter_forward_chars(&iter, 2); /* past the chip and its space: "has it" */
    int baseline = line_baseline(view, &iter, "has it");
    EXPECT(mapped && ABS(by - baseline) <= 1, "the chip's words sit on the line's baseline (chip %d, line %d)", by,
           baseline);
    szfg_conv_close(conv);
}

void szfg_run_conversation_look_probes(void) {
    SZFGHarness *harness = szfg_conv_harness("conv-look", NULL);
    test_bubble_contrast(harness, TRUE);
    test_bubble_contrast(harness, FALSE);
    test_live_switch(harness);
    test_weights_and_header(harness);
    test_mention_picker_and_chip(harness);
    szfg_harness_free(harness);
}
