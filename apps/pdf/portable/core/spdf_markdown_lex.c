/* spdf_markdown_lex.c -- the dedicated scanners and the HTML emitter.
 *
 * Ported from portable/mac/markdown/SPDFMarkdownHighlighter.mm (JavaScript,
 * TypeScript, Swift, Python, JSON, Markdown), SPDFMarkdownLexersData.mm (YAML,
 * TOML) and SPDFMarkdownLexersMarkup.mm (HTML/XML, CSS, LaTeX). Same rule
 * order, same token classes, same single forward pass; every other catalog
 * language goes through the grammar scanner in spdf_markdown_lang.c.
 */
#include "spdf_markdown.h"

#include <ctype.h>
#include <string.h>

static int word_is(const char* code, size_t start, size_t end, const char* list) {
    size_t n = end - start;
    while (*list) {
        const char* sp = strchr(list, ' ');
        size_t m = sp ? (size_t)(sp - list) : strlen(list);
        if (m == n && memcmp(code + start, list, n) == 0) return 1;
        list += m;
        while (*list == ' ') ++list;
    }
    return 0;
}

static int is_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

#define JS_KEYWORDS                                                                                               \
    "async await break case catch class const continue debugger default delete do else export extends false "    \
    "finally for function if import in instanceof let new null of return static super switch this throw true try " \
    "typeof undefined var void while with yield"
#define TS_EXTRA                                                                                                   \
    " abstract any as asserts bigint boolean declare enum implements infer interface is keyof module namespace " \
    "never number object override private protected public readonly satisfies string symbol type unique unknown"
#define SWIFT_KEYWORDS                                                                                           \
    "associatedtype break case catch class continue convenience default defer deinit do else enum extension "   \
    "fallthrough false fileprivate final for func guard if import in init inout internal is lazy let nil open "  \
    "operator override private protocol public repeat required rethrows return self static struct subscript "  \
    "super switch throw throws true try typealias var weak where while"
#define PYTHON_KEYWORDS                                                                                        \
    "and as assert async await break class continue def del elif else except False finally for from global if " \
    "import in is lambda None nonlocal not or pass raise return True try while with yield"

/* JavaScript, TypeScript and Swift: C-like comments, quotes (Swift has no
 * template or char literal quotes but does have triple-quoted strings). */
static void scan_clike(const char* code, size_t len, const char* keywords, int swift, spdf_md_tokens* out) {
    size_t i = 0;
    while (i < len) {
        char c = code[i];
        size_t end;
        if (spdf_md_lex_matches(code, len, i, "//")) {
            end = spdf_md_lex_line(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_COMMENT);
        } else if (spdf_md_lex_matches(code, len, i, "/*")) {
            end = spdf_md_lex_until(code, len, i + 2, "*/");
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_COMMENT);
        } else if (c == '"' || (!swift && (c == '\'' || c == '`'))) {
            end = spdf_md_lex_quoted(code, len, i, c, swift);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_STRING);
        } else if (isdigit((unsigned char)c)) {
            end = spdf_md_lex_number(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_NUMBER);
        } else if (spdf_md_lex_ident_start((unsigned char)c)) {
            end = spdf_md_lex_ident(code, len, i);
            if (word_is(code, i, end, keywords)) spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEYWORD);
        } else {
            end = i + 1;
        }
        i = end;
    }
}

static int python_prefix(const char* code, size_t start, size_t end) {
    size_t n = end - start, i;
    if (!n || n > 2) return 0;
    for (i = start; i < end; ++i)
        if (!strchr("rRuUbBfF", code[i])) return 0;
    return 1;
}

static void scan_python(const char* code, size_t len, spdf_md_tokens* out) {
    size_t i = 0;
    while (i < len) {
        char c = code[i];
        size_t end;
        if (c == '#') {
            end = spdf_md_lex_line(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_COMMENT);
        } else if (c == '"' || c == '\'') {
            end = spdf_md_lex_quoted(code, len, i, c, 1);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_STRING);
        } else if (isdigit((unsigned char)c)) {
            end = spdf_md_lex_number(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_NUMBER);
        } else if (spdf_md_lex_ident_start((unsigned char)c)) {
            end = spdf_md_lex_ident(code, len, i);
            if (end < len && (code[end] == '"' || code[end] == '\'') && python_prefix(code, i, end)) {
                end = spdf_md_lex_quoted(code, len, end, code[end], 1);
                spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_STRING);
            } else if (word_is(code, i, end, PYTHON_KEYWORDS)) {
                spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEYWORD);
            }
        } else {
            end = i + 1;
        }
        i = end;
    }
}

static void scan_json(const char* code, size_t len, spdf_md_tokens* out) {
    size_t i = 0;
    while (i < len) {
        char c = code[i];
        size_t end;
        if (spdf_md_lex_matches(code, len, i, "//")) {
            end = spdf_md_lex_line(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_COMMENT);
        } else if (spdf_md_lex_matches(code, len, i, "/*")) {
            end = spdf_md_lex_until(code, len, i + 2, "*/");
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_COMMENT);
        } else if (c == '"') {
            size_t look;
            end = spdf_md_lex_quoted(code, len, i, c, 0);
            look = end;
            while (look < len && is_space(code[look])) ++look;
            spdf_md_tokens_add(out, i, end, look < len && code[look] == ':' ? SPDF_MD_TOKEN_KEY : SPDF_MD_TOKEN_STRING);
        } else if (c == '-' || isdigit((unsigned char)c)) {
            size_t start = i;
            if (c == '-' && i + 1 < len && isdigit((unsigned char)code[i + 1])) ++i;
            end = spdf_md_lex_number(code, len, i);
            if (isdigit((unsigned char)code[start]) || end > start + 1)
                spdf_md_tokens_add(out, start, end, SPDF_MD_TOKEN_NUMBER);
            if (end <= start) end = start + 1;
        } else if (spdf_md_lex_ident_start((unsigned char)c)) {
            end = spdf_md_lex_ident(code, len, i);
            if (word_is(code, i, end, "true false null")) spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEYWORD);
        } else {
            end = i + 1;
        }
        i = end;
    }
}

static void scan_markdown(const char* code, size_t len, spdf_md_tokens* out) {
    size_t i = 0;
    int line_start = 1;
    while (i < len) {
        char c = code[i];
        if (c == '\n') {
            line_start = 1;
            ++i;
            continue;
        }
        if (line_start && c == '#') {
            size_t end = i;
            while (end < len && code[end] == '#' && end - i < 6) ++end;
            if (end < len && (code[end] == ' ' || code[end] == '\t')) {
                spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_MARKUP);
                i = end;
                line_start = 0;
                continue;
            }
        }
        line_start = 0;
        if (c == '`') {
            size_t end = i + 1;
            while (end < len && code[end] != '`' && code[end] != '\n') ++end;
            if (end < len && code[end] == '`') ++end;
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_STRING);
            i = end;
        } else if ((c == '*' || c == '_' || c == '~') && i + 1 < len && code[i + 1] == c) {
            spdf_md_tokens_add(out, i, i + 2, SPDF_MD_TOKEN_MARKUP);
            i += 2;
        } else if (c == '[' || (c == '!' && i + 1 < len && code[i + 1] == '[')) {
            size_t start = i;
            if (c == '!') ++i;
            spdf_md_tokens_add(out, start, i + 1, SPDF_MD_TOKEN_KEY);
            ++i;
        } else {
            ++i;
        }
    }
}

static void scan_yaml(const char* code, size_t len, spdf_md_tokens* out) {
    size_t i = 0;
    int allow_key = 1;
    while (i < len) {
        char c = code[i];
        if (c == '\n') {
            allow_key = 1;
            ++i;
        } else if (is_space(c)) {
            ++i;
        } else if (c == '#' && (i == 0 || is_space(code[i - 1]))) {
            size_t end = spdf_md_lex_line(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_COMMENT);
            i = end;
        } else if (allow_key && spdf_md_lex_matches(code, len, i, "---") &&
                   (i + 3 == len || code[i + 3] == ' ' || code[i + 3] == '\n')) {
            spdf_md_tokens_add(out, i, i + 3, SPDF_MD_TOKEN_MARKUP);
            i += 3;
            allow_key = 0;
        } else if (allow_key && c == '-' && i + 1 < len && code[i + 1] == ' ') {
            spdf_md_tokens_add(out, i, i + 1, SPDF_MD_TOKEN_MARKUP);
            ++i; /* list marker; the item may still be a key */
        } else if (c == '"' || c == '\'') {
            size_t end = spdf_md_lex_quoted(code, len, i, c, 0);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_STRING);
            i = end;
            allow_key = 0;
        } else if (allow_key) {
            size_t cursor = i;
            while (cursor < len && code[cursor] != ':' && code[cursor] != '\n' && code[cursor] != '#') ++cursor;
            if (cursor < len && code[cursor] == ':' && (cursor + 1 == len || is_space(code[cursor + 1]))) {
                size_t key_end = cursor;
                while (key_end > i && is_space(code[key_end - 1])) --key_end;
                spdf_md_tokens_add(out, i, key_end, SPDF_MD_TOKEN_KEY);
                i = cursor + 1;
            }
            allow_key = 0; /* not a key: reprocess this position as a value */
        } else if (isdigit((unsigned char)c) || (c == '-' && i + 1 < len && isdigit((unsigned char)code[i + 1]))) {
            size_t start = i;
            size_t end;
            if (c == '-') ++i;
            end = spdf_md_lex_number(code, len, i);
            spdf_md_tokens_add(out, start, end, SPDF_MD_TOKEN_NUMBER);
            i = end > start + 1 ? end : start + 1;
        } else if (spdf_md_lex_ident_start((unsigned char)c)) {
            size_t end = spdf_md_lex_ident(code, len, i);
            char word[8];
            size_t n = end - i, k;
            if (n < sizeof(word)) {
                for (k = 0; k < n; ++k) word[k] = (char)tolower((unsigned char)code[i + k]);
                word[n] = '\0';
                if (word_is(word, 0, n, "true false null yes no on off"))
                    spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEYWORD);
            }
            i = end;
        } else {
            ++i;
        }
    }
}

static void scan_toml(const char* code, size_t len, spdf_md_tokens* out) {
    size_t i = 0;
    int line_start = 1;
    while (i < len) {
        char c = code[i];
        if (c == '\n') {
            line_start = 1;
            ++i;
            continue;
        }
        if (is_space(c)) {
            ++i;
            continue;
        }
        if (c == '#') {
            size_t end = spdf_md_lex_line(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_COMMENT);
            i = end;
        } else if (line_start && c == '[') {
            size_t end = i + 1;
            while (end < len && code[end] != '\n' && code[end] != ']') ++end;
            while (end < len && code[end] == ']') ++end;
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_MARKUP);
            i = end;
        } else if (c == '"' || c == '\'') {
            size_t end = spdf_md_lex_quoted(code, len, i, c, 1);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_STRING);
            i = end;
        } else if (line_start && spdf_md_lex_ident_start((unsigned char)c)) {
            size_t end = i + 1, look;
            while (end < len && (spdf_md_lex_ident_continue((unsigned char)code[end]) || code[end] == '-' ||
                                 code[end] == '.'))
                ++end;
            look = end;
            while (look < len && is_space(code[look])) ++look;
            if (look < len && code[look] == '=') spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEY);
            i = end;
        } else if (isdigit((unsigned char)c) || (c == '-' && i + 1 < len && isdigit((unsigned char)code[i + 1]))) {
            size_t start = i, end;
            if (c == '-') ++i;
            end = spdf_md_lex_number(code, len, i);
            spdf_md_tokens_add(out, start, end, SPDF_MD_TOKEN_NUMBER);
            i = end > start + 1 ? end : start + 1;
        } else if (spdf_md_lex_ident_start((unsigned char)c)) {
            size_t end = spdf_md_lex_ident(code, len, i);
            if (word_is(code, i, end, "true false")) spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEYWORD);
            i = end;
        } else {
            ++i;
        }
        line_start = 0;
    }
}

static size_t markup_name(const char* code, size_t len, size_t i) {
    while (i < len && (spdf_md_lex_ident_continue((unsigned char)code[i]) || code[i] == '-' || code[i] == ':')) ++i;
    return i;
}

static void scan_angle_markup(const char* code, size_t len, spdf_md_tokens* out) {
    size_t i = 0;
    while (i < len) {
        char c = code[i];
        if (c == '<' && spdf_md_lex_matches(code, len, i, "<!--")) {
            size_t end = spdf_md_lex_until(code, len, i + 4, "-->");
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_COMMENT);
            i = end;
        } else if (c == '<') {
            size_t cursor = i + 1, name_end;
            if (cursor < len && (code[cursor] == '/' || code[cursor] == '!' || code[cursor] == '?')) ++cursor;
            if (cursor >= len || !spdf_md_lex_ident_start((unsigned char)code[cursor])) {
                ++i;
                continue;
            }
            name_end = markup_name(code, len, cursor + 1);
            spdf_md_tokens_add(out, i, name_end, SPDF_MD_TOKEN_MARKUP);
            i = name_end;
            while (i < len) {
                char inner = code[i];
                if (inner == '>') {
                    spdf_md_tokens_add(out, i, i + 1, SPDF_MD_TOKEN_MARKUP);
                    ++i;
                    break;
                }
                if (inner == '"' || inner == '\'') {
                    size_t end = spdf_md_lex_quoted(code, len, i, inner, 0);
                    spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_STRING);
                    i = end;
                } else if (spdf_md_lex_ident_start((unsigned char)inner)) {
                    size_t end = markup_name(code, len, i + 1);
                    spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEY);
                    i = end;
                } else {
                    ++i;
                }
            }
        } else if (c == '&') {
            size_t cursor = i + 1, name_start;
            if (cursor < len && code[cursor] == '#') ++cursor;
            name_start = cursor;
            while (cursor < len && cursor - i < 12 && spdf_md_lex_ident_continue((unsigned char)code[cursor])) ++cursor;
            if (cursor > name_start && cursor < len && code[cursor] == ';') {
                spdf_md_tokens_add(out, i, cursor + 1, SPDF_MD_TOKEN_MARKUP);
                i = cursor + 1;
            } else {
                ++i;
            }
        } else {
            ++i;
        }
    }
}

static size_t css_word(const char* code, size_t len, size_t i) {
    ++i;
    while (i < len && (spdf_md_lex_ident_continue((unsigned char)code[i]) || code[i] == '-')) ++i;
    return i;
}

static void scan_css(const char* code, size_t len, spdf_md_tokens* out) {
    size_t i = 0;
    int depth = 0;
    while (i < len) {
        char c = code[i];
        if (spdf_md_lex_matches(code, len, i, "/*")) {
            size_t end = spdf_md_lex_until(code, len, i + 2, "*/");
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_COMMENT);
            i = end;
        } else if (c == '"' || c == '\'') {
            size_t end = spdf_md_lex_quoted(code, len, i, c, 0);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_STRING);
            i = end;
        } else if ((c == '@' || c == '!') && i + 1 < len && spdf_md_lex_ident_start((unsigned char)code[i + 1])) {
            size_t end = css_word(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEYWORD);
            i = end;
        } else if (c == '#' && i + 1 < len && spdf_md_lex_ident_continue((unsigned char)code[i + 1])) {
            size_t end = css_word(code, len, i);
            spdf_md_tokens_add(out, i, end, depth > 0 ? SPDF_MD_TOKEN_NUMBER : SPDF_MD_TOKEN_MARKUP);
            i = end;
        } else if (c == '.' && depth == 0 && i + 1 < len && spdf_md_lex_ident_start((unsigned char)code[i + 1])) {
            size_t end = css_word(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_MARKUP);
            i = end;
        } else if (isdigit((unsigned char)c)) {
            size_t end = spdf_md_lex_number(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_NUMBER);
            i = end;
        } else if (spdf_md_lex_ident_start((unsigned char)c)) {
            size_t end = css_word(code, len, i);
            if (depth == 0) {
                spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_MARKUP);
            } else {
                size_t look = end;
                while (look < len && is_space(code[look])) ++look;
                if (look < len && code[look] == ':') spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEY);
            }
            i = end;
        } else {
            if (c == '{') ++depth;
            if (c == '}' && depth > 0) --depth;
            ++i;
        }
    }
}

static void scan_latex(const char* code, size_t len, spdf_md_tokens* out) {
    size_t i = 0;
    while (i < len) {
        char c = code[i];
        if (c == '%') {
            size_t end = spdf_md_lex_line(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_COMMENT);
            i = end;
        } else if (c == '\\') {
            size_t end = i + 1;
            while (end < len && isalpha((unsigned char)code[end])) ++end;
            if (end < len && code[end] == '*') ++end;
            if (end == i + 1 && end < len) ++end; /* escaped symbol such as \% */
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEYWORD);
            i = end;
        } else if (c == '$') {
            int display = i + 1 < len && code[i + 1] == '$';
            size_t cursor = i + (display ? 2 : 1);
            while (cursor < len) {
                if (code[cursor] == '\\') {
                    cursor = cursor + 2 < len ? cursor + 2 : len;
                    continue;
                }
                if (code[cursor] == '$') {
                    cursor += display && cursor + 1 < len && code[cursor + 1] == '$' ? 2 : 1;
                    break;
                }
                ++cursor;
            }
            spdf_md_tokens_add(out, i, cursor, SPDF_MD_TOKEN_STRING);
            i = cursor;
        } else if (c == '{' || c == '}' || c == '&') {
            spdf_md_tokens_add(out, i, i + 1, SPDF_MD_TOKEN_MARKUP);
            ++i;
        } else {
            ++i;
        }
    }
}

int spdf_markdown_tokenize(const char* id, const char* code, size_t len, spdf_md_tokens* out) {
    memset(out, 0, sizeof(*out));
    if (!id || !code) return 0;
    if (strcmp(id, "plain") == 0) return 0;
    if (strcmp(id, "javascript") == 0) scan_clike(code, len, JS_KEYWORDS, 0, out);
    else if (strcmp(id, "typescript") == 0) scan_clike(code, len, JS_KEYWORDS TS_EXTRA, 0, out);
    else if (strcmp(id, "swift") == 0) scan_clike(code, len, SWIFT_KEYWORDS, 1, out);
    else if (strcmp(id, "python") == 0) scan_python(code, len, out);
    else if (strcmp(id, "json") == 0) scan_json(code, len, out);
    else if (strcmp(id, "markdown") == 0) scan_markdown(code, len, out);
    else if (strcmp(id, "yaml") == 0) scan_yaml(code, len, out);
    else if (strcmp(id, "toml") == 0) scan_toml(code, len, out);
    else if (strcmp(id, "html") == 0 || strcmp(id, "xml") == 0) scan_angle_markup(code, len, out);
    else if (strcmp(id, "css") == 0) scan_css(code, len, out);
    else if (strcmp(id, "latex") == 0) scan_latex(code, len, out);
    else if (!spdf_md_lex_grammar(id, code, len, out)) return 0;
    return 1;
}

void spdf_markdown_highlight_html(const char* id, const char* code, size_t len, spdf_md_buf* out) {
    spdf_md_tokens tokens;
    size_t i, pos = 0;

    if (!spdf_markdown_tokenize(id, code, len, &tokens) || tokens.failed) {
        spdf_md_tokens_free(&tokens);
        spdf_md_buf_escape(out, code, len);
        return;
    }
    for (i = 0; i < tokens.count; ++i) {
        const spdf_md_token* t = &tokens.items[i];
        if (t->start < pos || t->end > len) continue; /* defensive: never overlap, never overrun */
        spdf_md_buf_escape(out, code + pos, t->start - pos);
        spdf_md_buf_puts(out, "<span class=\"h");
        spdf_md_buf_putc(out, t->kind);
        spdf_md_buf_puts(out, "\">");
        spdf_md_buf_escape(out, code + t->start, t->end - t->start);
        spdf_md_buf_puts(out, "</span>");
        pos = t->end;
    }
    spdf_md_buf_escape(out, code + pos, len - pos);
    spdf_md_tokens_free(&tokens);
}
