#pragma once
#include <stdlib.h>
#include <string.h>

/* Shared multiline wildcard policy: geometry and sidebar context must agree. */
static int append_regex_text(char** buffer, size_t* length, size_t* capacity, const char* text, size_t text_len) {
    char* grown;
    size_t needed;
    size_t new_capacity;

    if (text_len == 0) return 1;
    needed = *length + text_len + 1;
    if (needed > *capacity) {
        new_capacity = *capacity ? *capacity : 64;
        while (new_capacity < needed) new_capacity *= 2;
        grown = (char*)realloc(*buffer, new_capacity);
        if (!grown) return 0;
        *buffer = grown;
        *capacity = new_capacity;
    }
    memcpy(*buffer + *length, text, text_len);
    *length += text_len;
    (*buffer)[*length] = '\0';
    return 1;
}

static int append_regex_cstr(char** buffer, size_t* length, size_t* capacity, const char* text) {
    return append_regex_text(buffer, length, capacity, text, strlen(text));
}

static int regex_rest_is_empty(const char* text) {
    return !text || !*text;
}

static char* copy_multiline_regex_pattern(const char* pattern) {
    char* out = NULL;
    size_t out_len = 0;
    size_t out_cap = 0;
    int escaped = 0;
    int in_class = 0;
    size_t i;

    if (!append_regex_text(&out, &out_len, &out_cap, "", 0)) return NULL;
    for (i = 0; pattern[i]; ++i) {
        char c = pattern[i];
        if (escaped) {
            if (!append_regex_text(&out, &out_len, &out_cap, &c, 1)) goto fail;
            escaped = 0;
            continue;
        }
        if (c == '\\') {
            if (!append_regex_text(&out, &out_len, &out_cap, &c, 1)) goto fail;
            escaped = 1;
            continue;
        }
        if (in_class) {
            if (!append_regex_text(&out, &out_len, &out_cap, &c, 1)) goto fail;
            if (c == ']') in_class = 0;
            continue;
        }
        if (c == '[') {
            in_class = 1;
            if (!append_regex_text(&out, &out_len, &out_cap, &c, 1)) goto fail;
            continue;
        }
        if (c == '.') {
            char quantifier = pattern[i + 1];
            if (quantifier == '*' || quantifier == '+') {
                int lazy = pattern[i + 2] == '?';
                const char* rest = pattern + i + (lazy ? 3 : 2);
                if (regex_rest_is_empty(rest)) {
                    const char* capped = quantifier == '*' ? "[^]{0,254}" : "[^]{1,254}";
                    if (!append_regex_cstr(&out, &out_len, &out_cap, capped)) goto fail;
                    i += lazy ? 2 : 1;
                    continue;
                }
                if (!append_regex_cstr(&out, &out_len, &out_cap, "[^]")) goto fail;
                if (!append_regex_text(&out, &out_len, &out_cap, &quantifier, 1)) goto fail;
                if (!lazy && !append_regex_cstr(&out, &out_len, &out_cap, "?")) goto fail;
                if (lazy && !append_regex_cstr(&out, &out_len, &out_cap, "?")) goto fail;
                i += lazy ? 2 : 1;
                continue;
            }
            if (!append_regex_cstr(&out, &out_len, &out_cap, "[^]")) goto fail;
            continue;
        }
        if (!append_regex_text(&out, &out_len, &out_cap, &c, 1)) goto fail;
    }
    return out;

fail:
    free(out);
    return NULL;
}

