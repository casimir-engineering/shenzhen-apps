/* spdf_link.h -- szpdf: links, the way a web page opens a document in ShenzhenPDF.
 *
 *   szpdf://open?url=<percent-encoded address>[&page=N][&section=<title or id>][&heading=<text or slug>]
 *   szpdf://https/<host>[:port]/<path>[?query][#page=N | #section=... | #heading=... | #<heading slug>]
 *
 * Both name one document by its address, of any type the reader opens, and optionally where to open it: a page, a
 * chapter or section (a PDF outline entry or named destination, an EPUB chapter), or a Markdown heading by its text
 * or by the slug GitHub gives it (so a #fragment copied from GitHub works). Only https is accepted, and http only
 * to this computer (localhost, 127.0.0.1, [::1]) so a site can be tried out locally; anything else (file:,
 * javascript:, ftp:, http to another host, an address with a user name or password in it) is refused before
 * anything is fetched. A link only ever
 * names a document to download and show: nothing in it is run. The format is documented in
 * docs/szpdf-links.md.
 *
 * Pure C, no allocation the caller does not own, no I/O: shared by every frontend and tested headlessly
 * (core/tests/SPDFCoreLinkTests.c).
 */
#ifndef SPDF_LINK_H
#define SPDF_LINK_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum spdf_link_status {
    SPDF_LINK_OK = 0,
    SPDF_LINK_NOT_SZPDF,      /* not an szpdf: link at all */
    SPDF_LINK_MALFORMED,      /* szpdf:, but no document address can be read from it */
    SPDF_LINK_UNSUPPORTED,    /* the address is not https (file:, javascript:, ftp:, http to another computer) */
    SPDF_LINK_CREDENTIALS,    /* the address carries a user name or password */
    SPDF_LINK_TOO_LONG        /* longer than SPDF_LINK_MAX_BYTES */
} spdf_link_status;

#define SPDF_LINK_MAX_BYTES 4096
#define SPDF_LINK_MAX_PAGE 1000000

typedef struct spdf_link {
    char url[SPDF_LINK_MAX_BYTES + 1]; /* the document's address: https://host[:port]/path[?query], no fragment */
    char host[256];                    /* lowercase host, without port or brackets */
    int page;                          /* 1-based page to show, 0 when the link names none */
    char section[512];                 /* chapter or section to open at (outline title or id), "" for none */
    char heading[512];                 /* Markdown heading (text or slug), "" for none */
} spdf_link;

/* Reads an szpdf: link. On SPDF_LINK_OK `out` holds the document's address and where to open it; otherwise `out`
 * is zeroed. */
spdf_link_status spdf_link_parse(const char* text, spdf_link* out);

/* A short sentence for the person who clicked a refused link (status != OK), or "" for SPDF_LINK_OK. */
const char* spdf_link_refusal_message(spdf_link_status status);

/* Where a link's document is kept, relative to the app's storage: "<host>/<16 hex digits>/<file name>". The digits
 * are a hash of the whole address, so the same link always comes back to the same file (and the tab already showing
 * it), while two documents with one name on one site never share a file. The name is the address's last path
 * segment, percent-decoded, with characters a file name cannot hold replaced, and ".pdf" added when it has no
 * extension (an address without one is taken to be a PDF); "Document.pdf" when the address has no name. Returns 0
 * when `cap` is too small. */
int spdf_link_cache_relative_path(const spdf_link* link, char* out, size_t cap);

/* GitHub's slug for a heading: lowercase, spaces to hyphens, punctuation dropped ("Getting Started!" ->
 * "getting-started"). Bytes past ASCII (letters of other scripts) are kept as they are. */
void spdf_link_slug(const char* text, char* out, size_t cap);

/* Which of `titles` (in document order) a link's section or heading names: the first exact match, else the first
 * that matches ignoring case, else the first whose slug matches the wanted text or its slug, counting repeated slugs
 * the way GitHub numbers them ("intro", "intro-1", ...). -1 when none does. */
int spdf_link_match_title(const char* wanted, const char* const* titles, int count);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_LINK_H */
