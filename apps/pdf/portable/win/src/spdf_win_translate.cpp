/* spdf_win_translate.cpp -- the PURE half of spdf_win_translate.h: the
 * language table, the Mac enablement policy, output naming, whitespace
 * collapsing, batch assembly and output distribution, the Argos command line.
 * Nothing here touches a process or a document; portable/win/tests/
 * translate_test.c drives it all. The runners are spdf_win_translate_run.cpp. */
#include "spdf_win_translate.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* GTK3 k_translation_languages / Mac spdf_translation_languages, verbatim. */
static const SpdfWinTranslationLanguage k_languages[] = {
    {"zh", "Chinese (Simplified)"}, {"en", "English"},    {"fr", "French"},     {"de", "German"},
    {"es", "Spanish"},              {"it", "Italian"},    {"pt", "Portuguese"}, {"ru", "Russian"},
    {"ja", "Japanese"},             {"ko", "Korean"},     {"ar", "Arabic"},     {"hi", "Hindi"},
    {"nl", "Dutch"},                {"pl", "Polish"},     {"tr", "Turkish"},    {"vi", "Vietnamese"},
    {"id", "Indonesian"},           {"uk", "Ukrainian"},  {"cs", "Czech"},
};
#define LANGUAGE_COUNT ((int)(sizeof(k_languages) / sizeof(k_languages[0])))

const SpdfWinTranslationLanguage* spdf_win_translation_languages(int* count) {
    if (count) *count = LANGUAGE_COUNT;
    return k_languages;
}

int spdf_win_translation_language_index(const char* code) {
    if (!code || !*code) return -1;
    for (int i = 0; i < LANGUAGE_COUNT; ++i)
        if (strcmp(k_languages[i].code, code) == 0) return i;
    return -1;
}

/* --- policy (SPDFMacTranslationPolicy.mm) ----------------------------------- */

static int idle(SpdfWinTranslationContext c) { return !c.translation_running && !c.install_running; }

int spdf_win_translation_selection_enabled(SpdfWinTranslationContext c) {
    if (!c.has_selection) return 0;
    if (!c.markdown_active && !c.pdf_document_open) return 0;
    return idle(c);
}

int spdf_win_translation_whole_document_available(SpdfWinTranslationContext c) {
    return c.pdf_document_open && !c.markdown_active;
}

int spdf_win_translation_command_enabled(SpdfWinTranslationContext c) {
    if (spdf_win_translation_selection_enabled(c)) return 1;
    return spdf_win_translation_whole_document_available(c) && idle(c);
}

/* --- naming ------------------------------------------------------------------- */

const char* spdf_win_translate_suffix_for_language(const char* target_language) {
    if (!target_language || !*target_language) return "translated";
    if (strcmp(target_language, "en") == 0) return "english";
    return target_language;
}

static void split_leaf(const char* path, size_t* dir_len, const char** leaf) {
    const char* a = strrchr(path, '\\');
    const char* b = strrchr(path, '/');
    const char* sep = a > b ? a : b;
    *leaf = sep ? sep + 1 : path;
    *dir_len = sep ? (size_t)(sep - path + 1) : 0;
}

int spdf_win_translate_output_path(const char* path, const char* target_language, char* out, size_t out_bytes) {
    size_t dir_len;
    const char* leaf;
    const char* dot;
    int stem_len, n;
    if (!path || !*path) return 0;
    split_leaf(path, &dir_len, &leaf);
    dot = strrchr(leaf, '.');
    stem_len = dot ? (int)(dot - leaf) : (int)strlen(leaf);
    n = snprintf(out, out_bytes, "%.*s%.*s_%s.pdf", (int)dir_len, path, stem_len, leaf,
                 spdf_win_translate_suffix_for_language(target_language));
    return n > 0 && (size_t)n < out_bytes;
}

int spdf_win_translate_temp_path(const char* path, unsigned nonce, char* out, size_t out_bytes) {
    size_t dir_len;
    const char* leaf;
    int n;
    if (!path || !*path) return 0;
    split_leaf(path, &dir_len, &leaf);
    n = snprintf(out, out_bytes, "%.*s.%s.translate-%u.pdf", (int)dir_len, path, leaf, nonce);
    return n > 0 && (size_t)n < out_bytes;
}

size_t spdf_win_translate_collapse_whitespace(const char* text, char* out, size_t out_bytes) {
    size_t at = 0;
    int pending_space = 0;
    if (!out || !out_bytes) return 0;
    for (const char* p = text ? text : ""; *p; ++p) {
        if (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == '\f' || *p == '\v') {
            if (at) pending_space = 1;
            continue;
        }
        if (pending_space) {
            if (at + 1 < out_bytes) out[at++] = ' ';
            pending_space = 0;
        }
        if (at + 1 < out_bytes) out[at++] = *p;
    }
    out[at] = '\0';
    return at;
}

/* --- batching ------------------------------------------------------------------- */

int spdf_win_translate_batch_end(const SpdfWinTranslateBatchItem* items, int count, int start, int budget) {
    int end;
    if (!items || start < 0 || start >= count) return count;
    /* The first page group always fits, even when it alone exceeds the
     * budget -- a batch must cover whole page groups (Mac batching). */
    end = start + 1;
    while (end < count && items[end].page == items[start].page) end++;
    while (end < count && end - start < budget) {
        int next_page = items[end].page;
        int next_end = end + 1;
        while (next_end < count && items[next_end].page == next_page) next_end++;
        if (next_end - start > budget) break;
        end = next_end;
    }
    return end;
}

size_t spdf_win_translate_batch_scope(const SpdfWinTranslateBatchItem* items, int count, int start, int end,
                                      char* out, size_t out_bytes) {
    int has_outline = 0, has_comment = 0, first_page = -1, last_page = -1;
    char pages[64] = "";
    const char* extras = NULL;
    for (int i = start; i < end && i < count; ++i) {
        if (items[i].kind == 1) has_outline = 1;
        else if (items[i].kind == 2) has_comment = 1;
        else {
            if (first_page < 0) first_page = items[i].page;
            last_page = items[i].page;
        }
    }
    if (first_page >= 0) {
        if (first_page == last_page) snprintf(pages, sizeof(pages), "page %d", first_page + 1);
        else snprintf(pages, sizeof(pages), "pages %d-%d", first_page + 1, last_page + 1);
    }
    if (has_outline && has_comment) extras = "chapters and comments";
    else if (has_outline) extras = "chapter titles";
    else if (has_comment) extras = "comments";
    if (pages[0] && extras) return (size_t)snprintf(out, out_bytes, "%s and %s", pages, extras);
    if (pages[0]) return (size_t)snprintf(out, out_bytes, "%s", pages);
    return (size_t)snprintf(out, out_bytes, "%s", extras ? extras : "text");
}

static char* dup_range(const char* s, size_t n) {
    char* d = (char*)malloc(n + 1);
    if (d) {
        memcpy(d, s, n);
        d[n] = '\0';
    }
    return d;
}

void spdf_win_translate_apply_batch_output(char** result_lines, int start, int end, const char* batch_output) {
    const char* text = batch_output ? batch_output : "";
    const char* p = text;
    int local = 0;
    size_t tail_len = 0;
    char* tail = NULL;

    /* One output line per item; "" and missing lines become " " so the
     * overlay count stays aligned with the source lines. */
    for (;;) {
        const char* e = strchr(p, '\n');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        if (start + local < end) {
            free(result_lines[start + local]);
            result_lines[start + local] = n ? dup_range(p, n) : dup_range(" ", 1);
        } else if (n && end > start) {
            /* Extra output lines fold into the batch's last line, space-joined:
             * embedded newlines would shift every later overlay (78072bf55). */
            const char* last = result_lines[end - 1];
            size_t ll = tail ? tail_len : strlen(last);
            char* grown = (char*)malloc(ll + 1 + n + 1);
            if (grown) {
                memcpy(grown, tail ? tail : last, ll);
                grown[ll] = ' ';
                memcpy(grown + ll + 1, p, n);
                grown[ll + 1 + n] = '\0';
                free(tail);
                tail = grown;
                tail_len = ll + 1 + n;
            }
        }
        ++local;
        if (!e) break;
        p = e + 1;
    }
    for (int i = start + local; i < end; ++i) {
        free(result_lines[i]);
        result_lines[i] = dup_range(" ", 1);
    }
    if (tail) {
        /* A folded tail begins with the last line's own text, which may have
         * been a stand-in " " -- keep the join, drop the leading blank. */
        char* flat = tail;
        for (size_t i = 0; flat[i]; ++i)
            if (flat[i] == '\n' || flat[i] == '\r') flat[i] = ' ';
        while (*flat == ' ') ++flat;
        free(result_lines[end - 1]);
        result_lines[end - 1] = dup_range(flat, strlen(flat));
        free(tail);
    }
}

size_t spdf_win_translate_argos_cmd(const char* argos, const char* from_lang, const char* to_lang, char* out,
                                    size_t out_bytes) {
    const char* argv[5] = {argos, "--from-lang", from_lang, "--to-lang", to_lang};
    return spdf_win_toolchain_join_argv(argv, 5, out, out_bytes);
}
