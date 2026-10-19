/* spdf_win_props_format.h — the document-properties panel's PURE value
 * formatting: the PDF date parser, the file-size string, the page-size string
 * and the one-line security summary.
 *
 * A TRANSCRIPTION, NOT A DESIGN. Ported function for function from
 * portable/linux/gtk4/spdf_props_internal.h, which is itself a port of
 * portable/mac/SPDFMacPropertiesFormat.mm. Both of those are deliberately
 * toolkit-free for exactly this reason: the panel's WIDGETS differ on every
 * platform, but "2.4 MB (2,437,120 bytes)" and "210 x 297 mm - 8.27 x 11.69 in"
 * must be the same three strings everywhere, or the three apps are not the same
 * product. portable/win/tests/props_differential.c compiles the GTK header
 * beside this one and compares them EXACTLY — same instrument as
 * layout.differential and the search/minimap/selection differentials.
 *
 * NO glib, NO Windows, NO core, NO ALLOCATION. The GTK original returns
 * freshly-allocated strings because glib's idiom is g_strdup_printf; here every
 * function writes into a caller buffer, so the panel builder can compose a
 * whole transcript out of one stack frame and the tests need no teardown. That
 * is the ONLY intentional difference from the original, and the differential
 * compares the resulting bytes, not the allocation strategy.
 *
 * THE DATE PARSER RETURNS FIELDS, NOT A TIME. GDateTime and NSDate both carry a
 * calendar, a zone and an epoch; a Win32 panel needs none of that, it needs the
 * six numbers and the UTC offset so it can hand a SYSTEMTIME to
 * GetDateFormatEx. So spdf_win_props_pdf_date is the broken-out result and the
 * calendar validity check (is there a February 30th?) lives here rather than
 * being inherited from the platform. props_format_test.c cross-checks that
 * check against Windows' OWN calendar via SystemTimeToFileTime, so it is
 * verified against an independent implementation and not merely against itself.
 *
 * UTF-8 THROUGHOUT. The page-size and security strings contain U+00D7 MULTI-
 * PLICATION SIGN, U+00B7 MIDDLE DOT and U+2014 EM DASH, exactly as the Mac and
 * GTK originals do. The build passes /utf-8 (portable/win/build-native.cmd), so
 * these literals are UTF-8 bytes in the binary, matching what the other two
 * frontends emit byte for byte; the panel widens them once on its way to
 * DrawTextW. A build without /utf-8 would encode them in the machine's ANSI
 * code page and the differential would catch it immediately.
 */
#ifndef SPDF_WIN_PROPS_FORMAT_H
#define SPDF_WIN_PROPS_FORMAT_H

#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "spdf_win_layout.h" /* SPDF_WIN_INLINE */

#ifdef __cplusplus
extern "C" {
#endif

/* The broken-out result of parsing a PDF date string. `valid` is 0 for every
 * rejection; the other fields are then zero. `has_offset` is 0 when the string
 * carried no zone, which PDF 32000-1 7.9.4 defines as LOCAL time — the caller
 * decides what local means, because the panel and a test disagree about that
 * and neither should be able to change the parse. */
typedef struct spdf_win_props_pdf_date {
    int valid;
    int year;
    int month;  /* 1-12 */
    int day;    /* 1-31 */
    int hour;   /* 0-23 */
    int minute; /* 0-59 */
    int second; /* 0-59 */
    int has_offset;
    int offset_seconds; /* signed, 0 for Z */
} spdf_win_props_pdf_date;

/* glib's g_ascii_isspace set, which is also what g_strstrip trims and what
 * NSCharacterSet.whitespaceAndNewlineCharacterSet covers for ASCII. Spelled
 * out rather than calling isspace(), whose behaviour is locale-dependent. */
static SPDF_WIN_INLINE int spdf_win_props_is_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

/* g_strstrip into a caller buffer. Returns the trimmed length. */
static SPDF_WIN_INLINE size_t spdf_win_props_strip(const char* raw, char* out, size_t out_len) {
    size_t begin = 0;
    size_t end;
    size_t n;

    if (!out || out_len == 0) return 0;
    out[0] = '\0';
    if (!raw) return 0;
    end = strlen(raw);
    while (begin < end && spdf_win_props_is_space(raw[begin])) ++begin;
    while (end > begin && spdf_win_props_is_space(raw[end - 1])) --end;
    n = end - begin;
    if (n >= out_len) n = out_len - 1;
    memcpy(out, raw + begin, n);
    out[n] = '\0';
    return n;
}

/* Reads exactly two digits at s[*pos] into *value. Returns 0 when fewer than
 * two digits remain — a lone trailing digit is a PARTIAL field, not a zero. */
static SPDF_WIN_INLINE int spdf_win_props_read_two_digits(const char* s, size_t len, size_t* pos, int* value) {
    if (*pos + 2 > len) return 0;
    if (!isdigit((unsigned char)s[*pos]) || !isdigit((unsigned char)s[*pos + 1])) return 0;
    *value = (s[*pos] - '0') * 10 + (s[*pos + 1] - '0');
    *pos += 2;
    return 1;
}

/* Gregorian days in month. The GTK original gets this from g_date_time_new()
 * and the Mac one from NSCalendar's round-trip check; on Windows the panel
 * would get it from SystemTimeToFileTime, but that would make this header
 * un-includable in the differential, so it is spelled out and then verified
 * against SystemTimeToFileTime by props_format_test.c. */
static SPDF_WIN_INLINE int spdf_win_props_days_in_month(int year, int month) {
    static const int k_days[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (month < 1 || month > 12) return 0;
    if (month == 2 && ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0)) return 29;
    return k_days[month - 1];
}

/* Parse a PDF date string (D:YYYYMMDDHHmmSSOHH'mm', PDF 32000-1 7.9.4).
 * Everything after the 4-digit year is optional; the optional offset is
 * Z / +HH'mm' / -HH'mm' with the apostrophes optional and possibly unbalanced,
 * as they are in the wild. Rejects garbage, partial fields (an odd digit
 * count), out-of-range components, a date that does not exist (February 30th)
 * and a started-but-malformed offset ("+8"). Trailing junk after a valid date
 * block is IGNORED, which is deliberate: producers append all sorts of things.
 * Returns 1 when *out is valid. */
static SPDF_WIN_INLINE int spdf_win_props_parse_pdf_date(const char* raw, spdf_win_props_pdf_date* out) {
    /* Fixed buffer where the originals allocate. A real PDF date is at most 23
     * bytes; anything past 255 is junk that both this and the originals reject
     * on the digit-count rule, so the truncation cannot change a verdict. */
    char trimmed[256];
    const char* s;
    size_t len;
    size_t pos = 0;
    size_t digit_count = 0;
    int year = 0;
    int month = 1, day = 1, hour = 0, minute = 0, second = 0;
    int has_offset = 0;
    int offset_seconds = 0;

    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    spdf_win_props_strip(raw, trimmed, sizeof(trimmed));
    s = trimmed;
    if (strncmp(s, "D:", 2) == 0) s += 2;
    len = strlen(s);
    if (len < 4) return 0;

    while (digit_count < len && isdigit((unsigned char)s[digit_count])) ++digit_count;
    /* Fields are fixed-width pairs after the 4-digit year; an odd digit count
     * means a partial field, and 15+ digits is not a date. */
    if (digit_count < 4 || digit_count > 14 || (digit_count % 2) != 0) return 0;

    for (pos = 0; pos < 4; ++pos) year = year * 10 + (s[pos] - '0');
    if (year <= 0) return 0;

    if (pos < digit_count && !spdf_win_props_read_two_digits(s, len, &pos, &month)) return 0;
    if (pos < digit_count && !spdf_win_props_read_two_digits(s, len, &pos, &day)) return 0;
    if (pos < digit_count && !spdf_win_props_read_two_digits(s, len, &pos, &hour)) return 0;
    if (pos < digit_count && !spdf_win_props_read_two_digits(s, len, &pos, &minute)) return 0;
    if (pos < digit_count && !spdf_win_props_read_two_digits(s, len, &pos, &second)) return 0;
    if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) return 0;
    /* The calendar check the other two frontends inherit from their platform. */
    if (day > spdf_win_props_days_in_month(year, month)) return 0;

    if (pos < len && (s[pos] == 'Z' || s[pos] == 'z')) {
        has_offset = 1;
        ++pos;
        if (pos < len && s[pos] == '0') { /* tolerate Z00'00' */
            int zh = 0, zm = 0;
            if (!spdf_win_props_read_two_digits(s, len, &pos, &zh) || zh != 0) return 0;
            if (pos < len && s[pos] == '\'') ++pos;
            if (pos < len && isdigit((unsigned char)s[pos])) {
                if (!spdf_win_props_read_two_digits(s, len, &pos, &zm) || zm != 0) return 0;
            }
        }
    } else if (pos < len && (s[pos] == '+' || s[pos] == '-')) {
        int sign = s[pos] == '-' ? -1 : 1;
        int offset_hour = 0, offset_minute = 0;
        ++pos;
        if (!spdf_win_props_read_two_digits(s, len, &pos, &offset_hour) || offset_hour > 23) return 0;
        if (pos < len && s[pos] == '\'') ++pos;
        if (pos < len && isdigit((unsigned char)s[pos])) {
            if (!spdf_win_props_read_two_digits(s, len, &pos, &offset_minute) || offset_minute > 59) return 0;
        }
        has_offset = 1;
        offset_seconds = sign * (offset_hour * 3600 + offset_minute * 60);
    }

    out->valid = 1;
    out->year = year;
    out->month = month;
    out->day = day;
    out->hour = hour;
    out->minute = minute;
    out->second = second;
    out->has_offset = has_offset;
    out->offset_seconds = offset_seconds;
    return 1;
}

/* "2,437,120" — en-US grouping. The Mac formatter is pinned to en_US_POSIX and
 * the GTK one builds the string by hand for the same reason: the panel's
 * numbers must not change with the machine's locale, or two readers comparing
 * the same document would see different strings. */
static SPDF_WIN_INLINE void spdf_win_props_grouped_number(unsigned long long value, char* out, size_t out_len) {
    char plain[32];
    size_t len;
    size_t i;
    size_t w = 0;

    if (!out || out_len == 0) return;
    out[0] = '\0';
    snprintf(plain, sizeof(plain), "%llu", value);
    len = strlen(plain);
    for (i = 0; i < len; ++i) {
        if (i > 0 && (len - i) % 3 == 0) {
            if (w + 1 >= out_len) break;
            out[w++] = ',';
        }
        if (w + 1 >= out_len) break;
        out[w++] = plain[i];
    }
    out[w] = '\0';
}

/* "2.4" / "2" — the trailing ".0" trimmed, exactly the Mac spdf_one_decimal. */
static SPDF_WIN_INLINE void spdf_win_props_one_decimal(double value, char* out, size_t out_len) {
    size_t n;
    if (!out || out_len == 0) return;
    snprintf(out, out_len, "%.1f", value);
    n = strlen(out);
    if (n >= 2 && strcmp(out + n - 2, ".0") == 0) out[n - 2] = '\0';
}

/* "614 bytes", "1 byte", "2.4 MB (2,437,120 bytes)". 1000-based units (the
 * Finder convention macOS shipped first); the exact grouped byte count is
 * appended from 1 KB up. */
static SPDF_WIN_INLINE void spdf_win_props_format_file_size(unsigned long long bytes, char* out, size_t out_len) {
    static const char* const k_units[] = {"KB", "MB", "GB", "TB", "PB"};
    double value;
    size_t unit = 0;
    char scaled[32];
    char grouped[40];

    if (!out || out_len == 0) return;
    if (bytes == 1) {
        snprintf(out, out_len, "1 byte");
        return;
    }
    if (bytes < 1000) {
        snprintf(out, out_len, "%llu bytes", bytes);
        return;
    }
    value = (double)bytes / 1000.0;
    while (value >= 1000.0 && unit + 1 < sizeof(k_units) / sizeof(k_units[0])) {
        value /= 1000.0;
        ++unit;
    }
    spdf_win_props_one_decimal(value, scaled, sizeof(scaled));
    spdf_win_props_grouped_number(bytes, grouped, sizeof(grouped));
    snprintf(out, out_len, "%s %s (%s bytes)", scaled, k_units[unit], grouped);
}

/* "210 x 297 mm - 8.27 x 11.69 in - 595 x 842 pt" (with U+00D7 and U+00B7)
 * from PDF points, 1/72 in. Empty string when either dimension is not a
 * positive finite number. */
static SPDF_WIN_INLINE void spdf_win_props_format_page_size(double width_pt, double height_pt, char* out,
                                                            size_t out_len) {
    if (!out || out_len == 0) return;
    out[0] = '\0';
    if (!isfinite(width_pt) || !isfinite(height_pt) || width_pt <= 0.0 || height_pt <= 0.0) return;
    snprintf(out, out_len, "%.0f \xc3\x97 %.0f mm \xc2\xb7 %.2f \xc3\x97 %.2f in \xc2\xb7 %.0f \xc3\x97 %.0f pt",
             width_pt * 25.4 / 72.0, height_pt * 25.4 / 72.0, width_pt / 72.0, height_pt / 72.0, width_pt, height_pt);
}

/* One-line security summary: "Not encrypted", "Encrypted (em dash) Standard V4
 * R4 128-bit AES", optionally followed by " (middle dot) printing and copying
 * not allowed". The detail is used trimmed; empty or whitespace means the
 * document is not encrypted.
 *
 * can_copy IS ALWAYS 1 in this product. spdf_has_permission(doc, 'c') returns 1
 * unconditionally by product decision (shenzhen_pdf_core.h:209-214), so the
 * "copying not allowed" branch is unreachable through the panel and exists only
 * because this is a transcription and the differential drives the parameter
 * directly. No copy gate may be built on it. */
static SPDF_WIN_INLINE void spdf_win_props_security_summary(const char* encryption_detail, int can_print, int can_copy,
                                                            int can_edit, int can_annotate, char* out,
                                                            size_t out_len) {
    char detail[256];
    const char* denied[4];
    int denied_count = 0;
    int i;
    size_t w;

    if (!out || out_len == 0) return;
    spdf_win_props_strip(encryption_detail, detail, sizeof(detail));
    if (detail[0])
        snprintf(out, out_len, "Encrypted \xe2\x80\x94 %s", detail);
    else
        snprintf(out, out_len, "Not encrypted");

    if (!can_print) denied[denied_count++] = "printing";
    if (!can_copy) denied[denied_count++] = "copying";
    if (!can_edit) denied[denied_count++] = "editing";
    if (!can_annotate) denied[denied_count++] = "annotating";
    if (denied_count == 0) return;

    w = strlen(out);
    /* Appended piece by piece rather than composed with one snprintf: the
     * separator between the last two entries is " and " while the others are
     * ", ", which is the Mac spdf_denied_list rule and reads as English. */
    snprintf(out + w, out_len - w, " \xc2\xb7 ");
    for (i = 0; i < denied_count; ++i) {
        w = strlen(out);
        if (w + 1 >= out_len) return;
        if (i > 0) {
            snprintf(out + w, out_len - w, "%s", i == denied_count - 1 ? " and " : ", ");
            w = strlen(out);
            if (w + 1 >= out_len) return;
        }
        snprintf(out + w, out_len - w, "%s", denied[i]);
    }
    w = strlen(out);
    if (w + 1 < out_len) snprintf(out + w, out_len - w, " not allowed");
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SPDF_WIN_PROPS_FORMAT_H */
