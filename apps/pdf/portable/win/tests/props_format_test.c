/* props_format_test.c -- the properties panel's value formatting, and the one
 * thing its differential deliberately cannot prove.
 *
 * TWO JOBS, AND THE SECOND IS WHY THIS FILE EXISTS SEPARATELY FROM
 * portable/win/tests/props_differential.c:
 *
 *   1. THE EXACT BYTES. The differential compares the port against the GTK
 *      original, and both are compiled here by the same MSVC from source that
 *      spells the multiplication sign, the middle dot and the em dash as
 *      literal characters. If the build ever lost /utf-8, BOTH sides would
 *      encode them in the machine's ANSI code page, they would still agree,
 *      and the app would ship the wrong bytes. So the exact UTF-8 sequences
 *      are pinned HERE, against escapes that cannot be re-encoded.
 *
 *   2. THE CALENDAR, AGAINST AN IMPLEMENTATION NOBODY HERE WROTE. The GTK
 *      original gets "is there a February 30th?" from g_date_time_new() and
 *      the Mac one from NSCalendar; the port spells the rule out, because a
 *      header that called SystemTimeToFileTime could not be compiled into the
 *      differential. That would leave the rule checked only against itself.
 *      test_calendar_against_windows() sweeps every (year, month, day) triple
 *      from 1601 to 2400 past SystemTimeToFileTime -- Windows' OWN calendar --
 *      and asserts the two verdicts agree, 316,800 triples including all 200
 *      Februaries and both century rules.
 *
 * NO DOCUMENT, NO MUPDF, NO WINDOW: the inputs are literals and the only
 * Windows call is the calendar oracle, so this is a fast suite that runs on a
 * locked workstation like any other.
 */
#include <windows.h>

#include "spdf_win_props_format.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_STR(got, want)                                                                                           \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (strcmp((got), (want)) != 0) {                                                                              \
            printf("FAIL %s:%d: got \"%s\" want \"%s\"\n", __FILE__, __LINE__, (got), (want));                         \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- 1. the exact bytes --------------------------------------------------- */

static void test_page_size_bytes(void) {
    char buf[256];

    /* A4: 595 x 842 pt. The separators are written as escapes so this
     * expectation cannot itself be re-encoded by a compiler switch:
     *   \xc3\x97  U+00D7 MULTIPLICATION SIGN
     *   \xc2\xb7  U+00B7 MIDDLE DOT */
    spdf_win_props_format_page_size(595.0, 842.0, buf, sizeof(buf));
    CHECK_STR(buf, "210 \xc3\x97 297 mm \xc2\xb7 8.26 \xc3\x97 11.69 in \xc2\xb7 595 \xc3\x97 842 pt");

    /* US Letter. */
    spdf_win_props_format_page_size(612.0, 792.0, buf, sizeof(buf));
    CHECK_STR(buf, "216 \xc3\x97 279 mm \xc2\xb7 8.50 \xc3\x97 11.00 in \xc2\xb7 612 \xc3\x97 792 pt");

    /* Non-positive or non-finite is the empty string, never "0 x 0 mm": the
     * panel omits the row rather than showing a size nothing has. */
    spdf_win_props_format_page_size(0.0, 792.0, buf, sizeof(buf));
    CHECK_STR(buf, "");
    spdf_win_props_format_page_size(-1.0, -1.0, buf, sizeof(buf));
    CHECK_STR(buf, "");
}

static void test_security_bytes(void) {
    char buf[512];

    /* \xe2\x80\x94 is U+2014 EM DASH. */
    spdf_win_props_security_summary("", 1, 1, 1, 1, buf, sizeof(buf));
    CHECK_STR(buf, "Not encrypted");
    spdf_win_props_security_summary("   ", 1, 1, 1, 1, buf, sizeof(buf));
    CHECK_STR(buf, "Not encrypted");
    spdf_win_props_security_summary("Standard V4 R4 128-bit AES", 1, 1, 1, 1, buf, sizeof(buf));
    CHECK_STR(buf, "Encrypted \xe2\x80\x94 Standard V4 R4 128-bit AES");

    /* One denial, two, and four: the list separator is ", " except before the
     * last entry, which takes " and ". */
    spdf_win_props_security_summary("", 0, 1, 1, 1, buf, sizeof(buf));
    CHECK_STR(buf, "Not encrypted \xc2\xb7 printing not allowed");
    spdf_win_props_security_summary("", 0, 0, 1, 1, buf, sizeof(buf));
    CHECK_STR(buf, "Not encrypted \xc2\xb7 printing and copying not allowed");
    spdf_win_props_security_summary("AES", 0, 0, 0, 0, buf, sizeof(buf));
    CHECK_STR(buf, "Encrypted \xe2\x80\x94 AES \xc2\xb7 printing, copying, editing and annotating not allowed");

    /* THE CASE THE PRODUCT FORBIDS BUILDING ON. can_copy reaches this function
     * from spdf_has_permission(doc, 'c'), which returns 1 unconditionally
     * (shenzhen_pdf_core.h:209-214), so "copying not allowed" is unreachable
     * through the panel. It is still formatted correctly when driven directly,
     * because this is a transcription -- but nothing may gate a copy on it. */
    spdf_win_props_security_summary("", 1, 0, 1, 1, buf, sizeof(buf));
    CHECK_STR(buf, "Not encrypted \xc2\xb7 copying not allowed");
}

static void test_file_size(void) {
    char buf[128];

    spdf_win_props_format_file_size(0, buf, sizeof(buf));
    CHECK_STR(buf, "0 bytes");
    spdf_win_props_format_file_size(1, buf, sizeof(buf));
    CHECK_STR(buf, "1 byte"); /* singular, deliberately */
    spdf_win_props_format_file_size(614, buf, sizeof(buf));
    CHECK_STR(buf, "614 bytes");
    spdf_win_props_format_file_size(999, buf, sizeof(buf));
    CHECK_STR(buf, "999 bytes");
    /* 1000-based, the Finder convention macOS shipped first -- NOT 1024. */
    spdf_win_props_format_file_size(1000, buf, sizeof(buf));
    CHECK_STR(buf, "1 KB (1,000 bytes)");
    spdf_win_props_format_file_size(2437120, buf, sizeof(buf));
    CHECK_STR(buf, "2.4 MB (2,437,120 bytes)");
    spdf_win_props_format_file_size(1000000000, buf, sizeof(buf));
    CHECK_STR(buf, "1 GB (1,000,000,000 bytes)");

    /* The grouping is pinned to en-US on all three platforms so two readers
     * comparing the same document see the same number. */
    spdf_win_props_grouped_number(0, buf, sizeof(buf));
    CHECK_STR(buf, "0");
    spdf_win_props_grouped_number(999, buf, sizeof(buf));
    CHECK_STR(buf, "999");
    spdf_win_props_grouped_number(1000, buf, sizeof(buf));
    CHECK_STR(buf, "1,000");
    spdf_win_props_grouped_number(1234567890123ULL, buf, sizeof(buf));
    CHECK_STR(buf, "1,234,567,890,123");
}

static void test_strip(void) {
    char buf[32];
    CHECK(spdf_win_props_strip("  hello \t\r\n", buf, sizeof(buf)) == 5);
    CHECK_STR(buf, "hello");
    CHECK(spdf_win_props_strip("   ", buf, sizeof(buf)) == 0);
    CHECK_STR(buf, "");
    CHECK(spdf_win_props_strip(NULL, buf, sizeof(buf)) == 0);
    CHECK_STR(buf, "");
}

/* --- 2. the parser -------------------------------------------------------- */

static void test_parse_examples(void) {
    spdf_win_props_pdf_date d;

    /* The full form with an offset. */
    CHECK(spdf_win_props_parse_pdf_date("D:20240229134501+05'30'", &d));
    CHECK(d.year == 2024 && d.month == 2 && d.day == 29);
    CHECK(d.hour == 13 && d.minute == 45 && d.second == 1);
    CHECK(d.has_offset == 1 && d.offset_seconds == 5 * 3600 + 30 * 60);

    /* Z is an explicit zero offset, not "no zone". */
    CHECK(spdf_win_props_parse_pdf_date("D:20240229134501Z", &d));
    CHECK(d.has_offset == 1 && d.offset_seconds == 0);

    /* No zone at all means LOCAL time, which the caller resolves. */
    CHECK(spdf_win_props_parse_pdf_date("D:20240229134501", &d));
    CHECK(d.has_offset == 0);

    /* A year alone is legal; the missing fields default to January 1st 00:00. */
    CHECK(spdf_win_props_parse_pdf_date("D:2024", &d));
    CHECK(d.year == 2024 && d.month == 1 && d.day == 1 && d.hour == 0);

    /* Trailing junk after a valid block is ignored -- producers append all
     * sorts of things -- but a partial FIELD is not a date. */
    CHECK(spdf_win_props_parse_pdf_date("D:20240229 (Adobe)", &d));
    CHECK(!spdf_win_props_parse_pdf_date("D:2024022", &d));
    CHECK(!spdf_win_props_parse_pdf_date("D:202402291", &d));

    /* A started-but-malformed offset invalidates the whole date rather than
     * being ignored as junk: "+8" is a producer bug, not a comment. */
    CHECK(!spdf_win_props_parse_pdf_date("D:20240229134501+8", &d));
    CHECK(spdf_win_props_parse_pdf_date("D:20240229134501-08", &d));
    CHECK(d.offset_seconds == -8 * 3600);

    /* Out-of-range components. */
    CHECK(!spdf_win_props_parse_pdf_date("D:20241329", &d));
    CHECK(!spdf_win_props_parse_pdf_date("D:20240229245959", &d));
    CHECK(!spdf_win_props_parse_pdf_date("D:20240229135960", &d));
    CHECK(!spdf_win_props_parse_pdf_date("", &d));
    CHECK(!spdf_win_props_parse_pdf_date(NULL, &d));
    /* A rejection leaves the structure zeroed rather than half-filled. */
    CHECK(d.year == 0 && d.valid == 0);
}

/* THE CALENDAR ORACLE. SystemTimeToFileTime rejects a SYSTEMTIME naming a day
 * that does not exist, using the Gregorian rules the OS itself keeps -- an
 * implementation nobody in this repository wrote. Its lower bound is 1601,
 * which is why the sweep starts there; the parser accepts year 1 and up, and
 * the few earlier cases are pinned by hand below. */
static void test_calendar_against_windows(void) {
    int year, month, day;
    long triples = 0;
    long disagreements = 0;

    for (year = 1601; year <= 2400; ++year) {
        for (month = 1; month <= 12; ++month) {
            for (day = 1; day <= 33; ++day) {
                SYSTEMTIME st;
                FILETIME ft;
                int windows_says;
                int we_say;

                memset(&st, 0, sizeof(st));
                st.wYear = (WORD)year;
                st.wMonth = (WORD)month;
                st.wDay = (WORD)day;
                windows_says = SystemTimeToFileTime(&st, &ft) ? 1 : 0;
                we_say = (day >= 1 && day <= spdf_win_props_days_in_month(year, month)) ? 1 : 0;
                ++triples;
                if (windows_says != we_say) {
                    if (disagreements < 10)
                        printf("FAIL calendar %04d-%02d-%02d: windows=%d ours=%d\n", year, month, day, windows_says,
                               we_say);
                    ++disagreements;
                }
            }
        }
    }
    ++g_checks;
    if (disagreements) {
        printf("FAIL %s: %ld of %ld (year, month, day) triples disagree with Windows' calendar\n", __FILE__,
               disagreements, triples);
        ++g_failures;
    } else {
        printf("props_format_test: %ld (year, month, day) triples agree with SystemTimeToFileTime\n", triples);
    }

    /* Below Windows' 1601 floor, by hand. 1600 is a leap year (divisible by
     * 400), 1700 is not (divisible by 100 but not 400), 4 is. */
    CHECK(spdf_win_props_days_in_month(1600, 2) == 29);
    CHECK(spdf_win_props_days_in_month(1700, 2) == 28);
    CHECK(spdf_win_props_days_in_month(4, 2) == 29);
    CHECK(spdf_win_props_days_in_month(1, 2) == 28);
    CHECK(spdf_win_props_days_in_month(2024, 13) == 0);
    CHECK(spdf_win_props_days_in_month(2024, 0) == 0);

    /* And through the parser, which is what the panel actually calls. */
    {
        spdf_win_props_pdf_date d;
        CHECK(!spdf_win_props_parse_pdf_date("D:20230229", &d)); /* 2023 is not a leap year */
        CHECK(spdf_win_props_parse_pdf_date("D:20240229", &d));
        CHECK(!spdf_win_props_parse_pdf_date("D:21000229", &d)); /* 2100 is not */
        CHECK(spdf_win_props_parse_pdf_date("D:20000229", &d));  /* 2000 is */
        CHECK(!spdf_win_props_parse_pdf_date("D:20240431", &d)); /* April has 30 */
    }
}

int main(void) {
    test_page_size_bytes();
    test_security_bytes();
    test_file_size();
    test_strip();
    test_parse_examples();
    test_calendar_against_windows();
    printf("props_format_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
