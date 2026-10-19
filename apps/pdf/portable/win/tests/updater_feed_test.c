/* updater_feed_test.c — the updater's pure feed half: version compare, the
 * GitHub release parse, the availability decision, the release-notes
 * formatter and the sha256 sidecar.
 *
 * A TRANSCRIPTION of portable/linux/gtk4/tests/updater_test.c's cases 1-11 and
 * test_parse_release, with the same fixtures, so that a decision this frontend
 * makes about a release is provably the decision the other two make. The
 * fixture's release body is hostile on purpose: it contains a spoofed
 * "assets" array inside a string and braces inside the highlights, and the
 * structural scanner must read past both.
 *
 * NO NETWORK, no clock, no window. Exit code is the whole signal.
 */
/* spdf-test-sources: portable/win/src/spdf_win_updater_feed.c portable/win/src/spdf_win_updater_version.c portable/win/src/spdf_win_updater_store.c */
#include "spdf_win_updater.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                      \
    do {                                                                                 \
        ++g_checks;                                                                      \
        if (!(cond)) {                                                                   \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);             \
            ++g_failures;                                                                \
        }                                                                                \
    } while (0)

#define CHECK_STR(got, want)                                                                                \
    do {                                                                                                    \
        ++g_checks;                                                                                         \
        if (!(got) || strcmp((got), (want)) != 0) {                                                         \
            fprintf(stderr, "FAIL %s == \"%s\" (got \"%s\") (%s:%d)\n", #got, (want), (got) ? (got) : "(null)", \
                    __FILE__, __LINE__);                                                                    \
            ++g_failures;                                                                                   \
        }                                                                                                   \
    } while (0)

/* --- 1-5. version compare ------------------------------------------------ */

static void test_version_compare(void) {
    CHECK(spdf_win_updater_compare_versions("26.6.25", "26.6.4") > 0); /* non-padded day; lexical would be wrong */
    CHECK(spdf_win_updater_compare_versions("26.6.11", "26.6.4") > 0);
    CHECK(spdf_win_updater_compare_versions("26.6.19-3", "26.6.19-1") > 0); /* build tiebreaker */
    CHECK(spdf_win_updater_compare_versions("26.6.25-1", "26.6.25-1") == 0);
    CHECK(spdf_win_updater_compare_versions("not-a-version", "26.6.25-1") == 0); /* malformed: no decision */
    CHECK(spdf_win_updater_compare_versions("v26.6.25", "26.6.25-1") == 0);
    CHECK(spdf_win_updater_compare_versions(NULL, "26.6.25-1") == 0);
    CHECK(spdf_win_updater_compare_versions("", "") == 0);
    /* A missing build suffix is a zero field: 26.6.25 == 26.6.25-0 < 26.6.25-1 */
    CHECK(spdf_win_updater_compare_versions("26.6.25", "26.6.25-1") < 0);
    CHECK(spdf_win_updater_compare_versions("26.6.25-0", "26.6.25") == 0);

    /* Relaunch health is strict: the complete YY.M.D-BUILD identity. */
    CHECK(spdf_win_updater_versions_match_release_target("26.7.17-2", "26.7.17-2"));
    CHECK(!spdf_win_updater_versions_match_release_target("26.7.17-2", "26.7.17-1"));
    CHECK(!spdf_win_updater_versions_match_release_target("26.7.17-2", "26.7.17"));
    CHECK(!spdf_win_updater_versions_match_release_target("26.7.17-2", "26.7.18-2"));
    CHECK(!spdf_win_updater_versions_match_release_target("junk", "26.7.17-2"));
    CHECK(!spdf_win_updater_versions_match_release_target(NULL, "26.7.17-2"));
}

/* --- 6. downgrade feed + the gates --------------------------------------- */

static void test_availability(void) {
    spdf_win_release_info rel;
    memset(&rel, 0, sizeof(rel));
    rel.tag = (char*)"26.6.19-3";
    rel.asset_url = (char*)"https://example.invalid/a.exe";
    rel.sidecar_url = (char*)"https://example.invalid/a.exe.sha256";

    CHECK(spdf_win_updater_release_available(&rel, "26.6.4-1", NULL));
    CHECK(spdf_win_updater_release_available(&rel, "26.6.4-1", "26.6.19-3"));  /* == high water */
    CHECK(!spdf_win_updater_release_available(&rel, "26.6.4-1", "26.6.25-1")); /* downgrade */

    rel.tag = (char*)"26.8.1-1";
    CHECK(spdf_win_updater_release_available(&rel, "26.7.17-1", NULL));
    CHECK(!spdf_win_updater_release_available(&rel, "26.8.1-1", NULL)); /* not newer */
    CHECK(!spdf_win_updater_release_available(&rel, "26.9.1-1", NULL)); /* older than running */
    rel.draft = 1;
    CHECK(!spdf_win_updater_release_available(&rel, "26.7.17-1", NULL));
    rel.draft = 0;
    rel.prerelease = 1;
    CHECK(!spdf_win_updater_release_available(&rel, "26.7.17-1", NULL));
    rel.prerelease = 0;
    rel.sidecar_url = NULL; /* an incomplete release is never offered */
    CHECK(!spdf_win_updater_release_available(&rel, "26.7.17-1", NULL));
    rel.sidecar_url = (char*)"https://example.invalid/a.exe.sha256";
    rel.asset_url = NULL;
    CHECK(!spdf_win_updater_release_available(&rel, "26.7.17-1", NULL));
    CHECK(!spdf_win_updater_release_available(NULL, "26.7.17-1", NULL));
}

/* --- 7-11. release notes ------------------------------------------------- */

static void test_format_notes(void) {
    char* notes;
    char body[4096];
    int i, chars;
    const char* p;

    /* 7. Bullets become U+2022 lines; details below the first rule dropped. */
    notes = spdf_win_updater_format_notes(
        "- First **bold** highlight\n- Second `code` highlight\n\n---\n\n### Details\n- hidden detail\n");
    CHECK_STR(notes, "\xE2\x80\xA2 First bold highlight\n\xE2\x80\xA2 Second code highlight");
    free(notes);

    /* 8. Hard-wrapped continuations rejoin their bullet; blank runs collapse. */
    notes = spdf_win_updater_format_notes("- A very long line\n  that was hard-wrapped\n\n\n- Next\n***\n- gone");
    CHECK_STR(notes, "\xE2\x80\xA2 A very long line that was hard-wrapped\n\xE2\x80\xA2 Next");
    free(notes);

    /* 9. Headers and quotes stripped; the bidi override removed; newline kept. */
    notes = spdf_win_updater_format_notes("## Heads up\n> quoted\nplain \xE2\x80\xAEtricky");
    CHECK_STR(notes, "Heads up\nquoted\nplain tricky");
    free(notes);

    /* CRLF bodies (GitHub's editor) format like LF bodies. */
    notes = spdf_win_updater_format_notes("- one\r\n- two\r\n");
    CHECK_STR(notes, "\xE2\x80\xA2 one\n\xE2\x80\xA2 two");
    free(notes);

    /* 10. Over-cap bodies are cut on a line boundary with an ellipsis line. */
    body[0] = '\0';
    for (i = 0; i < 40; ++i) {
        char line[64];
        snprintf(line, sizeof(line), "- highlight number %d padded out\n", i);
        strcat(body, line);
    }
    notes = spdf_win_updater_format_notes(body);
    CHECK(notes != NULL);
    chars = 0;
    for (p = notes; p && *p; ++p)
        if (((unsigned char)*p & 0xC0) != 0x80) ++chars;
    CHECK(chars <= 502);
    CHECK(notes && strlen(notes) > 4 && strcmp(notes + strlen(notes) - 4, "\n\xE2\x80\xA6") == 0);
    CHECK(notes && strstr(notes, "number 39") == NULL);
    free(notes);

    /* 11. NULL / empty input. */
    notes = spdf_win_updater_format_notes(NULL);
    CHECK_STR(notes, "");
    free(notes);
    notes = spdf_win_updater_format_notes("");
    CHECK_STR(notes, "");
    free(notes);
}

/* --- the release JSON ---------------------------------------------------- */

/* The GTK fixture with the Windows asset pair added. The body is HOSTILE: a
 * spoofed "assets" array inside a string, braces inside a highlight, a decoy
 * "assets" key nested under "author". */
static const char k_release_json[] =
    "{\n"
    "  \"url\": \"https://api.github.com/repos/casimir-engineering/shenzhen-pdf/releases/1\",\n"
    "  \"tag_name\": \"26.8.2-1\",\n"
    "  \"draft\": false,\n"
    "  \"prerelease\": false,\n"
    "  \"author\": {\"login\": \"raph\", \"assets\": [{\"name\": \"decoy\"}]},\n"
    "  \"body\": \"- Adds \\\"assets\\\": [{\\\"name\\\": \\\"ShenzhenPDF-win-x64.exe\\\"}] "
    "spoofing \\u00e9\\n- Real highlight {with braces}\\n\\n---\\nhidden\",\n"
    "  \"assets\": [\n"
    "    {\"name\": \"ShenzhenPDF-mac-arm64.dmg\", \"size\": 34210133,\n"
    "     \"browser_download_url\": \"https://github.com/x/releases/download/26.8.2-1/ShenzhenPDF-mac-arm64.dmg\"},\n"
    "    {\"name\": \"ShenzhenPDF-win-x64.exe\", \"size\": 23068672,\n"
    "     \"browser_download_url\": \"https://github.com/x/releases/download/26.8.2-1/ShenzhenPDF-win-x64.exe\"},\n"
    "    {\"name\": \"ShenzhenPDF-win-x64.exe.sha256\", \"size\": 90,\n"
    "     \"browser_download_url\": "
    "\"https://github.com/x/releases/download/26.8.2-1/ShenzhenPDF-win-x64.exe.sha256\"},\n"
    "    {\"name\": \"ShenzhenPDF-linux-amd64.tar.gz\", \"size\": 39845888,\n"
    "     \"browser_download_url\": "
    "\"https://github.com/x/releases/download/26.8.2-1/ShenzhenPDF-linux-amd64.tar.gz\"}\n"
    "  ]\n"
    "}\n";

static void test_parse_release(void) {
    spdf_win_release_info rel;
    char* draft_json;
    char* pos;

    CHECK(spdf_win_updater_parse_release(k_release_json, -1, SPDF_WIN_UPDATER_ASSET, SPDF_WIN_UPDATER_SIDECAR_SUFFIX,
                                         &rel));
    CHECK_STR(rel.tag, "26.8.2-1");
    CHECK(!rel.draft);
    CHECK(!rel.prerelease);
    CHECK_STR(rel.asset_url, "https://github.com/x/releases/download/26.8.2-1/ShenzhenPDF-win-x64.exe");
    CHECK(rel.asset_size == 23068672);
    CHECK_STR(rel.sidecar_url, "https://github.com/x/releases/download/26.8.2-1/ShenzhenPDF-win-x64.exe.sha256");
    CHECK(rel.notes != NULL);
    CHECK(rel.notes && strstr(rel.notes, "Real highlight {with braces}") != NULL);
    CHECK(rel.notes && strstr(rel.notes, "\xC3\xA9") != NULL); /* é decoded to UTF-8 */
    CHECK(spdf_win_updater_release_available(&rel, "26.7.17-1", NULL));
    /* And the formatter over the real body: the spoof line survives as text,
     * the hidden section does not. */
    {
        char* notes = spdf_win_updater_format_notes(rel.notes);
        CHECK(notes && strstr(notes, "hidden") == NULL);
        CHECK(notes && strncmp(notes, "\xE2\x80\xA2 Adds", 8) == 0);
        free(notes);
    }
    spdf_win_release_info_clear(&rel);
    CHECK(rel.tag == NULL && rel.asset_url == NULL);

    /* The tarball exists but has no sidecar: unavailable. */
    CHECK(spdf_win_updater_parse_release(k_release_json, -1, "ShenzhenPDF-linux-amd64.tar.gz", ".sha256", &rel));
    CHECK(rel.asset_url != NULL);
    CHECK(rel.sidecar_url == NULL);
    CHECK(!spdf_win_updater_release_available(&rel, "26.7.17-1", NULL));
    spdf_win_release_info_clear(&rel);

    /* Missing asset entirely. */
    CHECK(spdf_win_updater_parse_release(k_release_json, -1, "nonexistent.xyz", ".sha256", &rel));
    CHECK(rel.asset_url == NULL);
    CHECK(!spdf_win_updater_release_available(&rel, "26.7.17-1", NULL));
    spdf_win_release_info_clear(&rel);

    /* Draft flag honoured. */
    draft_json = (char*)malloc(sizeof(k_release_json));
    memcpy(draft_json, k_release_json, sizeof(k_release_json));
    pos = strstr(draft_json, "\"draft\": false");
    CHECK(pos != NULL);
    if (pos) memcpy(pos, "\"draft\": true ", strlen("\"draft\": true "));
    CHECK(spdf_win_updater_parse_release(draft_json, -1, SPDF_WIN_UPDATER_ASSET, ".sha256", &rel));
    CHECK(rel.draft);
    CHECK(!spdf_win_updater_release_available(&rel, "26.7.17-1", NULL));
    spdf_win_release_info_clear(&rel);
    free(draft_json);

    /* Malformed / hostile inputs never "succeed". */
    CHECK(!spdf_win_updater_parse_release("{\"tag_name\": \"26.8.2-1\"", -1, "a.exe", ".sha256", &rel));
    CHECK(!spdf_win_updater_parse_release("[]", -1, "a.exe", ".sha256", &rel));
    CHECK(!spdf_win_updater_parse_release("{}", -1, "a.exe", ".sha256", &rel)); /* no tag_name */
    CHECK(!spdf_win_updater_parse_release("{\"tag_name\": \"\"}", -1, "a.exe", ".sha256", &rel));
    CHECK(!spdf_win_updater_parse_release(NULL, -1, "a.exe", ".sha256", &rel));
    CHECK(!spdf_win_updater_parse_release("{\"tag_name\": \"1\", \"assets\": [{\"name\": 5}]", -1, "a", "", &rel));
    /* An explicit length that stops short of the closing brace is malformed. */
    CHECK(!spdf_win_updater_parse_release(k_release_json, (long)sizeof(k_release_json) / 2, "a.exe", "", &rel));
}

/* --- the sidecar --------------------------------------------------------- */

static void test_sidecar(void) {
    char hex[65];
    const char* digest = "A3F1e9c2b4d6f8a0c1e2d3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3B4";

    CHECK(spdf_win_updater_parse_sha256_sidecar(
        "a3f1e9c2b4d6f8a0c1e2d3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4  ShenzhenPDF-win-x64.exe\n", hex,
        sizeof(hex)));
    CHECK_STR(hex, "a3f1e9c2b4d6f8a0c1e2d3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4");
    CHECK(spdf_win_updater_parse_sha256_sidecar(digest, hex, sizeof(hex))); /* bare, mixed case */
    CHECK_STR(hex, "a3f1e9c2b4d6f8a0c1e2d3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4");
    CHECK(spdf_win_updater_parse_sha256_sidecar(
        "a3f1e9c2b4d6f8a0c1e2d3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4 *binary", hex, sizeof(hex)));
    CHECK(!spdf_win_updater_parse_sha256_sidecar("a3f1e9c2b4d6f8a0c1e2d3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3", hex,
                                                 sizeof(hex))); /* 62 digits */
    CHECK(!spdf_win_updater_parse_sha256_sidecar(
        "a3f1e9c2b4d6f8a0c1e2d3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4f", hex, sizeof(hex))); /* 65 */
    CHECK(!spdf_win_updater_parse_sha256_sidecar("not a digest at all", hex, sizeof(hex)));
    CHECK(!spdf_win_updater_parse_sha256_sidecar("", hex, sizeof(hex)));
    CHECK(!spdf_win_updater_parse_sha256_sidecar(NULL, hex, sizeof(hex)));
    CHECK(!spdf_win_updater_parse_sha256_sidecar(digest, hex, 10)); /* too small an out buffer */
}

int main(void) {
    test_version_compare();
    test_availability();
    test_format_notes();
    test_parse_release();
    test_sidecar();
    printf("updater_feed_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
