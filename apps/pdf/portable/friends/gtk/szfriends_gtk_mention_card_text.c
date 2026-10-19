/* A name shown literally on a stranger's card (szfriends_gtk_conversation.h). Display-free but for Pango attributes.
 *
 * WHY: the card shows the name the sender wrote for someone the reader does not know, and it is where the reader
 * decides whether to add them. A character that draws nothing (a zero-width space or joiner, a direction override
 * that reorders what follows, a tag character, a control, the Hangul filler, a private-use character) would hide
 * what the name really is, so each shows as its code point instead. This is the GTK port of the rule in
 * mac/SZFriendsLiteralText.m, run against the same friends/fixtures/text/invisible-cases.json; its exceptions are
 * only where the character changes what its neighbours draw:
 *   - U+FE0E or U+FE0F after a base emoji-variation-sequences.txt lists, and after a keycap base (# * 0-9) only when
 *     U+20E3 follows, since "1" with a selector alone draws as "1";
 *   - U+200D between Extended_Pictographic code points, the first one's own U+FE0F (not one marked itself) or skin
 *     tone between them (UTS #51 emoji ZWJ elements: 👩🏽‍💻, 🏳️‍🌈), and in an Indic conjunct: right after a virama
 *     before a consonant of the virama's block (Sinhala ශ්‍රී), or right after such a consonant before the virama
 *     when a consonant of the block follows it (Bengali র‍্য);
 *   - U+200C where it changes a shape: between a letter that joins to the letter after it (Joining_Type D) and one
 *     that joins to the letter before it (D or R), as in Persian می‌خواهم, and right after a virama before a
 *     consonant of the virama's block (क्‌ष).
 * A combining mark is shown as its code point too when its letter already carries it or already carries four, since
 * repeats of some marks draw nothing more, and when it belongs to another script than its letter's (a Hangul
 * syllable with U+3099 draws exactly the syllable: szfriends_gtk_mark_fits_letter), though a Quranic pause or
 * annotation mark may stand on a space, as Quran text writes them ("رَيْبَ ۛ فِيهِ"). As the shared rule says, the text
 * is composed (NFC) first, as the send check composes what Friends delivers, and the card shows that composed text;
 * a letter starts out carrying the marks of its own canonical decomposition (U+1EC7 carries U+0323 and U+0302,
 * U+2260 carries U+0338), while a mark counts as NFC writes it, even one that decomposes into two (Tulu-Tigalari
 * U+113C5 is U+113C2 twice: counting its parts would mark a plain vowel). One place goes further than the AppKit
 * card, toward the send check, which refuses all of them: every other format or control character and every code
 * point GLib's Unicode does not assign (U+0600, U+0378) is marked. */

#include "gtk/szfriends_gtk_conversation.h"

#include <string.h>

/* A letter carries at most this many marks before the next one is marked: more cannot be counted by eye. */
#define SZFRIENDS_GTK_MARKS_PER_LETTER 4

static gboolean draws_nothing(gunichar c) {
    if (c == '\t' || c == '\n' || c == '\r') return FALSE;
    if (c < 0x20 || (c >= 0x7F && c <= 0x9F)) return TRUE;
    switch (c) {
    case 0x00AD: case 0x034F: case 0x061C: case 0x115F: case 0x1160: case 0x17B4: case 0x17B5: case 0x2800:
    case 0x3164: case 0xFEFF: case 0xFFA0:
        return TRUE;
    default:
        break;
    }
    if ((c >= 0x180B && c <= 0x180F) || (c >= 0x200B && c <= 0x200F) || (c >= 0x202A && c <= 0x202E) ||
        (c >= 0x2060 && c <= 0x206F) || (c >= 0xFE00 && c <= 0xFE0F) || (c >= 0xFFF0 && c <= 0xFFFC) ||
        (c >= 0x13430 && c <= 0x1343F) || (c >= 0x1BCA0 && c <= 0x1BCA3) || (c >= 0x1D173 && c <= 0x1D17A) ||
        (c >= 0xE0000 && c <= 0xE0FFF))
        return TRUE;
    GUnicodeType type = g_unichar_type(c);
    return type == G_UNICODE_FORMAT || type == G_UNICODE_CONTROL || type == G_UNICODE_UNASSIGNED ||
           type == G_UNICODE_PRIVATE_USE || type == G_UNICODE_SURROGATE;
}

static gboolean is_keycap_base(gunichar c) {
    return (c >= '0' && c <= '9') || c == '#' || c == '*';
}

static gboolean non_joiner_seen(gunichar before, gunichar after) {
    if (szfriends_gtk_is_dual_joining(before) &&
        (szfriends_gtk_is_dual_joining(after) || szfriends_gtk_is_right_joining(after)))
        return TRUE;
    gunichar low = 0, high = 0;
    return szfriends_gtk_virama_block(before, &low, &high) && after >= low && after <= high &&
           szfriends_gtk_is_indic_consonant(after);
}

/* Whether a zero-width joiner between `before` and `after` shapes an Indic conjunct (the rule above): before the
 * virama, only when a consonant of its block follows the virama (`after_next`); at a word's end there is none. */
static gboolean joiner_in_conjunct(gunichar before, gunichar after, gunichar after_next) {
    gunichar low = 0, high = 0;
    if (szfriends_gtk_virama_block(before, &low, &high))
        return after >= low && after <= high && szfriends_gtk_is_indic_consonant(after);
    return szfriends_gtk_virama_block(after, &low, &high) && before >= low && before <= high &&
           szfriends_gtk_is_indic_consonant(before) && after_next >= low && after_next <= high &&
           szfriends_gtk_is_indic_consonant(after_next);
}

static gunichar point_at(const gunichar *points, glong count, glong index) {
    return index >= 0 && index < count ? points[index] : 0;
}

/* Whether the character at `index` draws nothing and is not one of the exceptions above. */
static gboolean marked_alone(const gunichar *points, glong count, glong index) {
    gunichar c = points[index];
    if (!draws_nothing(c)) return FALSE;
    gunichar before = point_at(points, count, index - 1), after = point_at(points, count, index + 1);
    if (c == 0xFE0F || c == 0xFE0E) {
        if (is_keycap_base(before)) return after != 0x20E3;
        return !szfriends_gtk_is_emoji_variation_base(before);
    }
    if (c == 0x200D) {
        if (joiner_in_conjunct(before, after, point_at(points, count, index + 2))) return FALSE;
        glong base = index - 1;
        if (base >= 0 && points[base] == 0xFE0F) {
            if (marked_alone(points, count, base)) return TRUE; /* that selector draws nothing: so does the join */
            base--;
        } else if (base >= 0 && points[base] >= 0x1F3FB && points[base] <= 0x1F3FF) {
            base--;
        }
        return !(base >= 0 && szfriends_gtk_is_extended_pictographic(points[base]) &&
                 szfriends_gtk_is_extended_pictographic(after));
    }
    if (c == 0x200C) return !non_joiner_seen(before, after);
    return TRUE;
}

typedef struct {
    gunichar base, marks[SZFRIENDS_GTK_MARKS_PER_LETTER];
    guint count;
} SZFriendsGtkLetter;

/* Puts `mark` on the letter; FALSE (and the mark is shown) when the letter already carries it or carries four. */
static gboolean carry(SZFriendsGtkLetter *letter, gunichar mark) {
    if (letter->count == SZFRIENDS_GTK_MARKS_PER_LETTER) return FALSE;
    for (guint i = 0; i < letter->count; i++)
        if (letter->marks[i] == mark) return FALSE;
    letter->marks[letter->count++] = mark;
    return TRUE;
}

/* Whether `mark` is drawn on `letter` as its own: szfriends_gtk_mark_fits_letter, or a Quranic pause or annotation
 * mark (U+06D6-06DC, U+06DF-06E4, U+06E7-06E8, U+06EA-06ED) on a space the send check writes as U+0020. */
static gboolean mark_fits(gunichar mark, gunichar letter) {
    gboolean quranic = (mark >= 0x06D6 && mark <= 0x06DC) || (mark >= 0x06DF && mark <= 0x06E4) || mark == 0x06E7 ||
                       mark == 0x06E8 || (mark >= 0x06EA && mark <= 0x06ED);
    gboolean space = letter == ' ' || letter == 0x00A0 || letter == 0x1680 || (letter >= 0x2000 && letter <= 0x200A) ||
                     letter == 0x202F || letter == 0x205F;
    return (quranic && space) || szfriends_gtk_mark_fits_letter(mark, letter);
}

/* One flag per code point: marked alone, or a combining mark its letter already carries, that would be a fifth, or
 * that does not fit it. The letter is the last code point kept that is not a mark nor a joiner (U+0000 before the
 * first), so a marked character between a letter and its marks leaves them counting on that letter, and the virama
 * after a conjunct's joiner (র‍্য) counts on the consonant. One pass; each code point's
 * decomposition is a few code points at most. */
static gboolean *marked_flags(const gunichar *points, glong count) {
    gboolean *flags = g_new0(gboolean, MAX(count, 1));
    SZFriendsGtkLetter letter = {0, {0}, 0};
    for (glong index = 0; index < count; index++) {
        gunichar c = points[index], parts[G_UNICHAR_MAX_DECOMPOSITION_LENGTH];
        if (marked_alone(points, count, index)) {
            flags[index] = TRUE;
            continue;
        }
        if (c == 0x200D) continue;
        if (!g_unichar_ismark(c)) {
            /* A new letter, carrying the marks it is made of; nothing below U+00C0 decomposes. */
            letter.base = c, letter.count = 0;
            gsize n_parts = c < 0xC0 ? 0 : g_unichar_fully_decompose(c, FALSE, parts, G_N_ELEMENTS(parts));
            for (gsize i = 1; i < n_parts; i++)
                if (g_unichar_ismark(parts[i])) carry(&letter, parts[i]);
            continue;
        }
        if (!mark_fits(c, letter.base) || !carry(&letter, c)) flags[index] = TRUE;
    }
    return flags;
}

/* The code points of `length` bytes (-1: up to the NUL), U+0000 included, with U+FFFD for a byte that is not UTF-8. */
static gunichar *code_points(const char *text, gssize length, glong *count) {
    const char *p = text ? text : "", *end = p + (length < 0 ? (gssize)strlen(p) : length);
    GArray *points = g_array_new(FALSE, FALSE, sizeof(gunichar));
    while (p < end) {
        gunichar c = 0;
        if (*p == '\0') {
            p++;
        } else {
            c = g_utf8_get_char_validated(p, end - p);
            if (c == (gunichar)-1 || c == (gunichar)-2) c = 0xFFFD, p++;
            else p = g_utf8_next_char(p);
        }
        g_array_append_val(points, c);
    }
    *count = (glong)points->len;
    return (gunichar *)(void *)g_array_free(points, FALSE);
}

/* The composed (NFC) code points, as the send check composes what Friends delivers. GLib's normalizer stops at a
 * NUL, so each run between NULs is composed on its own and the NULs kept, to be marked. */
static gunichar *composed_points(const char *text, gssize length, glong *count) {
    glong n = 0;
    gunichar *raw = code_points(text, length, &n);
    GArray *out = g_array_new(FALSE, FALSE, sizeof(gunichar));
    for (glong start = 0, i = 0; i <= n; i++) {
        if (i < n && raw[i] != 0) continue;
        char *run = i > start ? g_ucs4_to_utf8(raw + start, i - start, NULL, NULL, NULL) : NULL;
        char *nfc = run ? g_utf8_normalize(run, -1, G_NORMALIZE_NFC) : NULL;
        glong m = 0;
        gunichar *composed = nfc ? g_utf8_to_ucs4_fast(nfc, -1, &m) : NULL;
        if (composed) g_array_append_vals(out, composed, (guint)m);
        else if (i > start) g_array_append_vals(out, raw + start, (guint)(i - start));
        g_free(composed);
        g_free(nfc);
        g_free(run);
        if (i < n) g_array_append_val(out, raw[i]);
        start = i + 1;
    }
    g_free(raw);
    *count = (glong)out->len;
    return (gunichar *)(void *)g_array_free(out, FALSE);
}

GArray *szfriends_gtk_literal_marked(const char *text, gssize length) {
    glong count = 0;
    gunichar *points = composed_points(text, length, &count);
    gboolean *flags = marked_flags(points, count);
    GArray *marked = g_array_new(FALSE, FALSE, sizeof(gunichar));
    for (glong i = 0; i < count; i++)
        if (flags[i]) g_array_append_val(marked, points[i]);
    g_free(flags);
    g_free(points);
    return marked;
}

static void insert(PangoAttrList *list, PangoAttribute *attribute, guint start, guint end) {
    attribute->start_index = start, attribute->end_index = end;
    pango_attr_list_insert(list, attribute);
}

static guint16 channel(float value) {
    return (guint16)(CLAMP(value, 0.f, 1.f) * 65535.f);
}

char *szfriends_gtk_literal_text(const char *text, gssize length, const GdkRGBA *mark, PangoAttrList **attributes) {
    glong count = 0;
    gunichar *points = composed_points(text, length, &count);
    gboolean *flags = marked_flags(points, count);
    GString *shown = g_string_new(NULL);
    PangoAttrList *list = pango_attr_list_new();
    for (glong index = 0; index < count;) {
        if (!flags[index]) {
            g_string_append_unichar(shown, points[index++]);
            continue;
        }
        /* One marker for a run of hidden characters, each code point once with its repeat count: forty zero-width
         * spaces read as "U+200B ×40", not as a wall of markers. */
        guint start = (guint)shown->len;
        g_string_append_c(shown, ' ');
        while (index < count && flags[index]) {
            gunichar c = points[index];
            guint repeats = 0;
            for (; index < count && flags[index] && points[index] == c; index++) repeats++;
            g_string_append_printf(shown, "U+%04X", (unsigned)c);
            if (repeats > 1) g_string_append_printf(shown, " ×%u", repeats);
            g_string_append_c(shown, ' ');
        }
        /* Set apart from words the sender could have typed ("U+200B" in a name): a monospace face, and the
         * warning colour on a faint fill of it, as the AppKit card draws its markers. */
        guint end = (guint)shown->len;
        insert(list, pango_attr_family_new("monospace"), start, end);
        insert(list, pango_attr_scale_new(0.85), start, end);
        insert(list, pango_attr_weight_new(PANGO_WEIGHT_MEDIUM), start, end);
        if (mark) {
            guint16 r = channel(mark->red), g = channel(mark->green), b = channel(mark->blue);
            insert(list, pango_attr_foreground_new(r, g, b), start, end);
            insert(list, pango_attr_background_new(r, g, b), start, end);
            insert(list, pango_attr_background_alpha_new(0x2400), start, end);
        }
    }
    g_free(flags);
    g_free(points);
    *attributes = list;
    return g_string_free(shown, FALSE);
}
