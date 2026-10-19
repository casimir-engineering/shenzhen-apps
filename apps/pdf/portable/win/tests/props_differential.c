/* THE PROPERTIES DIFFERENTIAL: portable/win/src/spdf_win_props_format.h versus
 * the GTK4 original it was transcribed from,
 * portable/linux/gtk4/spdf_props_internal.h -- which is itself the port of
 * portable/mac/SPDFMacPropertiesFormat.mm -- both compiled into ONE binary,
 * driven with identical inputs, compared for EXACT equality.
 *
 * Same instrument as portable/win/tests/print_differential.c,
 * search_differential.c, minimap_differential.c and gtk_differential.c.
 * Strings are compared with strcmp and integers with ==; the port is a
 * transcription, so a difference of one byte is a transcription error and not
 * a formatting question.
 *
 * WHAT IT PROVES AND WHAT IT DOES NOT. The GTK header returns freshly
 * allocated strings and a GDateTime; the port writes into caller buffers and
 * returns broken-out fields, because a Win32 panel wants a SYSTEMTIME and not
 * a calendar object. So the comparison is on the RESULTING BYTES and the
 * RESULTING NUMBERS, which is what a reader sees, and not on the allocation
 * strategy. portable/win/tests/glib_shim_props/glib.h supplies the glib the
 * GTK header needs; its own header says exactly which parts of it are real and
 * which one part (the Gregorian day-count inside g_date_time_new) is an
 * instrument -- and props_format_test.c closes that gap against Windows' own
 * calendar, which is an implementation nobody in this repository wrote.
 *
 * Not named *_test.c on purpose, so run-tests-native.sh's `*_test.c` sweep does
 * not try to build it without the extra include paths. Build and run it with
 * portable\win\tests\props-differential-native.cmd; its exit code is the whole
 * truth.
 */

/* The GTK4 original. The .cmd puts glib_shim_props on the include path first,
 * so its <glib.h> is the layered shim. */
#include "spdf_props_internal.h"

/* The port. */
#include "spdf_win_props_format.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int mismatches;
static long comparisons;

static void same_i(const char* what, const char* input, long long win, long long gtk) {
    comparisons++;
    if (win != gtk) {
        if (mismatches < 40) printf("DIFFER %s [%s]: win=%lld gtk=%lld\n", what, input, win, gtk);
        mismatches++;
    }
}

static void same_s(const char* what, const char* input, const char* win, const char* gtk) {
    comparisons++;
    if ((win == NULL) != (gtk == NULL) || (win && gtk && strcmp(win, gtk) != 0)) {
        if (mismatches < 40)
            printf("DIFFER %s [%s]: win=\"%s\" gtk=\"%s\"\n", what, input, win ? win : "(null)", gtk ? gtk : "(null)");
        mismatches++;
    }
}

/* --------------------------------------------------------------------------
 * 1. The PDF date parser.
 *
 * Nine comparisons per input: accept/reject, then the six components and the
 * zone decision. The zone is compared through the shim's instrument hooks --
 * real glib would answer with the machine's own local offset, which is not a
 * comparable quantity; see glib_shim_props/glib.h. */

static void compare_date(const char* raw) {
    spdf_win_props_pdf_date win;
    GDateTime* gtk = spdf_props_parse_pdf_date(raw);
    int win_ok = spdf_win_props_parse_pdf_date(raw, &win);

    same_i("date/accepted", raw, win_ok, gtk != NULL ? 1 : 0);
    if (!win_ok || !gtk) {
        if (gtk) g_date_time_unref(gtk);
        return;
    }
    same_i("date/year", raw, win.year, g_date_time_get_year(gtk));
    same_i("date/month", raw, win.month, g_date_time_get_month(gtk));
    same_i("date/day", raw, win.day, g_date_time_get_day_of_month(gtk));
    same_i("date/hour", raw, win.hour, g_date_time_get_hour(gtk));
    same_i("date/minute", raw, win.minute, g_date_time_get_minute(gtk));
    same_i("date/second", raw, win.second, g_date_time_get_second(gtk));
    same_i("date/has_offset", raw, win.has_offset, g_shim_date_time_zone_kind(gtk));
    same_i("date/offset", raw, win.has_offset ? win.offset_seconds : 0, g_shim_date_time_zone_offset(gtk));
    g_date_time_unref(gtk);
}

/* Every (year, month, day, hour, minute, second) combination worth naming,
 * spelled as the full 14-digit form. The out-of-range values are in the grid
 * on purpose: month 00 and 13, day 00 and 32, hour 24, minute and second 60,
 * and February 29 in a leap year, a common year and a century that is not a
 * leap year are all decided by rules the two files must agree about. */
static void differential_dates_full(void) {
    static const int years[] = {1, 1899, 1900, 1996, 1999, 2000, 2023, 2024, 2100, 9999};
    static const int months[] = {0, 1, 2, 3, 4, 6, 9, 11, 12, 13};
    static const int days[] = {0, 1, 15, 28, 29, 30, 31, 32};
    static const int hours[] = {0, 1, 12, 23, 24};
    static const int minutes[] = {0, 30, 59, 60};
    static const int seconds[] = {0, 30, 59, 60};
    char raw[64];
    size_t y, m, d, h, mi, s;

    for (y = 0; y < sizeof(years) / sizeof(years[0]); ++y)
        for (m = 0; m < sizeof(months) / sizeof(months[0]); ++m)
            for (d = 0; d < sizeof(days) / sizeof(days[0]); ++d)
                for (h = 0; h < sizeof(hours) / sizeof(hours[0]); ++h)
                    for (mi = 0; mi < sizeof(minutes) / sizeof(minutes[0]); ++mi)
                        for (s = 0; s < sizeof(seconds) / sizeof(seconds[0]); ++s) {
                            sprintf(raw, "D:%04d%02d%02d%02d%02d%02d", years[y], months[m], days[d], hours[h],
                                    minutes[mi], seconds[s]);
                            compare_date(raw);
                        }
}

/* Every TRUNCATION of a valid date, with and without the "D:" prefix. A PDF
 * that carries only a year is legal and common; a partial field (an odd digit
 * count) is not, and the boundary between the two is the rule most likely to
 * be transcribed wrong. */
static void differential_dates_truncated(void) {
    static const char* const full = "20240229134501";
    char raw[64];
    size_t n;

    for (n = 0; n <= strlen(full); ++n) {
        sprintf(raw, "D:%.*s", (int)n, full);
        compare_date(raw);
        sprintf(raw, "%.*s", (int)n, full);
        compare_date(raw);
        /* Trailing junk after the digits is IGNORED after a valid block and
         * must not rescue an invalid one. */
        sprintf(raw, "D:%.*s and then some words", (int)n, full);
        compare_date(raw);
        sprintf(raw, "  D:%.*s  ", (int)n, full);
        compare_date(raw);
    }
}

/* The zone suffix, which the PDF spec writes with optional apostrophes that
 * real producers get wrong in every possible way. */
static void differential_dates_offsets(void) {
    static const char* const suffixes[] = {
        "",      "Z",       "z",        "Z00",      "Z00'",      "Z00'00'",  "Z00'00",   "Z0",     "Z01",
        "Z00'30'", "+",     "-",        "+0",       "+8",        "+00",      "+00'",     "+00'00'", "+05",
        "+05'30'", "+05'3", "+05'30",   "-08",      "-08'00'",   "+23'59'",  "+24",      "-24",    "+05'60'",
        "+05'59'", "Q",     "+0530",    "-0800",    " +05'30'",  "+05'30'x", "z00'00'",
    };
    static const char* const bases[] = {"D:2024", "D:202402", "D:20240229", "D:2024022913", "D:202402291345",
                                        "D:20240229134501", "20240229134501"};
    char raw[96];
    size_t b, s;

    for (b = 0; b < sizeof(bases) / sizeof(bases[0]); ++b)
        for (s = 0; s < sizeof(suffixes) / sizeof(suffixes[0]); ++s) {
            sprintf(raw, "%s%s", bases[b], suffixes[s]);
            compare_date(raw);
        }
}

/* The strings that are not dates at all, including the ones a naive parser
 * accepts. */
static void differential_dates_garbage(void) {
    static const char* const cases[] = {
        "",      " ",      "\t\n",  "D:",     "D",      ":",       "abcd",   "D:abcd",  "20",     "2",
        "0000",  "D:0000", "00001", "D:0001", "123",    "12345",   "1234567", "D:99999999999999",
        "D:999999999999999", "D:20240229134501+05'30'extra", "\r\n D:2024 \t", "D:2024-02-29",
        "2024/02/29 13:45", "D: 20240229", "D:2024 0229", "-20240229", "+20240229",
    };
    size_t i;
    for (i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) compare_date(cases[i]);
    /* NULL: the GTK side g_strdup("")s it, the port memsets and returns 0.
     * Compared explicitly because "both crash" would otherwise look like
     * agreement. */
    compare_date(NULL);
}

/* --------------------------------------------------------------------------
 * 2. The three string formatters. */

static void differential_file_size(void) {
    static const unsigned long long extras[] = {
        999ULL,        1000ULL,          1001ULL,          1024ULL,         9999ULL,
        999999ULL,     1000000ULL,       1049999ULL,       2437120ULL,      999999999ULL,
        1000000000ULL, 1099511627776ULL, 1000000000000ULL, 999999999999ULL, 1000000000000000ULL,
        1000000000000000000ULL, 18446744073709551615ULL};
    char win[128];
    char label[64];
    unsigned long long v;
    size_t i;

    for (v = 0; v <= 2100; ++v) {
        char* gtk = spdf_props_format_file_size(v);
        spdf_win_props_format_file_size(v, win, sizeof(win));
        sprintf(label, "%llu", v);
        same_s("file_size", label, win, gtk);
        g_free(gtk);
    }
    for (i = 0; i < sizeof(extras) / sizeof(extras[0]); ++i) {
        char* gtk = spdf_props_format_file_size(extras[i]);
        spdf_win_props_format_file_size(extras[i], win, sizeof(win));
        sprintf(label, "%llu", extras[i]);
        same_s("file_size", label, win, gtk);
        g_free(gtk);
    }
    /* The grouped number on its own, which is what the "(2,437,120 bytes)"
     * tail is built from. */
    for (v = 0; v <= 1000000ULL; v = v * 3 + 1) {
        char grouped[64];
        char* gtk = spdf_props_grouped_number(v);
        spdf_win_props_grouped_number(v, grouped, sizeof(grouped));
        sprintf(label, "%llu", v);
        same_s("grouped_number", label, grouped, gtk);
        g_free(gtk);
    }
}

static void differential_page_size(void) {
    static const double dims[] = {-1.0,  0.0,   0.001, 0.5,    1.0,    72.0,   200.0,  595.0,
                                  595.2756, 612.0, 792.0, 841.89, 842.0,  1224.0, 5000.0, 14400.0};
    char win[256];
    char label[64];
    size_t a, b;

    for (a = 0; a < sizeof(dims) / sizeof(dims[0]); ++a)
        for (b = 0; b < sizeof(dims) / sizeof(dims[0]); ++b) {
            char* gtk = spdf_props_format_page_size(dims[a], dims[b]);
            spdf_win_props_format_page_size(dims[a], dims[b], win, sizeof(win));
            sprintf(label, "%g x %g", dims[a], dims[b]);
            same_s("page_size", label, win, gtk);
            g_free(gtk);
        }
}

static void differential_security(void) {
    static const char* const details[] = {
        "", " ", "  \t ", "Standard V4 R4 128-bit AES", "Standard V5 R6 256-bit AES",
        " Standard V2 R3 128-bit RC4 ", "None", "Standard V4 R4 128-bit AES (password protected)"};
    char win[512];
    char label[128];
    size_t d;
    int bits;

    for (d = 0; d < sizeof(details) / sizeof(details[0]); ++d)
        for (bits = 0; bits < 16; ++bits) {
            int p = (bits >> 0) & 1;
            int c = (bits >> 1) & 1;
            int e = (bits >> 2) & 1;
            int n = (bits >> 3) & 1;
            char* gtk = spdf_props_security_summary(details[d], p, c, e, n);
            spdf_win_props_security_summary(details[d], p, c, e, n, win, sizeof(win));
            sprintf(label, "%s|%d%d%d%d", details[d], p, c, e, n);
            same_s("security", label, win, gtk);
            g_free(gtk);
        }
    /* A NULL detail is what props_metadata() hands over for a document with no
     * encryption dictionary. */
    {
        char* gtk = spdf_props_security_summary(NULL, 1, 1, 1, 1);
        spdf_win_props_security_summary(NULL, 1, 1, 1, 1, win, sizeof(win));
        same_s("security", "(null)", win, gtk);
        g_free(gtk);
    }
}

int main(void) {
    differential_dates_full();
    differential_dates_truncated();
    differential_dates_offsets();
    differential_dates_garbage();
    differential_file_size();
    differential_page_size();
    differential_security();

    printf("props differential: %ld comparisons, %d mismatches\n", comparisons, mismatches);
    if (mismatches > 0) return 1;
    if (comparisons < 20000) {
        printf("props differential: only %ld comparisons ran; the matrix did not execute\n", comparisons);
        return 2;
    }
    return 0;
}
