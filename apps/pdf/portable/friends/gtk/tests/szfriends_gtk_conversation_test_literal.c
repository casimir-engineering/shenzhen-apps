/* friends-gtk-conversation-check, display-free: a stranger card's name shown literally (szfriends_gtk_conversation.h).
 * Every case of friends/fixtures/text/invisible-cases.json marks exactly what the AppKit card and the host's send
 * check mark; a few GTK cases go toward the send check (format characters, unassigned code points, the marks a
 * precomposed letter carries); the markers' words and look; and the Unicode tables equal mac/SZFriendsEmojiTables.m
 * range for range, so both apps judge the same characters. */

#include "szfriends_gtk_support.h"
#include "gtk/szfriends_gtk_conversation.h"

#include <string.h>

static char *marked_names(const char *text, gssize length) {
    GArray *marked = szfriends_gtk_literal_marked(text, length);
    GString *names = g_string_new(NULL);
    for (guint i = 0; i < marked->len; i++)
        g_string_append_printf(names, "%sU+%04X", i ? " " : "", (unsigned)g_array_index(marked, gunichar, i));
    g_array_unref(marked);
    return g_string_free(names, FALSE);
}

/* The cases' "text" strings decoded from the file itself, in order: json-glib hands strings over NUL-terminated, so
 * the case holding U+0000 would lose it and everything after it. */
static GPtrArray *case_texts(const char *json) {
    GPtrArray *texts = g_ptr_array_new_with_free_func((GDestroyNotify)g_bytes_unref);
    for (const char *at = strstr(json, "\"text\": \""); at; at = strstr(at, "\"text\": \"")) {
        GString *text = g_string_new(NULL);
        gunichar high = 0;
        for (at += strlen("\"text\": \""); *at && *at != '"'; at++) {
            if (*at != '\\') {
                g_string_append_c(text, *at);
                continue;
            }
            char escape = *++at;
            if (escape != 'u') {
                g_string_append_c(text, escape == 'n' ? '\n' : escape == 't' ? '\t' : escape);
                continue;
            }
            char digits[5] = {0};
            memcpy(digits, at + 1, 4);
            at += 4;
            gunichar unit = (gunichar)g_ascii_strtoull(digits, NULL, 16);
            if (unit >= 0xD800 && unit <= 0xDBFF) high = unit;
            else if (unit >= 0xDC00 && unit <= 0xDFFF)
                g_string_append_unichar(text, 0x10000 + ((high - 0xD800) << 10) + (unit - 0xDC00));
            else if (unit == 0) g_string_append_len(text, "", 1);
            else g_string_append_unichar(text, unit);
        }
        g_ptr_array_add(texts, g_string_free_to_bytes(text));
    }
    return texts;
}

static void test_shared_cases(void) {
    JsonObject *fixture = szfg_fixture("text/invisible-cases.json");
    JsonArray *cases = fixture ? json_object_get_array_member(fixture, "cases") : NULL;
    char *path = szfg_fixture_path("text/invisible-cases.json"), *json = NULL;
    GPtrArray *texts = g_file_get_contents(path, &json, NULL, NULL) ? case_texts(json) : g_ptr_array_new();
    EXPECT(cases && json_array_get_length(cases) > 40 && texts->len == json_array_get_length(cases),
           "the shared invisible-character cases, each text read whole (%u)", texts->len);
    for (guint i = 0; cases && i < json_array_get_length(cases) && i < texts->len; i++) {
        JsonObject *entry = json_array_get_object_element(cases, i);
        JsonArray *expected = json_object_get_array_member(entry, "marked");
        GString *want = g_string_new(NULL);
        for (guint m = 0; m < json_array_get_length(expected); m++)
            g_string_append_printf(want, "%s%s", m ? " " : "", json_array_get_string_element(expected, m));
        gsize length = 0;
        const char *text = g_bytes_get_data(g_ptr_array_index(texts, i), &length);
        char *got = marked_names(text, (gssize)length);
        EXPECT(strcmp(got, want->str) == 0, "%s: marks [%s], not [%s]", json_object_get_string_member(entry, "name"),
               want->str, got);
        g_free(got);
        g_string_free(want, TRUE);
    }
    g_ptr_array_unref(texts);
    g_free(json);
    g_free(path);
    if (fixture) json_object_unref(fixture);
}

static void test_gtk_cases(void) {
    static const char *const cases[][3] = {
        {"a name", "Leo Park", ""},
        {"markup-looking words are words", "<b>Leo</b> &amp;", ""},
        {"a format character the send check refuses (Arabic number sign)", "a\xD8\x80" "b", "U+0600"},
        {"an unassigned code point", "a\xCD\xB8" "b", "U+0378"},
        {"six marks on one decomposed letter: the fifth and sixth", "e\xCC\x82\xCC\xA3\xCC\x81\xCC\x80\xCC\x83\xCC\x84",
         "U+0303 U+0304"},
        {"the same on the precomposed letter, which carries two", "\xE1\xBB\x87\xCC\x81\xCC\x80\xCC\x83\xCC\x84",
         "U+0303 U+0304"},
        {"a mark the precomposed letter already carries", "\xE2\x89\xA0\xCC\xB8", "U+0338"},
        {"a mark NFC writes as one already there (U+0340 is U+0300)", "a\xCC\x80\xCD\x80", "U+0300"},
        {"marks on a precomposed letter it does not carry", "\xC3\xA9\xCC\x82", ""},
        {"a mark counts as NFC writes it, not as its parts (Tulu-Tigalari U+113C5 is U+113C2 twice)",
         "\xF0\x91\x8E\x92\xF0\x91\x8F\x85", ""},
    };
    for (gsize i = 0; i < G_N_ELEMENTS(cases); i++) {
        char *got = marked_names(cases[i][1], -1);
        EXPECT(strcmp(got, cases[i][2]) == 0, "%s: marks [%s], not [%s]", cases[i][0], cases[i][2], got);
        g_free(got);
    }
}

static gboolean attribute_covers(PangoAttrList *list, PangoAttrType type, guint start, guint end) {
    gboolean found = FALSE;
    GSList *all = pango_attr_list_get_attributes(list);
    for (GSList *a = all; a; a = a->next) {
        PangoAttribute *attribute = a->data;
        found |= attribute->klass->type == type && attribute->start_index == start && attribute->end_index == end;
    }
    g_slist_free_full(all, (GDestroyNotify)pango_attribute_destroy);
    return found;
}

static void test_shown_text(void) {
    PangoAttrList *attributes = NULL;
    GdkRGBA warning = {0.8f, 0.4f, 0.0f, 1.0f};
    char *shown = szfriends_gtk_literal_text("Leo\xE2\x80\x8B\xE2\x80\x8B\xE2\x80\x8BPark\xE2\x80\xAE", -1,
                                             &warning, &attributes);
    EXPECT(strcmp(shown, "Leo U+200B ×3 Park U+202E ") == 0,
           "a run of one hidden character reads once with its count: \"%s\"", shown);
    guint start = 3, end = (guint)strlen("Leo U+200B ×3 ");
    EXPECT(attribute_covers(attributes, PANGO_ATTR_FAMILY, start, end) &&
               attribute_covers(attributes, PANGO_ATTR_FOREGROUND, start, end) &&
               attribute_covers(attributes, PANGO_ATTR_BACKGROUND, start, end),
           "the marker is set apart from typed words: monospace, in the warning colour on its fill");
    EXPECT(!attribute_covers(attributes, PANGO_ATTR_FAMILY, 0, 3), "the name's own words keep their look");
    pango_attr_list_unref(attributes);
    g_free(shown);
    shown = szfriends_gtk_literal_text("U+200B <i>Leo</i>", -1, NULL, &attributes);
    GSList *none = pango_attr_list_get_attributes(attributes);
    EXPECT(strcmp(shown, "U+200B <i>Leo</i>") == 0 && !none,
           "typed words that look like a marker or markup stay plain words: \"%s\"", shown);
    g_slist_free_full(none, (GDestroyNotify)pango_attribute_destroy);
    pango_attr_list_unref(attributes);
    g_free(shown);
    shown = szfriends_gtk_literal_text("Le\xCC\x81o", -1, NULL, &attributes);
    EXPECT(strcmp(shown, "L\xC3\xA9o") == 0, "the card shows the composed name, as Friends delivers it: \"%s\"", shown);
    pango_attr_list_unref(attributes);
    g_free(shown);
}

/* The values of `name`'s table in the AppKit file, in order: every 0x number between its "= {" and "};". */
static GArray *appkit_table(const char *source, const char *name) {
    GArray *values = g_array_new(FALSE, FALSE, sizeof(gunichar));
    char *opening = g_strdup_printf(" %s[] = {", name);
    const char *at = strstr(source, opening), *end = at ? strstr(at, "};") : NULL;
    g_free(opening);
    for (const char *p = at; p && p < end; p++) {
        if (p[0] != '0' || p[1] != 'x') continue;
        char *after = NULL;
        gunichar value = (gunichar)g_ascii_strtoull(p + 2, &after, 16);
        g_array_append_val(values, value);
        p = after - 1;
    }
    return values;
}

static void test_tables_match_appkit(void) {
    char *friends = g_path_get_dirname(szfg_fixtures);
    char *path = g_build_filename(friends, "mac", "SZFriendsEmojiTables.m", NULL), *source = NULL;
    EXPECT(g_file_get_contents(path, &source, NULL, NULL), "the AppKit tables at %s", path);
    static const char *const names[] = {"SZFVariationBases", "SZFExtendedPictographic", "SZFDualJoining",
                                        "SZFRightJoining",   "SZFIndicConsonants",      "SZFViramas",
                                        "SZFScripts",        "SZFScriptExtensions",     "SZFScriptSets"};
    for (gsize i = 0; source && i < G_N_ELEMENTS(names); i++) {
        GArray *theirs = appkit_table(source, names[i]);
        gsize count = 0;
        const gunichar *ours = szfriends_gtk_literal_table(names[i], &count);
        gboolean same = ours && count == theirs->len && count > 0;
        for (gsize v = 0; same && v < count; v++) same = ours[v] == g_array_index(theirs, gunichar, v);
        EXPECT(same, "%s equals the AppKit table (%zu values against %u): copy it again from %s", names[i], count,
               theirs->len, path);
        g_array_unref(theirs);
    }
    EXPECT(szfriends_gtk_is_emoji_variation_base(0x2764) && !szfriends_gtk_is_emoji_variation_base(0x3042) &&
               szfriends_gtk_is_extended_pictographic(0x1F469) && szfriends_gtk_is_dual_joining(0x0645) &&
               szfriends_gtk_is_right_joining(0x0627) && szfriends_gtk_is_indic_consonant(0x0937),
           "the tables answer for the characters the shared cases use");
    /* A mark fits a letter of a script it is used with, or any letter when it belongs to no script. */
    EXPECT(szfriends_gtk_mark_fits_letter(0x0301, 'e') && szfriends_gtk_mark_fits_letter(0x064E, 0x0628) &&
               szfriends_gtk_mark_fits_letter(0x093F, 0x0915) && szfriends_gtk_mark_fits_letter(0x309A, 0x304B) &&
               szfriends_gtk_mark_fits_letter(0x0651, 0x0640) && szfriends_gtk_mark_fits_letter(0x0338, '=') &&
               szfriends_gtk_mark_fits_letter(0x20E3, '1') && szfriends_gtk_mark_fits_letter(0x0338, 0xAC00),
           "marks on letters of their scripts, and marks of no script anywhere");
    EXPECT(!szfriends_gtk_mark_fits_letter(0x3099, 0xAC00) && !szfriends_gtk_mark_fits_letter(0x309A, 0x1100) &&
               !szfriends_gtk_mark_fits_letter(0x16AF0, 0x0416) && !szfriends_gtk_mark_fits_letter(0x16AF3, 0x0628) &&
               !szfriends_gtk_mark_fits_letter(0x0301, 0xAC00) && !szfriends_gtk_mark_fits_letter(0x064E, 'a') &&
               !szfriends_gtk_mark_fits_letter(0x0301, 0xD800) && !szfriends_gtk_mark_fits_letter(0x0301, 0x10FFFD),
           "marks of another script: kana marks on Hangul, Bassa Vah tones on Cyrillic and Arabic");
    g_free(source);
    g_free(path);
    g_free(friends);
}

void szfg_run_conversation_literal_tests(void) {
    test_shared_cases();
    test_gtk_cases();
    test_shown_text();
    test_tables_match_appkit();
}
