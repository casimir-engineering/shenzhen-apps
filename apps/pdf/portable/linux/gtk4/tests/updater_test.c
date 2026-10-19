// Pure-logic tests for spdf_updater.c (glib + openssl only, no GTK; the app
// wiring is compiled out via SPDF_UPDATER_TESTING). Mirrors the Mac suite
// portable/mac/SPDFUpdaterTests.mm: version compare, downgrade feed,
// release-notes formatting, daily-gate delay — plus the Linux-specific
// layers: minisign parse/verify against committed fixtures (see
// fixtures/generate.sh), GitHub release JSON parse, availability decision,
// update.json store round-trip.
#define SPDF_UPDATER_TESTING 1

#include "../spdf_update_version.c"
#include "../spdf_updater.c"

// Fixture files live next to this test; the Makefile runs test binaries from
// portable/, so the relative path resolves there. SPDF_FIXTURES_DIR overrides.
static char* fixture_path(const char* name) {
    const char* dir = g_getenv("SPDF_FIXTURES_DIR");
    if (!dir) dir = "linux/gtk4/tests/fixtures";
    return g_build_filename(dir, name, NULL);
}

static char* fixture_text(const char* name) {
    char* path = fixture_path(name);
    char* contents = NULL;
    if (!g_file_get_contents(path, &contents, NULL, NULL))
        g_error(
            "fixture missing: %s (run from portable/, or set SPDF_FIXTURES_DIR; "
            "regenerate with tests/fixtures/generate.sh)",
            path);
    g_free(path);
    return contents;
}

// ---------------------------------------------------------------------------
// Version compare (SPDFUpdaterTests.mm cases 1-6)

static void test_version_compare(void) {
    // 1. 26.6.25 > 26.6.4 (non-padded day; lexical would be wrong)
    g_assert_cmpint(spdf_updater_compare_versions("26.6.25", "26.6.4"), >, 0);
    // 2. 26.6.11 > 26.6.4 (multi-digit day)
    g_assert_cmpint(spdf_updater_compare_versions("26.6.11", "26.6.4"), >, 0);
    // 3. 26.6.19-3 > 26.6.19-1 (build tiebreaker)
    g_assert_cmpint(spdf_updater_compare_versions("26.6.19-3", "26.6.19-1"), >, 0);
    // 4. 26.6.25-1 == 26.6.25-1 (no update)
    g_assert_cmpint(spdf_updater_compare_versions("26.6.25-1", "26.6.25-1"), ==, 0);
    // 5. malformed input -> ordered-same / no update
    g_assert_cmpint(spdf_updater_compare_versions("not-a-version", "26.6.25-1"), ==, 0);
    g_assert_cmpint(spdf_updater_compare_versions(NULL, "26.6.25-1"), ==, 0);
    g_assert_cmpint(spdf_updater_compare_versions("", ""), ==, 0);
    // Missing build suffix is a zero field: 26.6.25 == 26.6.25-0 < 26.6.25-1
    g_assert_cmpint(spdf_updater_compare_versions("26.6.25", "26.6.25-1"), <, 0);

    // The legacy primary-date matcher intentionally ignores -BUILD.
    g_assert_true(spdf_updater_versions_match_primary("26.7.17-2", "26.7.17-1"));
    g_assert_false(spdf_updater_versions_match_primary("26.7.18-1", "26.7.17-1"));
    g_assert_false(spdf_updater_versions_match_primary("26.7", "26.7.17"));
    g_assert_false(spdf_updater_versions_match_primary("junk", "26.7.17-1"));

    // Relaunch health is stricter: the complete YY.M.DD-BUILD identity must
    // match before update_ok is written or the rollback binary is deleted.
    g_assert_true(spdf_update_versions_match_release_target("26.7.17-2", "26.7.17-2"));
    g_assert_false(spdf_update_versions_match_release_target("26.7.17-2", "26.7.17-1"));
    g_assert_false(spdf_update_versions_match_release_target("26.7.17-2", "26.7.17"));
    g_assert_false(spdf_update_versions_match_release_target("26.7.17-2", "26.7.18-2"));
    g_assert_false(spdf_update_versions_match_release_target("junk", "26.7.17-2"));
}

// 6. Downgrade feed: tag < highestVersionSeen -> no update even when
//    tag > running (exercised through the real availability predicate).
static void test_downgrade_feed(void) {
    SpdfReleaseInfo rel = {0};
    rel.tag = (char*)"26.6.19-3";
    rel.asset_url = (char*)"https://example.invalid/a.deb";
    rel.sig_url = (char*)"https://example.invalid/a.deb.minisig";

    g_assert_true(spdf_updater_release_available(&rel, "26.6.4-1", NULL));
    g_assert_true(spdf_updater_release_available(&rel, "26.6.4-1", "26.6.19-3"));  // == high water
    g_assert_false(spdf_updater_release_available(&rel, "26.6.4-1", "26.6.25-1")); // downgrade
}

static void test_availability_gates(void) {
    SpdfReleaseInfo rel = {0};
    rel.tag = (char*)"26.8.1-1";
    rel.asset_url = (char*)"https://example.invalid/a.deb";
    rel.sig_url = (char*)"https://example.invalid/a.deb.minisig";

    g_assert_true(spdf_updater_release_available(&rel, "26.7.17-1", NULL));
    g_assert_false(spdf_updater_release_available(&rel, "26.8.1-1", NULL)); // not newer
    g_assert_false(spdf_updater_release_available(&rel, "26.9.1-1", NULL)); // older than running

    rel.draft = TRUE;
    g_assert_false(spdf_updater_release_available(&rel, "26.7.17-1", NULL));
    rel.draft = FALSE;
    rel.prerelease = TRUE;
    g_assert_false(spdf_updater_release_available(&rel, "26.7.17-1", NULL));
    rel.prerelease = FALSE;

    rel.sig_url = NULL; // unsigned release must never be offered
    g_assert_false(spdf_updater_release_available(&rel, "26.7.17-1", NULL));
    rel.sig_url = (char*)"https://example.invalid/a.deb.minisig";
    rel.asset_url = NULL;
    g_assert_false(spdf_updater_release_available(&rel, "26.7.17-1", NULL));
}

// ---------------------------------------------------------------------------
// Daily-gate delay (SPDFUpdaterTests.mm cases 12-16)

static void test_daily_check_delay(void) {
    const gint64 now = 1800000000;

    // 12. Fresh install: no stamp yet -> due immediately.
    g_assert_cmpint(spdf_updater_daily_check_delay(TRUE, FALSE, 0, now), ==, 0);
    // 13. Checked 2h ago -> gated for the remaining 22h.
    g_assert_cmpint(spdf_updater_daily_check_delay(TRUE, TRUE, now - 7200, now), ==, 86400 - 7200);
    // 14. Long sleep past the gate (30h) -> due immediately.
    g_assert_cmpint(spdf_updater_daily_check_delay(TRUE, TRUE, now - 30 * 3600, now), ==, 0);
    // 15. Day changed but only 40min elapsed: rolling window stays closed.
    g_assert_cmpint(spdf_updater_daily_check_delay(TRUE, TRUE, now - 2400, now), ==, 86400 - 2400);
    // 16. autoUpdate disabled -> never fires, even when long overdue.
    g_assert_cmpint(spdf_updater_daily_check_delay(FALSE, TRUE, now - 30 * 3600, now), ==, -1);
    // Backwards clock: gate stays closed (delay > 0, not due).
    g_assert_cmpint(spdf_updater_daily_check_delay(TRUE, TRUE, now + 7200, now), >, 0);
}

// ---------------------------------------------------------------------------
// Release-notes formatting (SPDFUpdaterTests.mm cases 7-11)

static void test_format_notes(void) {
    char* notes;

    // 7. Bullets become "• " lines; details below the first rule dropped.
    notes = spdf_updater_format_notes(
        "- First **bold** highlight\n- Second `code` highlight\n\n---\n\n### Details\n- hidden detail\n");
    g_assert_cmpstr(notes, ==, "\xE2\x80\xA2 First bold highlight\n\xE2\x80\xA2 Second code highlight");
    g_free(notes);

    // 8. Hard-wrapped continuation lines rejoin their bullet; blank runs collapse.
    notes = spdf_updater_format_notes("- A very long line\n  that was hard-wrapped\n\n\n- Next\n***\n- gone");
    g_assert_cmpstr(notes, ==, "\xE2\x80\xA2 A very long line that was hard-wrapped\n\xE2\x80\xA2 Next");
    g_free(notes);

    // 9. Headers/quotes stripped; bidi override removed; newline kept.
    notes = spdf_updater_format_notes("## Heads up\n> quoted\nplain \xE2\x80\xAEtricky");
    g_assert_cmpstr(notes, ==, "Heads up\nquoted\nplain tricky");
    g_free(notes);

    // 10. Over-cap bodies cut on a line boundary with an ellipsis line.
    {
        GString* body = g_string_new("");
        for (int i = 0; i < 40; ++i) g_string_append_printf(body, "- highlight number %d padded out\n", i);
        notes = spdf_updater_format_notes(body->str);
        g_assert_cmpint((int)g_utf8_strlen(notes, -1), <=, 502);
        g_assert_true(g_str_has_suffix(notes, "\n\xE2\x80\xA6"));
        g_free(notes);
        g_string_free(body, TRUE);
    }

    // 11. NULL / empty input.
    notes = spdf_updater_format_notes(NULL);
    g_assert_cmpstr(notes, ==, "");
    g_free(notes);
    notes = spdf_updater_format_notes("");
    g_assert_cmpstr(notes, ==, "");
    g_free(notes);
}

// ---------------------------------------------------------------------------
// Minisign parse + verify (fixtures: see fixtures/generate.sh)

static void test_minisign_pinned_key_parses(void) {
    SpdfMinisignKey key;
    char* error = NULL;
    // The production key pinned in spdf_updater.c (key id 95F72498E795D0DD,
    // stored little-endian in the blob).
    const guint8 expected_id[8] = {0xDD, 0xD0, 0x95, 0xE7, 0x98, 0x24, 0xF7, 0x95};

    g_assert_true(spdf_minisign_parse_pubkey(k_spdf_pinned_pubkey, &key, &error));
    g_assert_null(error);
    g_assert_cmpmem(key.key_id, 8, expected_id, 8);
}

static void test_minisign_parse_rejects_garbage(void) {
    SpdfMinisignKey key;
    SpdfMinisignSig sig;
    char* error = NULL;

    g_assert_false(spdf_minisign_parse_pubkey("not base64 at all!!", &key, &error));
    g_clear_pointer(&error, g_free);
    g_assert_false(spdf_minisign_parse_pubkey("QUJD", &key, &error)); // wrong length
    g_clear_pointer(&error, g_free);
    g_assert_false(spdf_minisign_parse_pubkey(NULL, &key, &error));
    g_clear_pointer(&error, g_free);
    // Wrong algorithm tag ("Xd" + 40 bytes).
    {
        guint8 blob[42] = {'X', 'd'};
        char* b64 = g_base64_encode(blob, sizeof(blob));
        g_assert_false(spdf_minisign_parse_pubkey(b64, &key, &error));
        g_clear_pointer(&error, g_free);
        g_free(b64);
    }

    g_assert_false(spdf_minisign_parse_sig("untrusted comment: only a comment\n", &sig, &error));
    g_clear_pointer(&error, g_free);
    g_assert_false(spdf_minisign_parse_sig("QUJD\n", &sig, &error)); // 3 bytes, not 74
    g_clear_pointer(&error, g_free);
}

static void test_minisign_verify_prehashed(void) {
    char* pub_text = fixture_text("testkey.pub");
    char* sig_text = fixture_text("blob.bin.minisig");
    char* blob = NULL;
    gsize blob_len = 0;
    SpdfMinisignKey key;
    SpdfMinisignSig sig;
    char* error = NULL;
    char* blob_path = fixture_path("blob.bin");

    g_assert_true(g_file_get_contents(blob_path, &blob, &blob_len, NULL));
    g_assert_true(spdf_minisign_parse_pubkey(pub_text, &key, &error));
    g_assert_true(spdf_minisign_parse_sig(sig_text, &sig, &error));
    g_assert_true(sig.prehashed); // minisign -S default is the "ED" mode
    g_assert_true(sig.has_global_sig);
    g_assert_nonnull(sig.trusted_comment);

    // Valid signature over the committed blob.
    g_assert_true(spdf_minisign_verify_buffer(&key, &sig, (const guint8*)blob, blob_len, &error));
    g_assert_null(error);

    // Whole-file convenience wrapper.
    g_assert_true(spdf_minisign_verify_file(&key, sig_text, blob_path, &error));
    g_assert_null(error);

    // Tampered payload must fail.
    blob[0] ^= 0x01;
    g_assert_false(spdf_minisign_verify_buffer(&key, &sig, (const guint8*)blob, blob_len, &error));
    g_assert_nonnull(error);
    g_clear_pointer(&error, g_free);
    blob[0] ^= 0x01;

    // Wrong key (the pinned production key): keyid mismatch.
    {
        SpdfMinisignKey pinned;
        g_assert_true(spdf_minisign_parse_pubkey(k_spdf_pinned_pubkey, &pinned, NULL));
        g_assert_false(spdf_minisign_verify_buffer(&pinned, &sig, (const guint8*)blob, blob_len, &error));
        g_assert_nonnull(error);
        g_assert_nonnull(strstr(error, "key id"));
        g_clear_pointer(&error, g_free);
    }
    spdf_minisign_sig_clear(&sig);

    // Corrupted signature fixture: parses, fails Ed25519 verification.
    {
        char* corrupt_text = fixture_text("blob.bin.corrupt.minisig");
        g_assert_true(spdf_minisign_parse_sig(corrupt_text, &sig, &error));
        g_assert_false(spdf_minisign_verify_buffer(&key, &sig, (const guint8*)blob, blob_len, &error));
        g_assert_nonnull(error);
        g_clear_pointer(&error, g_free);
        spdf_minisign_sig_clear(&sig);
        g_free(corrupt_text);
    }

    g_free(blob_path);
    g_free(blob);
    g_free(sig_text);
    g_free(pub_text);
}

static void test_minisign_verify_legacy(void) {
    char* pub_text = fixture_text("legacy.pub");
    char* sig_text = fixture_text("blob.bin.legacy.minisig");
    char* blob = NULL;
    gsize blob_len = 0;
    SpdfMinisignKey key;
    SpdfMinisignSig sig;
    char* error = NULL;
    char* blob_path = fixture_path("blob.bin");

    g_assert_true(g_file_get_contents(blob_path, &blob, &blob_len, NULL));
    g_assert_true(spdf_minisign_parse_pubkey(pub_text, &key, &error));
    g_assert_true(spdf_minisign_parse_sig(sig_text, &sig, &error));
    g_assert_false(sig.prehashed); // "Ed": Ed25519 over the raw content
    g_assert_true(sig.has_global_sig);

    g_assert_true(spdf_minisign_verify_buffer(&key, &sig, (const guint8*)blob, blob_len, &error));
    g_assert_null(error);

    // Same legacy signature against a tampered blob fails.
    blob[3] ^= 0x40;
    g_assert_false(spdf_minisign_verify_buffer(&key, &sig, (const guint8*)blob, blob_len, &error));
    g_clear_pointer(&error, g_free);

    // A truncated trusted-comment section (comment without global sig) fails.
    sig.has_global_sig = FALSE;
    blob[3] ^= 0x40;
    g_assert_false(spdf_minisign_verify_buffer(&key, &sig, (const guint8*)blob, blob_len, &error));
    g_assert_nonnull(strstr(error, "incomplete"));
    g_clear_pointer(&error, g_free);

    spdf_minisign_sig_clear(&sig);
    g_free(blob_path);
    g_free(blob);
    g_free(sig_text);
    g_free(pub_text);
}

// ---------------------------------------------------------------------------
// GitHub release JSON parse (offline fixture, like the Mac tests). The body
// deliberately embeds JSON-looking text — a structural parser must not be
// fooled by quotes/braces/asset-like content inside strings.

static const char k_release_json[] =
    "{\n"
    "  \"url\": \"https://api.github.com/repos/casimir-engineering/shenzhen-pdf/releases/1\",\n"
    "  \"tag_name\": \"26.8.2-1\",\n"
    "  \"draft\": false,\n"
    "  \"prerelease\": false,\n"
    "  \"author\": {\"login\": \"raph\", \"assets\": [{\"name\": \"decoy\"}]},\n"
    "  \"body\": \"- Adds \\\"assets\\\": [{\\\"name\\\": \\\"ShenzhenPDF-linux-amd64.deb\\\"}] "
    "spoofing \\u00e9\\n- Real highlight {with braces}\\n\\n---\\nhidden\",\n"
    "  \"assets\": [\n"
    "    {\"name\": \"ShenzhenPDF-mac-arm64.dmg\", \"size\": 34210133,\n"
    "     \"browser_download_url\": \"https://github.com/x/releases/download/26.8.2-1/ShenzhenPDF-mac-arm64.dmg\"},\n"
    "    {\"name\": \"ShenzhenPDF-linux-amd64.deb\", \"size\": 41943040,\n"
    "     \"browser_download_url\": \"https://github.com/x/releases/download/26.8.2-1/ShenzhenPDF-linux-amd64.deb\"},\n"
    "    {\"name\": \"ShenzhenPDF-linux-amd64.deb.minisig\", \"size\": 313,\n"
    "     \"browser_download_url\": "
    "\"https://github.com/x/releases/download/26.8.2-1/ShenzhenPDF-linux-amd64.deb.minisig\"},\n"
    "    {\"name\": \"ShenzhenPDF-linux-amd64.tar.gz\", \"size\": 39845888,\n"
    "     \"browser_download_url\": "
    "\"https://github.com/x/releases/download/26.8.2-1/ShenzhenPDF-linux-amd64.tar.gz\"}\n"
    "  ]\n"
    "}\n";

static void test_parse_release(void) {
    SpdfReleaseInfo rel;

    g_assert_true(spdf_updater_parse_release(k_release_json, -1, "ShenzhenPDF-linux-amd64.deb", &rel));
    g_assert_cmpstr(rel.tag, ==, "26.8.2-1");
    g_assert_false(rel.draft);
    g_assert_false(rel.prerelease);
    g_assert_cmpstr(rel.asset_url, ==, "https://github.com/x/releases/download/26.8.2-1/ShenzhenPDF-linux-amd64.deb");
    g_assert_cmpint(rel.asset_size, ==, 41943040);
    g_assert_cmpstr(rel.sig_url, ==,
                    "https://github.com/x/releases/download/26.8.2-1/ShenzhenPDF-linux-amd64.deb.minisig");
    g_assert_nonnull(rel.notes);
    g_assert_nonnull(strstr(rel.notes, "Real highlight {with braces}"));
    g_assert_nonnull(strstr(rel.notes, "\xC3\xA9")); // é decoded
    g_assert_true(spdf_updater_release_available(&rel, "26.7.17-1", NULL));
    spdf_release_info_clear(&rel);

    // Tarball flavour: the .tar.gz asset exists but ships no .minisig, so a
    // user-local install must see it as unavailable (unsigned).
    g_assert_true(spdf_updater_parse_release(k_release_json, -1, "ShenzhenPDF-linux-amd64.tar.gz", &rel));
    g_assert_nonnull(rel.asset_url);
    g_assert_null(rel.sig_url);
    g_assert_false(spdf_updater_release_available(&rel, "26.7.17-1", NULL));
    spdf_release_info_clear(&rel);

    // Missing asset entirely.
    g_assert_true(spdf_updater_parse_release(k_release_json, -1, "nonexistent.xyz", &rel));
    g_assert_null(rel.asset_url);
    g_assert_false(spdf_updater_release_available(&rel, "26.7.17-1", NULL));
    spdf_release_info_clear(&rel);

    // Draft flag honoured.
    {
        char* draft_json = g_strdup(k_release_json);
        char* pos = strstr(draft_json, "\"draft\": false");
        memcpy(pos, "\"draft\": true ", strlen("\"draft\": true "));
        g_assert_true(spdf_updater_parse_release(draft_json, -1, "ShenzhenPDF-linux-amd64.deb", &rel));
        g_assert_true(rel.draft);
        g_assert_false(spdf_updater_release_available(&rel, "26.7.17-1", NULL));
        spdf_release_info_clear(&rel);
        g_free(draft_json);
    }

    // Malformed / hostile inputs never "succeed".
    g_assert_false(spdf_updater_parse_release("{\"tag_name\": \"26.8.2-1\"", -1, "a.deb", &rel));
    g_assert_false(spdf_updater_parse_release("[]", -1, "a.deb", &rel));
    g_assert_false(spdf_updater_parse_release("{}", -1, "a.deb", &rel)); // no tag_name
    g_assert_false(spdf_updater_parse_release(NULL, -1, "a.deb", &rel));
}

// ---------------------------------------------------------------------------
// update.json store round-trip

static void test_store_roundtrip(void) {
    SpdfUpdateStore store = {0};
    SpdfUpdateStore parsed;
    char* json;

    store.last_check = 1800000123;
    store.etag = (char*)"W/\"abc\tdef\"";
    store.highest_seen = (char*)"26.8.2-1";
    store.deferred_tag = (char*)"26.8.2-1";
    store.remind_after = 1800604923;
    store.pending_tag = (char*)"26.8.2-1";
    store.update_ok = (char*)"26.7.17-1";
    store.lease_pid = 4242;
    store.lease_ts = 1800000200;

    json = spdf_update_store_serialize(&store);
    spdf_update_store_parse(json, -1, &parsed);
    g_assert_cmpint(parsed.last_check, ==, store.last_check);
    g_assert_cmpstr(parsed.etag, ==, store.etag);
    g_assert_cmpstr(parsed.highest_seen, ==, store.highest_seen);
    g_assert_cmpstr(parsed.deferred_tag, ==, store.deferred_tag);
    g_assert_cmpint(parsed.remind_after, ==, store.remind_after);
    g_assert_cmpstr(parsed.pending_tag, ==, store.pending_tag);
    g_assert_cmpstr(parsed.update_ok, ==, store.update_ok);
    g_assert_cmpint(parsed.lease_pid, ==, store.lease_pid);
    g_assert_cmpint(parsed.lease_ts, ==, store.lease_ts);
    spdf_update_store_clear(&parsed);
    g_free(json);

    // Empty / absent / corrupt files parse to a zeroed store.
    spdf_update_store_parse(NULL, -1, &parsed);
    g_assert_cmpint(parsed.last_check, ==, 0);
    g_assert_null(parsed.pending_tag);
    spdf_update_store_parse("garbage{{{", -1, &parsed);
    g_assert_cmpint(parsed.last_check, ==, 0);
    spdf_update_store_clear(&parsed);
}

// Mac SPDFUpdater.mm shapes: snake_case "update_ok" and the in-progress
// lease as a nested {"pid","timestamp"} object (fractional seconds). A
// Mac-written update.json must yield the same store as the Linux spelling —
// otherwise the Linux updater misses the healthy-relaunch marker and can
// grab an overlapping lease.
static void test_store_parses_mac_format(void) {
    SpdfUpdateStore parsed;
    static const char* kMacUpdateFixture =
        "{\n"
        "  \"etag\" : \"W/\\\"zz\\\"\",\n"
        "  \"highestVersionSeen\" : \"26.8.2-1\",\n"
        "  \"lastUpdateCheck\" : 1800000123.25,\n"
        "  \"update_ok\" : \"26.7.17-1\",\n"
        "  \"updateInProgress\" : {\n"
        "    \"pid\" : 4242,\n"
        "    \"timestamp\" : 1800000200.75\n"
        "  }\n"
        "}";

    spdf_update_store_parse(kMacUpdateFixture, -1, &parsed);
    g_assert_cmpstr(parsed.etag, ==, "W/\"zz\"");
    g_assert_cmpstr(parsed.highest_seen, ==, "26.8.2-1");
    g_assert_cmpint(parsed.last_check, ==, 1800000123); // fraction truncated
    g_assert_cmpstr(parsed.update_ok, ==, "26.7.17-1");
    g_assert_cmpint(parsed.lease_pid, ==, 4242);
    g_assert_cmpint(parsed.lease_ts, ==, 1800000200);
    spdf_update_store_clear(&parsed);
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    test_version_compare();
    test_downgrade_feed();
    test_availability_gates();
    test_daily_check_delay();
    test_format_notes();
    test_minisign_pinned_key_parses();
    test_minisign_parse_rejects_garbage();
    test_minisign_verify_prehashed();
    test_minisign_verify_legacy();
    test_parse_release();
    test_store_roundtrip();
    test_store_parses_mac_format();
    g_print(
        "updater_test passed (version compare, daily gate, notes, minisign, "
        "release parse, store)\n");
    return 0;
}
