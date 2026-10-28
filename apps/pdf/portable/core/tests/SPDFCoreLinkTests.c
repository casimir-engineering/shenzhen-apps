/* szpdf: links (core/spdf_link.h): which links open a document, which are refused and why, and where the document
 * is kept. */
#include "spdf_link.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void expect_ok(const char* text, const char* url, int page) {
    spdf_link link;
    spdf_link_status status = spdf_link_parse(text, &link);
    if (status != SPDF_LINK_OK || strcmp(link.url, url) != 0 || link.page != page) {
        fprintf(stderr, "FAIL: %s -> status %d url \"%s\" page %d, expected \"%s\" page %d\n", text, (int)status,
                link.url, link.page, url, page);
        failures++;
    }
}

static void expect_refused(const char* text, spdf_link_status expected) {
    spdf_link link;
    spdf_link_status status = spdf_link_parse(text, &link);
    if (status != expected || link.url[0]) {
        fprintf(stderr, "FAIL: %s -> status %d, expected %d\n", text ? text : "(null)", (int)status, (int)expected);
        failures++;
    }
    if (status != SPDF_LINK_OK && !spdf_link_refusal_message(status)[0]) {
        fprintf(stderr, "FAIL: no message for status %d\n", (int)status);
        failures++;
    }
}

static void expect_targets(const char* text, int page, const char* section, const char* heading) {
    spdf_link link;
    if (spdf_link_parse(text, &link) != SPDF_LINK_OK || link.page != page || strcmp(link.section, section) != 0 ||
        strcmp(link.heading, heading) != 0) {
        fprintf(stderr, "FAIL: %s -> page %d section \"%s\" heading \"%s\", expected %d \"%s\" \"%s\"\n", text,
                link.page, link.section, link.heading, page, section, heading);
        failures++;
    }
}

static void expect_match(const char* wanted, const char* const* titles, int count, int expected) {
    int found = spdf_link_match_title(wanted, titles, count);
    if (found != expected) {
        fprintf(stderr, "FAIL: \"%s\" matched %d, expected %d\n", wanted, found, expected);
        failures++;
    }
}

static void expect_cache(const char* text, const char* suffix) {
    spdf_link link;
    char path[1024];
    if (spdf_link_parse(text, &link) != SPDF_LINK_OK || !spdf_link_cache_relative_path(&link, path, sizeof(path))) {
        fprintf(stderr, "FAIL: no cache path for %s\n", text);
        failures++;
        return;
    }
    size_t n = strlen(path), m = strlen(suffix);
    /* "<host>/<16 hex>/<name>": check host and name around the hash. */
    const char* slash = strchr(path, '/');
    if (!slash || strlen(slash) < 18 || slash[17] != '/' || n < m || strcmp(path + n - m, suffix) != 0 ||
        strncmp(path, link.host[0] == ':' ? "__1" : link.host, (size_t)(slash - path)) != 0) {
        fprintf(stderr, "FAIL: cache path for %s is \"%s\", expected <host>/<hash>/...%s\n", text, path, suffix);
        failures++;
    }
}

int main(void) {
    /* The two forms, with and without a page. */
    expect_ok("szpdf://open?url=https%3A%2F%2Fexample.com%2Fdocs%2Fspec.pdf", "https://example.com/docs/spec.pdf", 0);
    expect_ok("szpdf://open?url=https%3A%2F%2Fexample.com%2Fspec.pdf&page=12", "https://example.com/spec.pdf", 12);
    expect_ok("szpdf://open?page=3&url=https://example.com/a.pdf", "https://example.com/a.pdf", 3);
    expect_ok("szpdf://open/?url=https%3A%2F%2Fexample.com%2Fa.pdf", "https://example.com/a.pdf", 0);
    expect_ok("szpdf://https/example.com/docs/spec.pdf", "https://example.com/docs/spec.pdf", 0);
    expect_ok("szpdf://https/example.com/docs/spec.pdf#page=7", "https://example.com/docs/spec.pdf", 7);
    expect_ok("SZPDF://HTTPS/Example.COM/Spec.pdf", "https://example.com/Spec.pdf", 0);
    expect_ok("szpdf:https://example.com/spec.pdf", "https://example.com/spec.pdf", 0);
    /* The address keeps its query, loses its fragment, and a #page= inside it counts when the link has none. */
    expect_ok("szpdf://https/example.com/get?id=4&v=2", "https://example.com/get?id=4&v=2", 0);
    expect_ok("szpdf://open?url=https%3A%2F%2Fexample.com%2Fget%3Fid%3D4%26v%3D2", "https://example.com/get?id=4&v=2",
              0);
    expect_ok("szpdf://open?url=https%3A%2F%2Fexample.com%2Fa.pdf%23page%3D5", "https://example.com/a.pdf", 5);
    expect_ok("szpdf://open?url=https%3A%2F%2Fexample.com%2Fa.pdf%23page%3D5&page=2", "https://example.com/a.pdf", 2);
    /* Ports, a host with no path, characters a URL cannot carry as they are. */
    expect_ok("szpdf://https/example.com:8443/a.pdf", "https://example.com:8443/a.pdf", 0);
    expect_ok("szpdf://https/example.com", "https://example.com/", 0);
    expect_ok("szpdf://open?url=https%3A%2F%2Fexample.com%2Fmy%20file%E2%80%93v2.pdf",
              "https://example.com/my%20file%E2%80%93v2.pdf", 0);
    expect_ok("szpdf://open?url=https%3A%2F%2Fexample.com%2F%3Cb%3E.pdf", "https://example.com/%3Cb%3E.pdf", 0);
    /* A page that is not a page is no page, not a refusal. */
    expect_ok("szpdf://open?url=https%3A%2F%2Fexample.com%2Fa.pdf&page=0", "https://example.com/a.pdf", 0);
    expect_ok("szpdf://open?url=https%3A%2F%2Fexample.com%2Fa.pdf&page=x", "https://example.com/a.pdf", 0);
    expect_ok("szpdf://open?url=https%3A%2F%2Fexample.com%2Fa.pdf&page=99999999", "https://example.com/a.pdf", 0);
    /* Plain http only to this computer. */
    expect_ok("szpdf://http/localhost:8000/a.pdf", "http://localhost:8000/a.pdf", 0);
    expect_ok("szpdf://open?url=http%3A%2F%2F127.0.0.1%3A9000%2Fa.pdf", "http://127.0.0.1:9000/a.pdf", 0);
    expect_ok("szpdf://open?url=http%3A%2F%2F%5B%3A%3A1%5D%3A9000%2Fa.pdf", "http://[::1]:9000/a.pdf", 0);
    expect_refused("szpdf://http/example.com/a.pdf", SPDF_LINK_UNSUPPORTED);
    expect_refused("szpdf://open?url=http%3A%2F%2Flocalhost.example.com%2Fa.pdf", SPDF_LINK_UNSUPPORTED);
    expect_refused("szpdf://open?url=http%3A%2F%2F127.0.0.2%2Fa.pdf", SPDF_LINK_UNSUPPORTED);

    /* Every other scheme is refused, however it is spelled into the link. */
    expect_refused("szpdf://open?url=file%3A%2F%2F%2Fetc%2Fpasswd", SPDF_LINK_UNSUPPORTED);
    expect_refused("szpdf://open?url=javascript%3Aalert(1)", SPDF_LINK_UNSUPPORTED);
    expect_refused("szpdf://open?url=ftp%3A%2F%2Fexample.com%2Fa.pdf", SPDF_LINK_UNSUPPORTED);
    expect_refused("szpdf://open?url=data%3Aapplication%2Fpdf%3Bbase64%2CJVBERi0%3D", SPDF_LINK_UNSUPPORTED);
    expect_refused("szpdf://open?url=smb%3A%2F%2Fserver%2Fshare%2Fa.pdf", SPDF_LINK_UNSUPPORTED);
    expect_refused("szpdf://file/etc/passwd", SPDF_LINK_UNSUPPORTED);
    expect_refused("szpdf:javascript:alert(1)", SPDF_LINK_UNSUPPORTED);
    /* A user name or password in the address (and the https://good@evil trick). */
    expect_refused("szpdf://open?url=https%3A%2F%2Fuser%3Apass%40example.com%2Fa.pdf", SPDF_LINK_CREDENTIALS);
    expect_refused("szpdf://https/bank.example.com@evil.example/a.pdf", SPDF_LINK_CREDENTIALS);
    /* Not readable as a document's address. */
    expect_refused(NULL, SPDF_LINK_NOT_SZPDF);
    expect_refused("https://example.com/a.pdf", SPDF_LINK_NOT_SZPDF);
    expect_refused("shenzhenpdf://friends/link#f.abc", SPDF_LINK_NOT_SZPDF);
    expect_refused("szpdf://open", SPDF_LINK_MALFORMED);
    expect_refused("szpdf://open?page=2", SPDF_LINK_MALFORMED);
    expect_refused("szpdf://open?url=", SPDF_LINK_MALFORMED);
    expect_refused("szpdf://open?url=https%3A%2F%2F", SPDF_LINK_MALFORMED);
    expect_refused("szpdf://open?url=https%3A%2F%2Fexa%00mple.com%2F", SPDF_LINK_MALFORMED);
    expect_refused("szpdf://open?url=https%3A%2F%2Fexample.com%2F%ZZ", SPDF_LINK_MALFORMED);
    expect_refused("szpdf://open?url=https%3A%2F%2Fex_ample.com%2Fa.pdf", SPDF_LINK_MALFORMED);
    expect_refused("szpdf://open?url=https%3A%2F%2Fexample.com%3A99999%2Fa.pdf", SPDF_LINK_MALFORMED);
    expect_refused("szpdf://open?url=https%3Aexample.com", SPDF_LINK_MALFORMED);
    expect_refused("szpdf://https/exa mple.com/a.pdf", SPDF_LINK_MALFORMED);
    expect_refused("szpdf://somewhere/else", SPDF_LINK_MALFORMED);
    {
        char longer[SPDF_LINK_MAX_BYTES + 64];
        snprintf(longer, sizeof(longer), "szpdf://https/example.com/");
        size_t n = strlen(longer);
        memset(longer + n, 'a', SPDF_LINK_MAX_BYTES);
        longer[SPDF_LINK_MAX_BYTES + 1] = '\0';
        expect_refused(longer, SPDF_LINK_TOO_LONG);
    }

    /* Where to open: a page, a chapter or section, a Markdown heading (by text, or a GitHub #slug). */
    expect_targets("szpdf://open?url=https%3A%2F%2Fexample.com%2Fa.pdf&section=Wiring%20diagram", 0, "Wiring diagram", "");
    expect_targets("szpdf://open?url=https%3A%2F%2Fexample.com%2Fbook.epub&chapter=Chapter%203", 0, "Chapter 3", "");
    expect_targets("szpdf://open?url=https%3A%2F%2Fexample.com%2FREADME.md&heading=Getting%20started", 0, "",
                   "Getting started");
    expect_targets("szpdf://open?url=https%3A%2F%2Fexample.com%2FREADME.md%23getting-started", 0, "", "getting-started");
    expect_targets("szpdf://https/example.com/README.md#getting-started", 0, "", "getting-started");
    expect_targets("szpdf://https/example.com/spec.pdf#section=Pin%20map", 0, "Pin map", "");
    expect_targets("szpdf://https/example.com/spec.pdf#nameddest=pinmap&page=4", 4, "pinmap", "");
    expect_targets("szpdf://https/example.com/notes.md#heading=%E5%AE%89%E8%A3%85", 0, "", "\xe5\xae\x89\xe8\xa3\x85");
    expect_targets("szpdf://open?url=https%3A%2F%2Fexample.com%2Fa.md%23intro&heading=Usage&page=2", 2, "", "Usage");
    {
        static const char* const headings[] = {"Introduction", "Getting Started!", "Usage", "FAQ", "Usage",
                                               "API \xe5\xae\x89\xe8\xa3\x85"};
        expect_match("Usage", headings, 6, 2);
        expect_match("getting started!", headings, 6, 1);
        expect_match("getting-started", headings, 6, 1);
        expect_match("Getting started", headings, 6, 1);
        expect_match("usage-1", headings, 6, 4);
        expect_match("api-\xe5\xae\x89\xe8\xa3\x85", headings, 6, 5);
        expect_match("Installation", headings, 6, -1);
        expect_match("", headings, 6, -1);
        static const char* const exact_first[] = {"faq", "FAQ"};
        expect_match("FAQ", exact_first, 2, 1);
    }

    /* The same link always lands on the same file; another address with the same name never does. */
    expect_cache("szpdf://https/example.com/docs/spec.pdf", "/spec.pdf");
    expect_cache("szpdf://https/example.com/download?id=7", "/download.pdf");
    expect_cache("szpdf://https/example.com/", "/Document.pdf");
    expect_cache("szpdf://open?url=https%3A%2F%2Fexample.com%2F%E6%96%87%E4%BB%B6.PDF", "/\xe6\x96\x87\xe4\xbb\xb6.PDF");
    expect_cache("szpdf://open?url=https%3A%2F%2Fexample.com%2F..%2F.hidden", "/_hidden.pdf");
    expect_cache("szpdf://open?url=https%3A%2F%2Fexample.com%2Fa%253Ab.pdf", "/a_b.pdf");
    expect_cache("szpdf://open?url=http%3A%2F%2F%5B%3A%3A1%5D%3A9000%2Fa.pdf", "/a.pdf");
    expect_cache("szpdf://https/example.com/docs/README.md#usage", "/README.md");
    expect_cache("szpdf://https/example.com/book.epub", "/book.epub");
    expect_cache("szpdf://https/example.com/v1.2/report", "/report.pdf");
    {
        spdf_link a, b;
        char pa[512], pb[512], again[512];
        spdf_link_parse("szpdf://https/example.com/one/spec.pdf", &a);
        spdf_link_parse("szpdf://https/example.com/two/spec.pdf", &b);
        spdf_link_cache_relative_path(&a, pa, sizeof(pa));
        spdf_link_cache_relative_path(&b, pb, sizeof(pb));
        spdf_link_parse("szpdf://open?url=https%3A%2F%2Fexample.com%2Fone%2Fspec.pdf", &a);
        spdf_link_cache_relative_path(&a, again, sizeof(again));
        if (strcmp(pa, pb) == 0 || strcmp(pa, again) != 0) {
            fprintf(stderr, "FAIL: cache paths %s / %s / %s\n", pa, pb, again);
            failures++;
        }
        if (spdf_link_cache_relative_path(&a, pa, 8)) {
            fprintf(stderr, "FAIL: a cache path that does not fit was written\n");
            failures++;
        }
    }

    if (failures) {
        fprintf(stderr, "SPDFCoreLinkTests: %d failure(s)\n", failures);
        return 1;
    }
    printf("SPDFCoreLinkTests passed\n");
    return 0;
}
