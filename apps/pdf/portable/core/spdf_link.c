/* spdf_link.c -- reading szpdf: links (spdf_link.h). Works on the link's bytes: a browser hands the app the link as
 * the page wrote it, so nothing here trusts it beyond what is checked. */
#include "spdf_link.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int lower(int c) { return c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c; }

static int prefix_nocase(const char* text, const char* prefix) {
    for (; *prefix; ++text, ++prefix)
        if (lower((unsigned char)*text) != *prefix) return 0;
    return 1;
}

static int hex_value(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    c = lower(c);
    return c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}

/* Percent-decodes [begin, end) into out. A %00, a broken escape or a result that does not fit fail. */
static int percent_decode(const char* begin, const char* end, char* out, size_t cap) {
    size_t n = 0;
    for (const char* p = begin; p < end; ++p) {
        int c = (unsigned char)*p;
        if (c == '%') {
            if (end - p < 3) return 0;
            int hi = hex_value((unsigned char)p[1]);
            int lo = hex_value((unsigned char)p[2]);
            if (hi < 0 || lo < 0 || (hi == 0 && lo == 0)) return 0;
            c = hi * 16 + lo;
            p += 2;
        }
        if (n + 1 >= cap) return 0;
        out[n++] = (char)c;
    }
    out[n] = '\0';
    return 1;
}

static int page_in(const char* begin, const char* end);

/* The value of a "key=" item of an &-separated list, percent-decoded into out (left alone when absent or unusable). */
static void value_in(const char* begin, const char* end, const char* key, char* out, size_t cap) {
    size_t key_len = strlen(key);
    for (const char* item = begin; item < end;) {
        const char* stop = memchr(item, '&', (size_t)(end - item));
        if (!stop) stop = end;
        char scratch[SPDF_LINK_MAX_BYTES + 1];
        if ((size_t)(stop - item) > key_len && prefix_nocase(item, key) &&
            percent_decode(item + key_len, stop, scratch, sizeof(scratch)) && strlen(scratch) < cap)
            memcpy(out, scratch, strlen(scratch) + 1);
        item = stop + 1;
    }
}

/* Where a fragment says to open: page=, section= (or chapter=, or a PDF's nameddest=), heading=, or a bare slug,
 * which is a heading. Fills only what the link did not already say. */
static void targets_in_fragment(const char* fragment, spdf_link* out) {
    const char* end = fragment + strlen(fragment);
    if (!*fragment) return;
    if (!strchr(fragment, '=')) {
        if (!out->heading[0]) value_in(fragment, end, "", out->heading, sizeof(out->heading));
        return;
    }
    char section[sizeof(out->section)] = "";
    if (!out->page) out->page = page_in(fragment, end);
    value_in(fragment, end, "nameddest=", section, sizeof(section));
    value_in(fragment, end, "chapter=", section, sizeof(section));
    value_in(fragment, end, "section=", section, sizeof(section));
    if (!out->section[0]) memcpy(out->section, section, sizeof(section));
    if (!out->heading[0]) value_in(fragment, end, "heading=", out->heading, sizeof(out->heading));
}

/* The page in a "page=N" item of an &-separated list, or 0. A page out of range is no page rather than a refusal:
 * the document is still the one the link names. */
static int page_in(const char* begin, const char* end) {
    const char* item = begin;
    while (item < end) {
        const char* stop = memchr(item, '&', (size_t)(end - item));
        if (!stop) stop = end;
        if (stop - item > 5 && prefix_nocase(item, "page=")) {
            long value = 0;
            const char* p = item + 5;
            for (; p < stop && *p >= '0' && *p <= '9' && value <= SPDF_LINK_MAX_PAGE; ++p) value = value * 10 + (*p - '0');
            if (p == stop && value >= 1 && value <= SPDF_LINK_MAX_PAGE) return (int)value;
        }
        item = stop + 1;
    }
    return 0;
}

static int url_safe(int c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
           (c && strchr("-._~:/?[]@!$&'()*+,;=", c));
}

/* Appends [begin, end) to out, percent-encoding every byte a URL cannot carry as it is (spaces, quotes, angle
 * brackets, bytes past ASCII) and any % that does not start an escape. */
static int append_encoded(char* out, size_t* n, size_t cap, const char* begin, const char* end) {
    static const char digits[] = "0123456789ABCDEF";
    for (const char* p = begin; p < end; ++p) {
        int c = (unsigned char)*p;
        int keep = url_safe(c) || (c == '%' && end - p >= 3 && hex_value((unsigned char)p[1]) >= 0 &&
                                   hex_value((unsigned char)p[2]) >= 0);
        if (*n + (keep ? 1 : 3) >= cap) return 0;
        if (keep) {
            out[(*n)++] = (char)c;
        } else {
            out[(*n)++] = '%';
            out[(*n)++] = digits[c >> 4];
            out[(*n)++] = digits[c & 15];
        }
    }
    out[*n] = '\0';
    return 1;
}

static int host_char(int c) { return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.'; }

/* Checks a document address and writes its normalized form into out. `page` is the link's own page, if any. */
static spdf_link_status read_target(const char* url, int page, spdf_link* out) {
    const char* colon = strchr(url, ':');
    const char* slash = strchr(url, '/');
    if (!colon || (slash && slash < colon)) return SPDF_LINK_MALFORMED;
    int https = colon - url == 5 && prefix_nocase(url, "https");
    int http = colon - url == 4 && prefix_nocase(url, "http");
    if (!https && !http) return SPDF_LINK_UNSUPPORTED; /* file:, javascript:, data:, ftp: ... */
    if (strncmp(colon, "://", 3) != 0) return SPDF_LINK_MALFORMED;

    const char* authority = colon + 3;
    const char* rest = authority + strcspn(authority, "/?#");
    if (memchr(authority, '@', (size_t)(rest - authority))) return SPDF_LINK_CREDENTIALS;
    const char* host = authority;
    const char* host_end;
    const char* port = NULL;
    if (*host == '[') {
        host_end = memchr(host, ']', (size_t)(rest - host));
        if (!host_end) return SPDF_LINK_MALFORMED;
        ++host;
        for (const char* p = host; p < host_end; ++p)
            if (hex_value((unsigned char)*p) < 0 && *p != ':') return SPDF_LINK_MALFORMED;
        if (host_end + 1 < rest) {
            if (host_end[1] != ':') return SPDF_LINK_MALFORMED;
            port = host_end + 2;
        }
    } else {
        host_end = memchr(host, ':', (size_t)(rest - host));
        if (host_end) port = host_end + 1;
        else host_end = rest;
        for (const char* p = host; p < host_end; ++p)
            if (!host_char(lower((unsigned char)*p))) return SPDF_LINK_MALFORMED;
    }
    size_t host_len = (size_t)(host_end - host);
    if (host_len == 0 || host_len >= sizeof(out->host)) return SPDF_LINK_MALFORMED;
    if (port) {
        long value = 0;
        if (port == rest || rest - port > 5) return SPDF_LINK_MALFORMED;
        for (const char* p = port; p < rest; ++p) {
            if (*p < '0' || *p > '9') return SPDF_LINK_MALFORMED;
            value = value * 10 + (*p - '0');
        }
        if (value < 1 || value > 65535) return SPDF_LINK_MALFORMED;
    }
    for (size_t i = 0; i < host_len; ++i) out->host[i] = (char)lower((unsigned char)host[i]);
    out->host[host_len] = '\0';
    if (http && strcmp(out->host, "localhost") != 0 && strcmp(out->host, "127.0.0.1") != 0 &&
        strcmp(out->host, "::1") != 0)
        return SPDF_LINK_UNSUPPORTED; /* plain http only to this computer */

    const char* fragment = strchr(rest, '#');
    const char* end = fragment ? fragment : rest + strlen(rest);
    size_t n = 0;
    const char* scheme = https ? "https://" : "http://";
    size_t scheme_len = strlen(scheme);
    memcpy(out->url, scheme, scheme_len);
    n = scheme_len;
    for (const char* p = authority; p < rest; ++p) out->url[n++] = (char)lower((unsigned char)*p);
    out->url[n] = '\0';
    static const char root[] = "/";
    if (*rest != '/' && !append_encoded(out->url, &n, sizeof(out->url), root, root + 1)) return SPDF_LINK_TOO_LONG;
    if (!append_encoded(out->url, &n, sizeof(out->url), rest, end)) return SPDF_LINK_TOO_LONG;
    out->page = page;
    if (fragment) targets_in_fragment(fragment + 1, out);
    return SPDF_LINK_OK;
}

static spdf_link_status parse(const char* text, spdf_link* out) {
    if (!text || !prefix_nocase(text, "szpdf:")) return SPDF_LINK_NOT_SZPDF;
    size_t len = strlen(text);
    if (len > SPDF_LINK_MAX_BYTES) return SPDF_LINK_TOO_LONG;
    for (size_t i = 0; i < len; ++i) {
        unsigned char c = (unsigned char)text[i];
        if (c <= 0x20 || c >= 0x7f) return SPDF_LINK_MALFORMED; /* a browser sends a link percent-encoded */
    }
    const char* rest = text + 6;
    if (rest[0] == '/' && rest[1] == '/') rest += 2;

    if (prefix_nocase(rest, "open?") || prefix_nocase(rest, "open/?")) {
        const char* query = strchr(rest, '?') + 1;
        const char* end = strchr(query, '#');
        if (!end) end = query + strlen(query);
        const char* url = NULL;
        const char* url_end = NULL;
        for (const char* item = query; item < end;) {
            const char* stop = memchr(item, '&', (size_t)(end - item));
            if (!stop) stop = end;
            if (stop - item > 4 && prefix_nocase(item, "url=")) {
                url = item + 4;
                url_end = stop;
            }
            item = stop + 1;
        }
        char decoded[SPDF_LINK_MAX_BYTES + 1];
        if (!url || !percent_decode(url, url_end, decoded, sizeof(decoded))) return SPDF_LINK_MALFORMED;
        int page = page_in(query, end);
        value_in(query, end, "chapter=", out->section, sizeof(out->section));
        value_in(query, end, "section=", out->section, sizeof(out->section));
        value_in(query, end, "heading=", out->heading, sizeof(out->heading));
        if (*end == '#') targets_in_fragment(end + 1, out);
        return read_target(decoded, page, out);
    }
    /* szpdf://https/host/path and szpdf:https://host/path: the address with its "://" folded or kept. */
    if (prefix_nocase(rest, "https:") || prefix_nocase(rest, "http:")) return read_target(rest, 0, out);
    if (prefix_nocase(rest, "https/") || prefix_nocase(rest, "http/")) {
        char address[SPDF_LINK_MAX_BYTES + 8];
        size_t scheme = (size_t)(strchr(rest, '/') - rest);
        snprintf(address, sizeof(address), "%.*s://%s", (int)scheme, rest, rest + scheme + 1);
        return read_target(address, 0, out);
    }
    /* Another scheme spelled in the link's place (szpdf://file/..., szpdf:javascript:...) is still a refusal of
     * that scheme, not a puzzle: say so the same way. */
    if (prefix_nocase(rest, "file") || prefix_nocase(rest, "javascript:") || prefix_nocase(rest, "ftp") ||
        prefix_nocase(rest, "data:"))
        return SPDF_LINK_UNSUPPORTED;
    return SPDF_LINK_MALFORMED;
}

spdf_link_status spdf_link_parse(const char* text, spdf_link* out) {
    spdf_link scratch;
    spdf_link* link = out ? out : &scratch;
    memset(link, 0, sizeof(*link));
    spdf_link_status status = parse(text, link);
    if (status != SPDF_LINK_OK) memset(link, 0, sizeof(*link));
    return status;
}

const char* spdf_link_refusal_message(spdf_link_status status) {
    switch (status) {
    case SPDF_LINK_OK: return "";
    case SPDF_LINK_NOT_SZPDF: return "This isn\u2019t a ShenzhenPDF link.";
    case SPDF_LINK_MALFORMED: return "This link is incomplete, so ShenzhenPDF can\u2019t tell which document it points to.";
    case SPDF_LINK_UNSUPPORTED: return "ShenzhenPDF opens linked documents only from secure (https) addresses.";
    case SPDF_LINK_CREDENTIALS: return "ShenzhenPDF doesn\u2019t open links that include a user name or password.";
    case SPDF_LINK_TOO_LONG: return "This link is too long to be a document\u2019s address.";
    }
    return "";
}

static uint64_t fnv1a64(const char* text) {
    uint64_t hash = 1469598103934665603ULL;
    for (; *text; ++text) {
        hash ^= (unsigned char)*text;
        hash *= 1099511628211ULL;
    }
    return hash;
}

int spdf_link_cache_relative_path(const spdf_link* link, char* out, size_t cap) {
    if (!link || !out || cap == 0 || !link->url[0]) return 0;
    char host[sizeof(link->host)];
    size_t i = 0;
    for (; link->host[i]; ++i) host[i] = link->host[i] == ':' ? '_' : link->host[i];
    host[i] = '\0';

    /* The last path segment, decoded, made safe for a file name. */
    const char* path = strstr(link->url, "://") + 3;
    path += strcspn(path, "/");
    const char* end = path + strcspn(path, "?");
    const char* segment = end;
    while (segment > path && segment[-1] != '/') --segment;
    char name[SPDF_LINK_MAX_BYTES + 8];
    if (!percent_decode(segment, end, name, SPDF_LINK_MAX_BYTES)) name[0] = '\0';
    size_t len = strlen(name);
    if (len > 200) { /* a file name's limit is 255 bytes: cut before a character, never inside one */
        len = 200;
        while (len > 0 && ((unsigned char)name[len] & 0xc0) == 0x80) --len;
        name[len] = '\0';
    }
    for (size_t k = 0; k < len; ++k) {
        unsigned char c = (unsigned char)name[k];
        if (c < 0x20 || c == 0x7f || c == '/' || c == ':' || c == '\\' || (k == 0 && c == '.')) name[k] = '_';
    }
    const char* dot = len ? strrchr(name + 1, '.') : NULL;
    if (!len) snprintf(name, sizeof(name), "Document.pdf");
    else if (!dot || !dot[1]) snprintf(name + len, sizeof(name) - len, ".pdf");

    int written = snprintf(out, cap, "%s/%016llx/%s", host, (unsigned long long)fnv1a64(link->url), name);
    return written > 0 && (size_t)written < cap;
}

void spdf_link_slug(const char* text, char* out, size_t cap) {
    size_t n = 0;
    if (!out || cap == 0) return;
    for (const unsigned char* p = (const unsigned char*)(text ? text : ""); *p && n + 1 < cap; ++p) {
        int c = lower(*p);
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c >= 0x80) out[n++] = (char)c;
        else if (c == ' ') out[n++] = '-';
    }
    out[n] = '\0';
}

static int equal_nocase(const char* a, const char* b) {
    for (; *a && *b; ++a, ++b)
        if (lower((unsigned char)*a) != lower((unsigned char)*b)) return 0;
    return *a == *b;
}

int spdf_link_match_title(const char* wanted, const char* const* titles, int count) {
    if (!wanted || !*wanted || !titles || count <= 0) return -1;
    for (int i = 0; i < count; ++i)
        if (titles[i] && strcmp(titles[i], wanted) == 0) return i;
    for (int i = 0; i < count; ++i)
        if (titles[i] && equal_nocase(titles[i], wanted)) return i;
    char wanted_slug[600], slug[600], numbered[640];
    spdf_link_slug(wanted, wanted_slug, sizeof(wanted_slug));
    for (int i = 0; i < count; ++i) {
        if (!titles[i]) continue;
        spdf_link_slug(titles[i], slug, sizeof(slug));
        int repeats = 0; /* GitHub numbers a slug seen before: intro, intro-1, intro-2 */
        for (int j = 0; j < i; ++j) {
            char earlier[600];
            spdf_link_slug(titles[j] ? titles[j] : "", earlier, sizeof(earlier));
            repeats += strcmp(earlier, slug) == 0;
        }
        if (repeats) snprintf(numbered, sizeof(numbered), "%s-%d", slug, repeats);
        else snprintf(numbered, sizeof(numbered), "%s", slug);
        if (strcmp(numbered, wanted) == 0 || (wanted_slug[0] && strcmp(numbered, wanted_slug) == 0)) return i;
    }
    return -1;
}
