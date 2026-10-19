/* Properties-panel formatting tests (spdf_props_internal.h). glib-only;
 * build via `make -C portable linux-gtk4-tests`.
 *
 * Mirrors mac/tests/SPDFMacPropertiesFormatTests.mm case for case: PDF-date
 * parsing (offsets, apostrophe variants, progressive truncation, rejection
 * of partial fields / out-of-range components / malformed offsets), file
 * sizes (1000-based units + grouped byte counts), page-size strings
 * (pt/mm/in) and security summaries (denied-permission list joins). The
 * word-count helper is not ported (the Linux panel has no Text row). */

#include <glib.h>

#include "spdf_props_internal.h"

/* Expected instant built in an explicit zone so the test is host-timezone
 * independent (except the deliberate local-time cases, which compute their
 * expectation with the local zone too). */
static GDateTime* date_in_zone(int year, int month, int day, int hour, int minute, int second, GTimeZone* zone) {
    return g_date_time_new(zone, year, month, day, hour, minute, (gdouble)second);
}

static void expect_date(const char* raw, GDateTime* expected /* takes ownership; may be NULL */) {
    GDateTime* actual = spdf_props_parse_pdf_date(raw);

    if (expected == NULL) {
        if (actual != NULL) {
            char* text = g_date_time_format_iso8601(actual);
            g_error("input \"%s\": expected NULL, got %s", raw, text);
        }
    } else {
        if (actual == NULL) g_error("input \"%s\": expected a date, got NULL", raw);
        g_assert_cmpint(g_date_time_to_unix(actual), ==, g_date_time_to_unix(expected));
    }
    if (actual) g_date_time_unref(actual);
    if (expected) g_date_time_unref(expected);
}

static void test_parse_pdf_date(void) {
    GTimeZone* utc = g_time_zone_new_utc();
    GTimeZone* plus8 = g_time_zone_new_offset(8 * 3600);
    GTimeZone* plus0530 = g_time_zone_new_offset(5 * 3600 + 30 * 60);
    GTimeZone* minus0530 = g_time_zone_new_offset(-(5 * 3600 + 30 * 60));
    GTimeZone* local = g_time_zone_new_local();

    /* Full spec form with positive offset. */
    expect_date("D:20240131235959+08'00'", date_in_zone(2024, 1, 31, 23, 59, 59, plus8));
    /* Negative offset with minutes. */
    expect_date("D:19990704120000-05'30'", date_in_zone(1999, 7, 4, 12, 0, 0, minus0530));
    /* UTC marker, bare and with the Acrobat-style Z00'00' tail. */
    expect_date("D:20200229120000Z", date_in_zone(2020, 2, 29, 12, 0, 0, utc));
    expect_date("D:20200229120000Z00'00'", date_in_zone(2020, 2, 29, 12, 0, 0, utc));
    /* Apostrophe variants: missing trailing, missing both. */
    expect_date("D:20240101000000+05'30", date_in_zone(2024, 1, 1, 0, 0, 0, plus0530));
    expect_date("D:20240101000000+0800", date_in_zone(2024, 1, 1, 0, 0, 0, plus8));
    /* Hour-only offset. */
    expect_date("D:20240101000000+08", date_in_zone(2024, 1, 1, 0, 0, 0, plus8));
    /* No offset = local time. */
    expect_date("D:20231115093000", date_in_zone(2023, 11, 15, 9, 30, 0, local));
    /* Progressive truncation: seconds, then time, day, month absent. */
    expect_date("D:202311150930", date_in_zone(2023, 11, 15, 9, 30, 0, local));
    expect_date("D:20231115", date_in_zone(2023, 11, 15, 0, 0, 0, local));
    expect_date("D:202311", date_in_zone(2023, 11, 1, 0, 0, 0, local));
    expect_date("D:2023", date_in_zone(2023, 1, 1, 0, 0, 0, local));
    /* Missing D: prefix. */
    expect_date("20231115093000Z", date_in_zone(2023, 11, 15, 9, 30, 0, utc));
    /* Surrounding whitespace. */
    expect_date("  D:20231115  ", date_in_zone(2023, 11, 15, 0, 0, 0, local));
    /* Trailing junk after a valid block is ignored. */
    expect_date("D:20231115 draft", date_in_zone(2023, 11, 15, 0, 0, 0, local));

    /* Rejections. */
    expect_date("", NULL);
    expect_date(NULL, NULL);
    expect_date("yesterday", NULL);
    expect_date("D:202", NULL);
    expect_date("D:202401012", NULL); /* odd digit count = partial field */
    expect_date("D:20241301", NULL);  /* month 13 */
    expect_date("D:20240132", NULL);  /* day 32 */
    expect_date("D:20240230", NULL);  /* Feb 30 must not roll over */
    expect_date("D:20230229", NULL);  /* Feb 29 in a non-leap year */
    expect_date("D:2024010124", NULL);   /* hour 24 */
    expect_date("D:202401011261", NULL); /* minute 61 */
    expect_date("D:20240101000000+8", NULL);      /* malformed offset */
    expect_date("D:20240101000000+25'00'", NULL); /* offset hour 25 */
    expect_date("D:2024010100000012", NULL);      /* too many digits */

    g_time_zone_unref(utc);
    g_time_zone_unref(plus8);
    g_time_zone_unref(plus0530);
    g_time_zone_unref(minus0530);
    g_time_zone_unref(local);
}

static void expect_string(char* actual /* takes ownership */, const char* expected) {
    g_assert_cmpstr(actual, ==, expected);
    g_free(actual);
}

static void test_file_size(void) {
    expect_string(spdf_props_format_file_size(0), "0 bytes");
    expect_string(spdf_props_format_file_size(1), "1 byte");
    expect_string(spdf_props_format_file_size(614), "614 bytes");
    expect_string(spdf_props_format_file_size(2048), "2 KB (2,048 bytes)");
    expect_string(spdf_props_format_file_size(2437120), "2.4 MB (2,437,120 bytes)");
    expect_string(spdf_props_format_file_size(G_GUINT64_CONSTANT(5300000000)), "5.3 GB (5,300,000,000 bytes)");
}

static void test_page_size(void) {
    expect_string(spdf_props_format_page_size(595.276, 841.89), "210 × 297 mm · 8.27 × 11.69 in · 595 × 842 pt");
    expect_string(spdf_props_format_page_size(612, 792), "216 × 279 mm · 8.50 × 11.00 in · 612 × 792 pt");
    expect_string(spdf_props_format_page_size(0, 792), "");
    expect_string(spdf_props_format_page_size(612, -1), "");
}

static void test_security_summary(void) {
    expect_string(spdf_props_security_summary("", TRUE, TRUE, TRUE, TRUE), "Not encrypted");
    expect_string(spdf_props_security_summary(NULL, TRUE, TRUE, TRUE, TRUE), "Not encrypted");
    expect_string(spdf_props_security_summary("Standard V4 R4 128-bit AES", TRUE, TRUE, TRUE, TRUE),
                  "Encrypted — Standard V4 R4 128-bit AES");
    expect_string(spdf_props_security_summary("Standard V2 R3 128-bit RC4", TRUE, FALSE, TRUE, TRUE),
                  "Encrypted — Standard V2 R3 128-bit RC4 · copying not allowed");
    expect_string(spdf_props_security_summary("AES", FALSE, FALSE, TRUE, TRUE),
                  "Encrypted — AES · printing and copying not allowed");
    expect_string(spdf_props_security_summary("AES", FALSE, FALSE, FALSE, TRUE),
                  "Encrypted — AES · printing, copying and editing not allowed");
    /* Permission denials also show on unencrypted documents (Mac behavior:
     * the base string and the denial list are independent). */
    expect_string(spdf_props_security_summary("  ", TRUE, TRUE, TRUE, FALSE),
                  "Not encrypted · annotating not allowed");
}

static void test_grouped_number(void) {
    expect_string(spdf_props_grouped_number(0), "0");
    expect_string(spdf_props_grouped_number(999), "999");
    expect_string(spdf_props_grouped_number(1000), "1,000");
    expect_string(spdf_props_grouped_number(2437120), "2,437,120");
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/props/parse-pdf-date", test_parse_pdf_date);
    g_test_add_func("/props/file-size", test_file_size);
    g_test_add_func("/props/page-size", test_page_size);
    g_test_add_func("/props/security-summary", test_security_summary);
    g_test_add_func("/props/grouped-number", test_grouped_number);
    return g_test_run();
}
