/* Strict YAML subset codec + JSON bridge for ShenzhenPDF state files.
 * See spdf_yaml.h for the supported subset and the emit guarantees. */

#include "spdf_yaml.h"

#include "spdf_win_compat.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SPDF_YAML_MAX_DEPTH 128

/* ---------------------------------------------------------------- values */

typedef enum {
    SPDF_NODE_NULL,
    SPDF_NODE_BOOL,
    SPDF_NODE_NUMBER, /* verbatim JSON number token, so round-trips are byte-stable */
    SPDF_NODE_STRING, /* decoded UTF-8 */
    SPDF_NODE_MAP,
    SPDF_NODE_SEQ,
} spdf_node_kind;

typedef struct spdf_node {
    spdf_node_kind kind;
    int bool_value;
    char* scalar;             /* NUMBER token or STRING bytes */
    char** keys;              /* MAP only, decoded UTF-8 */
    struct spdf_node** items; /* MAP values or SEQ items */
    size_t count;
    size_t capacity;
} spdf_node;

static spdf_node* node_new(spdf_node_kind kind) {
    spdf_node* node = (spdf_node*)calloc(1, sizeof(spdf_node));
    if (node) node->kind = kind;
    return node;
}

static void node_free(spdf_node* node) {
    if (!node) return;
    for (size_t i = 0; i < node->count; i++) {
        if (node->keys) free(node->keys[i]);
        node_free(node->items ? node->items[i] : NULL);
    }
    free(node->keys);
    free(node->items);
    free(node->scalar);
    free(node);
}

static int node_reserve(spdf_node* node, size_t extra) {
    size_t want = node->count + extra;
    if (want <= node->capacity) return 1;
    size_t capacity = node->capacity ? node->capacity * 2 : 8;
    while (capacity < want) capacity *= 2;
    spdf_node** items = (spdf_node**)realloc(node->items, capacity * sizeof(*items));
    if (!items) return 0;
    node->items = items;
    if (node->kind == SPDF_NODE_MAP) {
        char** keys = (char**)realloc(node->keys, capacity * sizeof(*keys));
        if (!keys) return 0;
        node->keys = keys;
    }
    node->capacity = capacity;
    return 1;
}

/* Takes ownership of key (may be NULL for sequences) and value. */
static int node_append(spdf_node* node, char* key, spdf_node* value) {
    if (!node || !value || !node_reserve(node, 1)) {
        free(key);
        node_free(value);
        return 0;
    }
    if (node->keys) node->keys[node->count] = key;
    node->items[node->count] = value;
    node->count++;
    return 1;
}

/* ---------------------------------------------------------------- buffer */

typedef struct {
    char* data;
    size_t len;
    size_t capacity;
    int oom;
} spdf_buf;

static void buf_append_len(spdf_buf* buf, const char* text, size_t len) {
    if (buf->oom) return;
    if (buf->len + len + 1 > buf->capacity) {
        size_t capacity = buf->capacity ? buf->capacity * 2 : 256;
        while (capacity < buf->len + len + 1) capacity *= 2;
        char* data = (char*)realloc(buf->data, capacity);
        if (!data) {
            buf->oom = 1;
            return;
        }
        buf->data = data;
        buf->capacity = capacity;
    }
    memcpy(buf->data + buf->len, text, len);
    buf->len += len;
    buf->data[buf->len] = 0;
}

static void buf_append(spdf_buf* buf, const char* text) {
    buf_append_len(buf, text, strlen(text));
}

static void buf_append_char(spdf_buf* buf, char c) {
    buf_append_len(buf, &c, 1);
}

static char* buf_take(spdf_buf* buf) {
    if (buf->oom) {
        free(buf->data);
        return NULL;
    }
    if (!buf->data) return spdf_compat_strdup("");
    return buf->data;
}

/* --------------------------------------------------------- shared scalars */

/* JSON number grammar: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)? */
static int is_json_number_token(const char* text, size_t len) {
    const char* p = text;
    const char* end = text + len;
    if (p < end && *p == '-') p++;
    if (p >= end || !isdigit((unsigned char)*p)) return 0;
    if (*p == '0') {
        p++;
    } else {
        while (p < end && isdigit((unsigned char)*p)) p++;
    }
    if (p < end && *p == '.') {
        p++;
        if (p >= end || !isdigit((unsigned char)*p)) return 0;
        while (p < end && isdigit((unsigned char)*p)) p++;
    }
    if (p < end && (*p == 'e' || *p == 'E')) {
        p++;
        if (p < end && (*p == '+' || *p == '-')) p++;
        if (p >= end || !isdigit((unsigned char)*p)) return 0;
        while (p < end && isdigit((unsigned char)*p)) p++;
    }
    return p == end;
}

static void append_utf8_codepoint(spdf_buf* buf, unsigned long cp) {
    char bytes[4];
    if (cp < 0x80) {
        bytes[0] = (char)cp;
        buf_append_len(buf, bytes, 1);
    } else if (cp < 0x800) {
        bytes[0] = (char)(0xc0 | (cp >> 6));
        bytes[1] = (char)(0x80 | (cp & 0x3f));
        buf_append_len(buf, bytes, 2);
    } else if (cp < 0x10000) {
        bytes[0] = (char)(0xe0 | (cp >> 12));
        bytes[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
        bytes[2] = (char)(0x80 | (cp & 0x3f));
        buf_append_len(buf, bytes, 3);
    } else {
        bytes[0] = (char)(0xf0 | (cp >> 18));
        bytes[1] = (char)(0x80 | ((cp >> 12) & 0x3f));
        bytes[2] = (char)(0x80 | ((cp >> 6) & 0x3f));
        bytes[3] = (char)(0x80 | (cp & 0x3f));
        buf_append_len(buf, bytes, 4);
    }
}

static int parse_hex4(const char* p, unsigned* out) {
    unsigned value = 0;
    for (int i = 0; i < 4; i++) {
        char c = p[i];
        value <<= 4;
        if (c >= '0' && c <= '9')
            value |= (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f')
            value |= (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F')
            value |= (unsigned)(c - 'A' + 10);
        else
            return 0;
    }
    *out = value;
    return 1;
}

/* Decode the escapes shared by JSON strings and YAML double-quoted scalars.
 * *cursor points just past the opening quote; on success it points just past
 * the closing quote. */
static char* decode_double_quoted(const char** cursor) {
    const char* p = *cursor;
    spdf_buf out = {0};
    while (*p && *p != '"') {
        if ((unsigned char)*p < 0x20) {
            free(out.data);
            return NULL; /* raw control chars (incl. newline) must be escaped */
        }
        if (*p != '\\') {
            buf_append_char(&out, *p++);
            continue;
        }
        p++;
        switch (*p) {
            case '"':
                buf_append_char(&out, '"');
                p++;
                break;
            case '\\':
                buf_append_char(&out, '\\');
                p++;
                break;
            case '/':
                buf_append_char(&out, '/');
                p++;
                break;
            case 'b':
                buf_append_char(&out, '\b');
                p++;
                break;
            case 'f':
                buf_append_char(&out, '\f');
                p++;
                break;
            case 'n':
                buf_append_char(&out, '\n');
                p++;
                break;
            case 'r':
                buf_append_char(&out, '\r');
                p++;
                break;
            case 't':
                buf_append_char(&out, '\t');
                p++;
                break;
            case 'u': {
                unsigned unit = 0;
                p++;
                if (!parse_hex4(p, &unit)) {
                    free(out.data);
                    return NULL;
                }
                p += 4;
                unsigned long cp = unit;
                if (unit >= 0xd800 && unit <= 0xdbff) {
                    unsigned low = 0;
                    if (p[0] != '\\' || p[1] != 'u' || !parse_hex4(p + 2, &low) || low < 0xdc00 || low > 0xdfff) {
                        free(out.data);
                        return NULL;
                    }
                    p += 6;
                    cp = 0x10000 + (((unsigned long)unit - 0xd800) << 10) + (low - 0xdc00);
                } else if (unit >= 0xdc00 && unit <= 0xdfff) {
                    free(out.data);
                    return NULL;
                }
                append_utf8_codepoint(&out, cp);
                break;
            }
            default:
                free(out.data);
                return NULL;
        }
    }
    if (*p != '"') {
        free(out.data);
        return NULL;
    }
    *cursor = p + 1;
    return buf_take(&out);
}

/* Shared by the JSON and YAML emitters: escapes ", \, and control characters;
 * UTF-8 passes through raw so paths stay readable. */
static void emit_quoted_string(spdf_buf* out, const char* text) {
    buf_append_char(out, '"');
    for (const unsigned char* p = (const unsigned char*)text; *p; p++) {
        switch (*p) {
            case '"':
                buf_append(out, "\\\"");
                break;
            case '\\':
                buf_append(out, "\\\\");
                break;
            case '\b':
                buf_append(out, "\\b");
                break;
            case '\f':
                buf_append(out, "\\f");
                break;
            case '\n':
                buf_append(out, "\\n");
                break;
            case '\r':
                buf_append(out, "\\r");
                break;
            case '\t':
                buf_append(out, "\\t");
                break;
            default:
                if (*p < 0x20) {
                    char esc[8];
                    snprintf(esc, sizeof(esc), "\\u%04x", (unsigned)*p);
                    buf_append(out, esc);
                } else {
                    buf_append_char(out, (char)*p);
                }
        }
    }
    buf_append_char(out, '"');
}

/* ------------------------------------------------------------ JSON parse */

typedef struct {
    const char* p;
    int depth;
} json_parser;

static void json_skip_ws(json_parser* jp) {
    while (*jp->p == ' ' || *jp->p == '\t' || *jp->p == '\n' || *jp->p == '\r') jp->p++;
}

static spdf_node* json_parse_value(json_parser* jp);

static spdf_node* json_parse_object(json_parser* jp) {
    spdf_node* map = node_new(SPDF_NODE_MAP);
    if (!map) return NULL;
    jp->p++; /* { */
    json_skip_ws(jp);
    if (*jp->p == '}') {
        jp->p++;
        return map;
    }
    for (;;) {
        json_skip_ws(jp);
        if (*jp->p != '"') goto fail;
        jp->p++;
        char* key = decode_double_quoted(&jp->p);
        if (!key) goto fail;
        json_skip_ws(jp);
        if (*jp->p != ':') {
            free(key);
            goto fail;
        }
        jp->p++;
        spdf_node* value = json_parse_value(jp);
        if (!value) {
            free(key);
            goto fail;
        }
        if (!node_append(map, key, value)) goto fail;
        json_skip_ws(jp);
        if (*jp->p == ',') {
            jp->p++;
            continue;
        }
        if (*jp->p == '}') {
            jp->p++;
            return map;
        }
        goto fail;
    }
fail:
    node_free(map);
    return NULL;
}

static spdf_node* json_parse_array(json_parser* jp) {
    spdf_node* seq = node_new(SPDF_NODE_SEQ);
    if (!seq) return NULL;
    jp->p++; /* [ */
    json_skip_ws(jp);
    if (*jp->p == ']') {
        jp->p++;
        return seq;
    }
    for (;;) {
        spdf_node* value = json_parse_value(jp);
        if (!value) goto fail;
        if (!node_append(seq, NULL, value)) goto fail;
        json_skip_ws(jp);
        if (*jp->p == ',') {
            jp->p++;
            continue;
        }
        if (*jp->p == ']') {
            jp->p++;
            return seq;
        }
        goto fail;
    }
fail:
    node_free(seq);
    return NULL;
}

static spdf_node* json_parse_value(json_parser* jp) {
    json_skip_ws(jp);
    if (jp->depth >= SPDF_YAML_MAX_DEPTH) return NULL;
    jp->depth++;
    spdf_node* result = NULL;
    if (*jp->p == '{') {
        result = json_parse_object(jp);
    } else if (*jp->p == '[') {
        result = json_parse_array(jp);
    } else if (*jp->p == '"') {
        jp->p++;
        char* text = decode_double_quoted(&jp->p);
        if (text) {
            result = node_new(SPDF_NODE_STRING);
            if (result)
                result->scalar = text;
            else
                free(text);
        }
    } else if (strncmp(jp->p, "true", 4) == 0) {
        jp->p += 4;
        result = node_new(SPDF_NODE_BOOL);
        if (result) result->bool_value = 1;
    } else if (strncmp(jp->p, "false", 5) == 0) {
        jp->p += 5;
        result = node_new(SPDF_NODE_BOOL);
    } else if (strncmp(jp->p, "null", 4) == 0) {
        jp->p += 4;
        result = node_new(SPDF_NODE_NULL);
    } else {
        const char* start = jp->p;
        while (*jp->p && !strchr(",]}\t\n\r ", *jp->p)) jp->p++;
        size_t len = (size_t)(jp->p - start);
        if (len > 0 && is_json_number_token(start, len)) {
            result = node_new(SPDF_NODE_NUMBER);
            if (result) {
                result->scalar = (char*)malloc(len + 1);
                if (result->scalar) {
                    memcpy(result->scalar, start, len);
                    result->scalar[len] = 0;
                } else {
                    node_free(result);
                    result = NULL;
                }
            }
        }
    }
    jp->depth--;
    return result;
}

static spdf_node* json_parse_document(const char* text) {
    if (!text) return NULL;
    json_parser jp = {text, 0};
    spdf_node* root = json_parse_value(&jp);
    if (!root) return NULL;
    json_skip_ws(&jp);
    if (*jp.p) {
        node_free(root);
        return NULL;
    }
    return root;
}

/* ------------------------------------------------------------- JSON emit */

static void json_emit_node(spdf_buf* out, const spdf_node* node) {
    switch (node->kind) {
        case SPDF_NODE_NULL:
            buf_append(out, "null");
            break;
        case SPDF_NODE_BOOL:
            buf_append(out, node->bool_value ? "true" : "false");
            break;
        case SPDF_NODE_NUMBER:
            buf_append(out, node->scalar);
            break;
        case SPDF_NODE_STRING:
            emit_quoted_string(out, node->scalar);
            break;
        case SPDF_NODE_MAP:
            buf_append_char(out, '{');
            for (size_t i = 0; i < node->count; i++) {
                if (i) buf_append_char(out, ',');
                emit_quoted_string(out, node->keys[i]);
                buf_append_char(out, ':');
                json_emit_node(out, node->items[i]);
            }
            buf_append_char(out, '}');
            break;
        case SPDF_NODE_SEQ:
            buf_append_char(out, '[');
            for (size_t i = 0; i < node->count; i++) {
                if (i) buf_append_char(out, ',');
                json_emit_node(out, node->items[i]);
            }
            buf_append_char(out, ']');
            break;
    }
}

/* ------------------------------------------------------------- YAML emit */

/* Keys stay unquoted only when they cannot be misread: identifier-shaped and
 * not a null/bool word. Everything else (paths, spaces, colons, digits) is
 * double-quoted. */
static int yaml_key_is_plain(const char* key) {
    if (!key || !*key) return 0;
    if (!isalpha((unsigned char)key[0]) && key[0] != '_') return 0;
    for (const char* p = key; *p; p++) {
        if (!isalnum((unsigned char)*p) && *p != '_' && *p != '-') return 0;
    }
    if (!strcmp(key, "true") || !strcmp(key, "false") || !strcmp(key, "null")) return 0;
    return 1;
}

static void yaml_emit_indent(spdf_buf* out, int indent) {
    for (int i = 0; i < indent; i++) buf_append(out, "  ");
}

static void yaml_emit_scalar(spdf_buf* out, const spdf_node* node) {
    switch (node->kind) {
        case SPDF_NODE_NULL:
            buf_append(out, "null");
            break;
        case SPDF_NODE_BOOL:
            buf_append(out, node->bool_value ? "true" : "false");
            break;
        case SPDF_NODE_NUMBER:
            buf_append(out, node->scalar);
            break;
        default:
            emit_quoted_string(out, node->scalar);
            break;
    }
}

static int yaml_node_is_scalar(const spdf_node* node) {
    return node->kind != SPDF_NODE_MAP && node->kind != SPDF_NODE_SEQ;
}

static void yaml_emit_block(spdf_buf* out, const spdf_node* node, int indent, int hanging_first_line);

/* Emits "key:" plus the value, either inline (scalars, empty containers) or
 * as a nested block. */
static void yaml_emit_map_entry(spdf_buf* out, const char* key, const spdf_node* value, int indent) {
    if (yaml_key_is_plain(key))
        buf_append(out, key);
    else
        emit_quoted_string(out, key);
    buf_append_char(out, ':');
    if (yaml_node_is_scalar(value)) {
        buf_append_char(out, ' ');
        yaml_emit_scalar(out, value);
        buf_append_char(out, '\n');
    } else if (value->count == 0) {
        buf_append(out, value->kind == SPDF_NODE_MAP ? " {}\n" : " []\n");
    } else {
        buf_append_char(out, '\n');
        yaml_emit_block(out, value, indent + 1, 0);
    }
}

static void yaml_emit_block(spdf_buf* out, const spdf_node* node, int indent, int hanging_first_line) {
    if (node->kind == SPDF_NODE_MAP) {
        for (size_t i = 0; i < node->count; i++) {
            if (i > 0 || !hanging_first_line) yaml_emit_indent(out, indent);
            yaml_emit_map_entry(out, node->keys[i], node->items[i], indent);
        }
        return;
    }
    for (size_t i = 0; i < node->count; i++) {
        const spdf_node* item = node->items[i];
        if (i > 0 || !hanging_first_line) yaml_emit_indent(out, indent);
        buf_append(out, "- ");
        if (yaml_node_is_scalar(item)) {
            yaml_emit_scalar(out, item);
            buf_append_char(out, '\n');
        } else if (item->count == 0) {
            buf_append(out, item->kind == SPDF_NODE_MAP ? "{}\n" : "[]\n");
        } else {
            /* "- " is exactly one indent unit, so the item's first line hangs
             * after the dash and its remaining lines align at indent + 1. */
            yaml_emit_block(out, item, indent + 1, 1);
        }
    }
}

static char* yaml_emit_document(const spdf_node* root, const char* header_comment) {
    spdf_buf out = {0};
    if (header_comment && *header_comment) {
        buf_append(&out, "# ");
        buf_append(&out, header_comment);
        buf_append_char(&out, '\n');
    }
    if (yaml_node_is_scalar(root)) {
        yaml_emit_scalar(&out, root);
        buf_append_char(&out, '\n');
    } else if (root->count == 0) {
        buf_append(&out, root->kind == SPDF_NODE_MAP ? "{}\n" : "[]\n");
    } else {
        yaml_emit_block(&out, root, 0, 0);
    }
    return buf_take(&out);
}

/* ------------------------------------------------------------ YAML parse */

typedef struct {
    char** texts; /* content with indentation stripped, NUL-terminated */
    int* cols;    /* column where the content starts */
    int count;
    int capacity;
} yaml_lines;

static void yaml_lines_free(yaml_lines* lines) {
    for (int i = 0; i < lines->count; i++) free(lines->texts[i]);
    free(lines->texts);
    free(lines->cols);
}

/* Split into logical lines, dropping blanks and full-line comments. Tabs in
 * indentation are a hard error (YAML forbids them; silently treating them as
 * spaces would corrupt nesting). Returns 0 on error. */
static int yaml_split_lines(const char* text, yaml_lines* lines) {
    const char* p = text;
    while (*p) {
        const char* line = p;
        while (*p && *p != '\n') p++;
        const char* end = p;
        if (*p) p++;
        if (end > line && end[-1] == '\r') end--;
        int col = 0;
        const char* content = line;
        while (content < end && *content == ' ') {
            content++;
            col++;
        }
        if (content < end && *content == '\t') return 0;
        while (end > content && (end[-1] == ' ' || end[-1] == '\t')) end--; /* trailing whitespace */
        if (content == end || *content == '#') continue;
        if (lines->count == 0 && end - content == 3 && strncmp(content, "---", 3) == 0) continue;
        if (lines->count == lines->capacity) {
            int capacity = lines->capacity ? lines->capacity * 2 : 32;
            char** texts = (char**)realloc(lines->texts, (size_t)capacity * sizeof(*texts));
            int* cols = (int*)realloc(lines->cols, (size_t)capacity * sizeof(*cols));
            if (!texts || !cols) {
                free(texts ? texts : lines->texts);
                lines->texts = NULL;
                free(cols ? cols : lines->cols);
                lines->cols = NULL;
                lines->count = 0;
                lines->capacity = 0;
                return 0;
            }
            lines->texts = texts;
            lines->cols = cols;
            lines->capacity = capacity;
        }
        char* copy = (char*)malloc((size_t)(end - content) + 1);
        if (!copy) return 0;
        memcpy(copy, content, (size_t)(end - content));
        copy[end - content] = 0;
        lines->texts[lines->count] = copy;
        lines->cols[lines->count] = col;
        lines->count++;
    }
    return 1;
}

typedef struct {
    yaml_lines* lines;
    int i;
    /* One line of pushback: the content hanging after a sequence dash ("- x")
     * re-enters the parser as a virtual line at the dash's content column. */
    const char* pending_text;
    int pending_col;
    int has_pending;
    int depth;
    int ok;
} yaml_parser;

static int yp_has_line(const yaml_parser* yp) {
    return yp->has_pending || yp->i < yp->lines->count;
}

static const char* yp_peek_text(const yaml_parser* yp) {
    return yp->has_pending ? yp->pending_text : yp->lines->texts[yp->i];
}

static int yp_peek_col(const yaml_parser* yp) {
    return yp->has_pending ? yp->pending_col : yp->lines->cols[yp->i];
}

static void yp_advance(yaml_parser* yp) {
    if (yp->has_pending)
        yp->has_pending = 0;
    else
        yp->i++;
}

static spdf_node* yaml_parse_block(yaml_parser* yp);

static int yaml_line_is_seq_item(const char* text) {
    return text[0] == '-' && (text[1] == 0 || text[1] == ' ');
}

/* Strips an unquoted trailing comment: " #" starts a comment per YAML. */
static void yaml_strip_plain_comment(char* text) {
    for (char* p = text; *p; p++) {
        if (*p == '#' && p > text && (p[-1] == ' ' || p[-1] == '\t')) {
            *p = 0;
            break;
        }
    }
    size_t len = strlen(text);
    while (len > 0 && (text[len - 1] == ' ' || text[len - 1] == '\t')) text[--len] = 0;
}

static char* yaml_decode_single_quoted(const char** cursor) {
    const char* p = *cursor;
    spdf_buf out = {0};
    while (*p) {
        if (*p == '\'') {
            if (p[1] == '\'') {
                buf_append_char(&out, '\'');
                p += 2;
                continue;
            }
            *cursor = p + 1;
            return buf_take(&out);
        }
        buf_append_char(&out, *p++);
    }
    free(out.data);
    return NULL;
}

/* Only trailing whitespace or a comment may follow a closing quote. */
static int yaml_rest_is_ignorable(const char* p) {
    while (*p == ' ' || *p == '\t') p++;
    return *p == 0 || *p == '#';
}

static spdf_node* yaml_scalar_from_plain(const char* text) {
    size_t len = strlen(text);
    if (len == 0 || !strcmp(text, "~") || !strcmp(text, "null")) return node_new(SPDF_NODE_NULL);
    if (!strcmp(text, "true") || !strcmp(text, "false")) {
        spdf_node* node = node_new(SPDF_NODE_BOOL);
        if (node) node->bool_value = text[0] == 't';
        return node;
    }
    spdf_node* node = node_new(is_json_number_token(text, len) ? SPDF_NODE_NUMBER : SPDF_NODE_STRING);
    if (node) {
        node->scalar = spdf_compat_strdup(text);
        if (!node->scalar) {
            node_free(node);
            return NULL;
        }
    }
    return node;
}

/* Parses the scalar (or empty flow container) occupying the rest of a line. */
static spdf_node* yaml_parse_inline_value(const char* text) {
    if (text[0] == '"') {
        const char* p = text + 1;
        char* decoded = decode_double_quoted(&p);
        if (!decoded || !yaml_rest_is_ignorable(p)) {
            free(decoded);
            return NULL;
        }
        spdf_node* node = node_new(SPDF_NODE_STRING);
        if (node)
            node->scalar = decoded;
        else
            free(decoded);
        return node;
    }
    if (text[0] == '\'') {
        const char* p = text + 1;
        char* decoded = yaml_decode_single_quoted(&p);
        if (!decoded || !yaml_rest_is_ignorable(p)) {
            free(decoded);
            return NULL;
        }
        spdf_node* node = node_new(SPDF_NODE_STRING);
        if (node)
            node->scalar = decoded;
        else
            free(decoded);
        return node;
    }
    char* plain = spdf_compat_strdup(text);
    if (!plain) return NULL;
    yaml_strip_plain_comment(plain);
    spdf_node* node = NULL;
    if (!strcmp(plain, "{}"))
        node = node_new(SPDF_NODE_MAP);
    else if (!strcmp(plain, "[]"))
        node = node_new(SPDF_NODE_SEQ);
    else
        node = yaml_scalar_from_plain(plain);
    free(plain);
    return node;
}

/* Splits "key: value" / "key:" at the first colon that terminates a key.
 * Returns the decoded key (caller frees) and points *rest at the value text
 * (or "" when the value continues on following lines). NULL when the line is
 * not a mapping entry. */
static char* yaml_split_key(const char* text, const char** rest) {
    const char* p = text;
    char* key = NULL;
    if (*p == '"') {
        p++;
        key = decode_double_quoted(&p);
        if (!key) return NULL;
    } else if (*p == '\'') {
        p++;
        key = yaml_decode_single_quoted(&p);
        if (!key) return NULL;
    } else {
        /* Plain key: runs to the first ": " or a colon at end of line. */
        const char* colon = NULL;
        for (const char* q = p; *q; q++) {
            if (*q == ':' && (q[1] == ' ' || q[1] == 0)) {
                colon = q;
                break;
            }
        }
        if (!colon) return NULL;
        const char* end = colon;
        while (end > p && (end[-1] == ' ' || end[-1] == '\t')) end--;
        key = (char*)malloc((size_t)(end - p) + 1);
        if (!key) return NULL;
        memcpy(key, p, (size_t)(end - p));
        key[end - p] = 0;
        p = colon;
    }
    while (*p == ' ' || *p == '\t') p++;
    if (*p != ':' || (p[1] != ' ' && p[1] != 0)) {
        free(key);
        return NULL;
    }
    p++;
    while (*p == ' ' || *p == '\t') p++;
    *rest = p;
    return key;
}

/* Parses one mapping entry: the key/value split of `text` (which sits at
 * column `col`), consuming continuation lines for block values. */
static int yaml_parse_map_entry(yaml_parser* yp, spdf_node* map, const char* text, int col) {
    const char* rest = NULL;
    char* key = yaml_split_key(text, &rest);
    if (!key) {
        yp->ok = 0;
        return 0;
    }
    spdf_node* value = NULL;
    if (*rest == 0 || *rest == '#') {
        /* Block value on the following lines: deeper indent, or a sequence at
         * the same indent as the key (the common human style). */
        if (yp_has_line(yp) &&
            (yp_peek_col(yp) > col || (yp_peek_col(yp) == col && yaml_line_is_seq_item(yp_peek_text(yp)))))
            value = yaml_parse_block(yp);
        else
            value = node_new(SPDF_NODE_NULL);
    } else {
        value = yaml_parse_inline_value(rest);
    }
    if (!value || !yp->ok) {
        free(key);
        node_free(value);
        yp->ok = 0;
        return 0;
    }
    if (!node_append(map, key, value)) {
        yp->ok = 0;
        return 0;
    }
    return 1;
}

/* Parses the block starting at the current (or pushed-back) line; that line's
 * column defines the block, and the block ends at the first line indented
 * less deeply. A single non-entry line parses as a scalar block. */
static spdf_node* yaml_parse_block(yaml_parser* yp) {
    if (yp->depth >= SPDF_YAML_MAX_DEPTH || !yp_has_line(yp)) {
        yp->ok = 0;
        return NULL;
    }
    yp->depth++;
    int block_col = yp_peek_col(yp);
    spdf_node* result = NULL;
    if (yaml_line_is_seq_item(yp_peek_text(yp))) {
        result = node_new(SPDF_NODE_SEQ);
        while (result && yp->ok && yp_has_line(yp) && yp_peek_col(yp) == block_col &&
               yaml_line_is_seq_item(yp_peek_text(yp))) {
            const char* item_text = yp_peek_text(yp) + 1;
            int item_col = block_col + 1;
            while (*item_text == ' ') {
                item_text++;
                item_col++;
            }
            spdf_node* item = NULL;
            if (*item_text == 0) {
                /* "-" alone: the item is the nested block on later lines. */
                yp_advance(yp);
                if (yp_has_line(yp) && yp_peek_col(yp) > block_col)
                    item = yaml_parse_block(yp);
                else
                    item = node_new(SPDF_NODE_NULL);
            } else {
                /* Re-enter the parser with the content hanging after the dash
                 * as a virtual line at its own column; that handles scalars,
                 * "- key: value" hanging maps, and "- - nested" sequences.
                 * The text stays alive in the line buffer across the parse. */
                yp_advance(yp);
                yp->pending_text = item_text;
                yp->pending_col = item_col;
                yp->has_pending = 1;
                item = yaml_parse_block(yp);
            }
            if (!item || !yp->ok) {
                node_free(item);
                yp->ok = 0;
                break;
            }
            if (!node_append(result, NULL, item)) {
                yp->ok = 0;
                break;
            }
        }
    } else {
        const char* probe_rest = NULL;
        char* probe_key = yaml_split_key(yp_peek_text(yp), &probe_rest);
        if (!probe_key) {
            /* Scalar block: a single inline value line. */
            result = yaml_parse_inline_value(yp_peek_text(yp));
            yp_advance(yp);
            if (!result) yp->ok = 0;
        } else {
            free(probe_key);
            result = node_new(SPDF_NODE_MAP);
            while (result && yp->ok && yp_has_line(yp) && yp_peek_col(yp) == block_col &&
                   !yaml_line_is_seq_item(yp_peek_text(yp))) {
                const char* entry = yp_peek_text(yp);
                yp_advance(yp);
                if (!yaml_parse_map_entry(yp, result, entry, block_col)) break;
            }
        }
    }
    /* Any leftover line indented deeper than this block means broken nesting. */
    if (result && yp->ok && yp_has_line(yp) && yp_peek_col(yp) > block_col) yp->ok = 0;
    if (!yp->ok) {
        node_free(result);
        result = NULL;
    }
    yp->depth--;
    return result;
}

static spdf_node* yaml_parse_document(const char* text) {
    if (!text) return NULL;
    yaml_lines lines = {0};
    if (!yaml_split_lines(text, &lines)) {
        yaml_lines_free(&lines);
        return NULL;
    }
    if (lines.count == 0) {
        yaml_lines_free(&lines);
        return NULL; /* empty file: same as unparseable, callers use defaults */
    }
    spdf_node* root = NULL;
    if (lines.count == 1 && !yaml_line_is_seq_item(lines.texts[0])) {
        const char* rest = NULL;
        char* key = yaml_split_key(lines.texts[0], &rest);
        if (key)
            free(key);
        else
            root = yaml_parse_inline_value(lines.texts[0]); /* whole-document scalar or {} / [] */
    }
    if (!root) {
        yaml_parser yp = {0};
        yp.lines = &lines;
        yp.ok = 1;
        root = yaml_parse_block(&yp);
        if (root && (yp.i < lines.count || yp.has_pending || !yp.ok)) {
            node_free(root);
            root = NULL;
        }
    }
    yaml_lines_free(&lines);
    return root;
}

/* -------------------------------------------------------------- public API */

char* spdf_yaml_from_json(const char* json_text, const char* header_comment) {
    spdf_node* root = json_parse_document(json_text);
    if (!root) return NULL;
    char* yaml = yaml_emit_document(root, header_comment);
    node_free(root);
    return yaml;
}

char* spdf_json_from_yaml(const char* yaml_text) {
    spdf_node* root = yaml_parse_document(yaml_text);
    if (!root) return NULL;
    spdf_buf out = {0};
    json_emit_node(&out, root);
    node_free(root);
    return buf_take(&out);
}

const char* spdf_state_header_for_file(const char* filename, char* out, size_t out_len) {
    if (!out || out_len == 0) return out;
    const char* base = spdf_compat_path_basename(filename ? filename : "");
    char stem[64];
    size_t n = 0;
    while (base[n] && base[n] != '.' && n + 1 < sizeof(stem)) {
        stem[n] = base[n];
        n++;
    }
    stem[n] = 0;
    snprintf(out, out_len, "ShenzhenPDF %s — edit while the app is closed", n ? stem : "state");
    return out;
}

static int spdf_file_exists(const char* path) {
    long long sec;
    long nsec;
    return spdf_compat_file_mtime(path, &sec, &nsec);
}

/* 1 when a exists and is strictly newer than b, else 0. Windows has neither
 * st_mtimespec nor st_mtim and resolves only to the second, so two writes inside
 * one second compare equal there and the caller keeps the YAML it already has. */
static int spdf_file_strictly_newer(const char* a, const char* b) {
    long long a_sec = 0, b_sec = 0;
    long a_nsec = 0, b_nsec = 0;
    if (!spdf_compat_file_mtime(a, &a_sec, &a_nsec)) return 0;
    if (!spdf_compat_file_mtime(b, &b_sec, &b_nsec)) return 0;
    if (a_sec != b_sec) return a_sec > b_sec;
    return a_nsec > b_nsec;
}

static char* spdf_read_entire_file(const char* path) {
    FILE* f = spdf_compat_fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return NULL;
    }
    long size = ftell(f);
    if (size < 0 || fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        return NULL;
    }
    char* data = (char*)malloc((size_t)size + 1);
    if (!data) {
        fclose(f);
        return NULL;
    }
    size_t got = fread(data, 1, (size_t)size, f);
    fclose(f);
    if (got != (size_t)size) {
        free(data);
        return NULL;
    }
    data[size] = 0;
    return data;
}

static int spdf_write_file_atomic(const char* path, const char* text) {
    char temp[1024];
    if (!spdf_compat_snprintf_ok(snprintf(temp, sizeof(temp), "%s.tmp.%ld", path, spdf_compat_getpid()), sizeof(temp))) return 0;
    FILE* f = spdf_compat_fopen(temp, "wb");
    if (!f) return 0;
    size_t len = strlen(text);
    size_t written = fwrite(text, 1, len, f);
    int close_err = fclose(f);
    if (written != len || close_err != 0) {
        spdf_compat_unlink(temp);
        return 0;
    }
    /* Replace-existing: rename() refuses to overwrite on Windows, and every
     * state rewrite after the very first one overwrites an existing file. */
    if (spdf_compat_replace_file(temp, path) != 0) {
        spdf_compat_unlink(temp);
        return 0;
    }
    return 1;
}

int spdf_state_migrate_file(const char* json_path, const char* yaml_path, const char* header_comment) {
    if (!json_path || !yaml_path) return -1;
    /* An existing YAML file wins — a hand-created file, or a completed prior
     * migration — UNLESS the JSON sibling is strictly newer: that means a
     * pre-YAML build ran after the YAML was written (downgrade then upgrade)
     * and the JSON carries the user's most recent state, so re-migrate it. */
    if (spdf_file_exists(yaml_path) && !spdf_file_strictly_newer(json_path, yaml_path)) return 0;
    char* json = spdf_read_entire_file(json_path);
    if (!json) return 0; /* nothing to migrate */
    char* yaml = spdf_yaml_from_json(json, header_comment);
    free(json);
    if (!yaml) return -1; /* malformed JSON: leave both files alone, like the old corrupt-JSON path */
    int wrote = spdf_write_file_atomic(yaml_path, yaml);
    free(yaml);
    if (!wrote) return -1;
    char backup[1024];
    /* Rename only when the WHOLE path was written: the old `< (int)sizeof(backup)` was also true for snprintf's negative return. */
    if (spdf_compat_snprintf_ok(snprintf(backup, sizeof(backup), "%s.migrated-backup", json_path), sizeof(backup)))
        spdf_compat_replace_file(json_path, backup); /* a backup may already exist */
    return 1;
}

int spdf_state_migrate_dir(const char* dir, const char* const* stems, int stem_count) {
    if (!dir || !stems || stem_count <= 0) return 0;
    char lock_path[1024];
    const size_t lock_cap = sizeof(lock_path);
    if (!spdf_compat_snprintf_ok(snprintf(lock_path, lock_cap, "%s" SPDF_PATH_SEP_STR "migration.lock", dir), lock_cap)) return -1;
    /* Windows has no flock(); the shim takes an exclusive LockFileEx range on a
     * CreateFileW handle, which the kernel drops if a holder dies mid-migration. */
    spdf_compat_file_lock lock;
    if (!spdf_compat_lock_acquire(lock_path, &lock)) return -1;
    int migrated = 0;
    for (int i = 0; i < stem_count; i++) {
        char json_path[1024], yaml_path[1024];
        char header[128];
        const size_t path_cap = sizeof(json_path);
        if (!spdf_compat_snprintf_ok(snprintf(json_path, path_cap, "%s" SPDF_PATH_SEP_STR "%s.json", dir, stems[i]), path_cap)) continue;
        if (!spdf_compat_snprintf_ok(snprintf(yaml_path, path_cap, "%s" SPDF_PATH_SEP_STR "%s.yaml", dir, stems[i]), path_cap)) continue;
        spdf_state_header_for_file(stems[i], header, sizeof(header));
        if (spdf_state_migrate_file(json_path, yaml_path, header) == 1) migrated++;
    }
    spdf_compat_lock_release(&lock);
    return migrated;
}
