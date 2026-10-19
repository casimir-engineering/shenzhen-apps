#include "spdf_selection.h"

#include <math.h>

/* Word-boundary classification for double-click selection. CJK text carries
   no inter-word spaces, so word selection expands runs of same-class
   characters; Latin words remain the historical space-delimited tokens. */

spdf_word_char_class spdf_word_char_classify(int c) {
    if (c == 0x3000 || (c >= 0 && c <= 32) || fz_is_unicode_whitespace(c)) return SPDF_WORD_CHAR_SPACE;
    if (c >= 0x3005 && c <= 0x3007) return SPDF_WORD_CHAR_CJK; /* 々〆〇 continue Han words */
    if ((c >= 0x3001 && c <= 0x303F) ||                        /* CJK symbols and punctuation */
        (c >= 0xFE30 && c <= 0xFE4F) ||                        /* CJK compatibility forms */
        (c >= 0xFF01 && c <= 0xFF0F) || (c >= 0xFF1A && c <= 0xFF20) || /* fullwidth punctuation */
        (c >= 0xFF3B && c <= 0xFF40) || (c >= 0xFF5B && c <= 0xFF65))   /* incl. halfwidth 。「」、･ */
        return SPDF_WORD_CHAR_CJK_PUNCT;
    if ((c >= 0x1100 && c <= 0x11FF) ||   /* Hangul jamo */
        (c >= 0x2E80 && c <= 0x2FDF) ||   /* CJK/Kangxi radicals */
        (c >= 0x3040 && c <= 0x30FF) ||   /* hiragana + katakana */
        (c >= 0x3105 && c <= 0x312F) ||   /* bopomofo */
        (c >= 0x3130 && c <= 0x318F) ||   /* Hangul compatibility jamo */
        (c >= 0x31A0 && c <= 0x31BF) ||   /* bopomofo extended */
        (c >= 0x31F0 && c <= 0x31FF) ||   /* katakana phonetic extensions */
        (c >= 0x3400 && c <= 0x4DBF) ||   /* Han extension A */
        (c >= 0x4E00 && c <= 0x9FFF) ||   /* Han unified */
        (c >= 0xA960 && c <= 0xA97F) ||   /* Hangul jamo extended A */
        (c >= 0xAC00 && c <= 0xD7FF) ||   /* Hangul syllables + jamo extended B */
        (c >= 0xF900 && c <= 0xFAFF) ||   /* Han compatibility ideographs */
        (c >= 0xFF66 && c <= 0xFF9F) ||   /* halfwidth katakana */
        (c >= 0x1AFF0 && c <= 0x1B16F) || /* kana extensions */
        (c >= 0x20000 && c <= 0x3FFFF))   /* Han extensions B..H */
        return SPDF_WORD_CHAR_CJK;
    return SPDF_WORD_CHAR_OTHER;
}

int spdf_word_chars_join(int a, int b) {
    spdf_word_char_class ca = spdf_word_char_classify(a);
    spdf_word_char_class cb = spdf_word_char_classify(b);
    if (ca != cb) return 0;
    return ca == SPDF_WORD_CHAR_CJK || ca == SPDF_WORD_CHAR_OTHER;
}

static float point_distance(fz_point a, fz_point b) {
    return hypotf(b.x - a.x, b.y - a.y);
}

static void repair_collapsed_line_quads(fz_stext_line* line) {
    /* Ascent direction: 90 degrees counter-clockwise (in page terms) from the
       reading direction, expressed in y-down device space. */
    fz_point up = fz_make_point(line->dir.y, -line->dir.x);
    fz_stext_char* ch;

    for (ch = line->first_char; ch; ch = ch->next) {
        float rise = fz_max(point_distance(ch->quad.ul, ch->quad.ll), point_distance(ch->quad.ur, ch->quad.lr));
        float advance = fz_max(point_distance(ch->quad.ul, ch->quad.ur), point_distance(ch->quad.ll, ch->quad.lr));
        float asc, desc;
        if (!(ch->size > 0) || !isfinite(rise) || !isfinite(advance)) continue;
        if (rise > 0.01f * ch->size) continue;     /* already has real extent */
        if (advance <= 0.01f * ch->size) continue; /* zero advance stays flagged */
        asc = 0.8f * ch->size;
        desc = 0.2f * ch->size;
        ch->quad.ul.x += up.x * asc;
        ch->quad.ul.y += up.y * asc;
        ch->quad.ur.x += up.x * asc;
        ch->quad.ur.y += up.y * asc;
        ch->quad.ll.x -= up.x * desc;
        ch->quad.ll.y -= up.y * desc;
        ch->quad.lr.x -= up.x * desc;
        ch->quad.lr.y -= up.y * desc;
    }
}

static void repair_collapsed_block_quads(fz_stext_block* first, int depth) {
    fz_stext_block* block;
    fz_stext_line* line;

    if (depth > 64) return;
    for (block = first; block; block = block->next) {
        if (block->type == FZ_STEXT_BLOCK_STRUCT && block->u.s.down)
            repair_collapsed_block_quads(block->u.s.down->first_block, depth + 1);
        if (block->type != FZ_STEXT_BLOCK_TEXT) continue;
        for (line = block->u.t.first_line; line; line = line->next) repair_collapsed_line_quads(line);
    }
}

void spdf_selection_repair_collapsed_quads(fz_stext_page* page) {
    if (page) repair_collapsed_block_quads(page->first_block, 0);
}
