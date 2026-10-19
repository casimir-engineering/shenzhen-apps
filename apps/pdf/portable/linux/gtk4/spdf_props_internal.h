/* Pure value-formatting logic for the document-properties panel. glib-only
 * (no GTK includes) so tests/props_format_test.c compiles the exact shipping
 * logic against glib alone (same pattern as spdf_search_internal.h).
 * spdf_props.c is the only GTK consumer.
 *
 * Ported semantics (portable/mac/SPDFMacPropertiesFormat.mm, unit-tested by
 * mac/tests/SPDFMacPropertiesFormatTests.mm — mirrored by our test):
 *   spdf_props_parse_pdf_date    <- spdf_properties_parse_pdf_date
 *                                   (PDF 32000-1 §7.9.4 D:YYYYMMDDHHmmSSOHH'mm';
 *                                   everything after the year optional, missing
 *                                   offset = local time, partial fields /
 *                                   out-of-range components / malformed offsets
 *                                   rejected, trailing junk ignored)
 *   spdf_props_format_file_size  <- spdf_properties_format_file_size
 *                                   ("614 bytes", "2.4 MB (2,437,120 bytes)";
 *                                   1000-based units, grouped exact count from
 *                                   1 KB up)
 *   spdf_props_format_page_size  <- spdf_properties_format_page_size_pt
 *                                   ("210 × 297 mm · 8.27 × 11.69 in ·
 *                                   595 × 842 pt"; "" for non-positive dims)
 *   spdf_props_security_summary  <- spdf_properties_security_summary
 *                                   ("Not encrypted", "Encrypted — <detail>",
 *                                   " · printing and copying not allowed")
 */
#pragma once

#include <ctype.h>
#include <glib.h>
#include <math.h>
#include <string.h>

G_BEGIN_DECLS

/* Reads exactly two digits at s[*pos] into *value. Returns FALSE when fewer
 * than two digits remain (a lone trailing digit is a partial field). */
static inline gboolean spdf_props_read_two_digits(const char* s, gsize len, gsize* pos, int* value) {
    if (*pos + 2 > len) return FALSE;
    if (!isdigit((unsigned char)s[*pos]) || !isdigit((unsigned char)s[*pos + 1])) return FALSE;
    *value = (s[*pos] - '0') * 10 + (s[*pos + 1] - '0');
    *pos += 2;
    return TRUE;
}

/* Parses a PDF date string. Returns a new GDateTime (caller unrefs) or NULL
 * for garbage, partial fields, out-of-range components or a malformed offset.
 * A missing offset means local time; trailing junk after a valid block is
 * ignored. */
static inline GDateTime* spdf_props_parse_pdf_date(const char* raw) {
    char* trimmed;
    const char* s;
    gsize len;
    gsize pos;
    gsize digit_count = 0;
    int year = 0;
    int month = 1, day = 1, hour = 0, minute = 0, second = 0;
    GTimeZone* zone = NULL;
    GDateTime* date;

    trimmed = g_strstrip(g_strdup(raw ? raw : ""));
    s = trimmed;
    if (g_str_has_prefix(s, "D:")) s += 2;
    len = strlen(s);
    if (len < 4) {
        g_free(trimmed);
        return NULL;
    }

    while (digit_count < len && isdigit((unsigned char)s[digit_count])) ++digit_count;
    /* Fields are fixed-width pairs after the 4-digit year; an odd digit count
     * means a partial field, and 15+ digits is not a date. */
    if (digit_count < 4 || digit_count > 14 || (digit_count % 2) != 0) {
        g_free(trimmed);
        return NULL;
    }

    for (pos = 0; pos < 4; ++pos) year = year * 10 + (s[pos] - '0');
    if (year <= 0) {
        g_free(trimmed);
        return NULL;
    }

    if (pos < digit_count && !spdf_props_read_two_digits(s, len, &pos, &month)) goto reject;
    if (pos < digit_count && !spdf_props_read_two_digits(s, len, &pos, &day)) goto reject;
    if (pos < digit_count && !spdf_props_read_two_digits(s, len, &pos, &hour)) goto reject;
    if (pos < digit_count && !spdf_props_read_two_digits(s, len, &pos, &minute)) goto reject;
    if (pos < digit_count && !spdf_props_read_two_digits(s, len, &pos, &second)) goto reject;
    if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) goto reject;

    /* Optional offset: Z, or +/-HH with optional 'mm (apostrophes optional /
     * unbalanced in the wild). Missing offset = local time. A started-but-
     * malformed offset (e.g. "+8") invalidates the whole date. */
    if (pos < len && (s[pos] == 'Z' || s[pos] == 'z')) {
        zone = g_time_zone_new_utc();
        ++pos;
        if (pos < len && s[pos] == '0') { /* tolerate Z00'00' */
            int zh = 0, zm = 0;
            if (!spdf_props_read_two_digits(s, len, &pos, &zh) || zh != 0) goto reject;
            if (pos < len && s[pos] == '\'') ++pos;
            if (pos < len && isdigit((unsigned char)s[pos])) {
                if (!spdf_props_read_two_digits(s, len, &pos, &zm) || zm != 0) goto reject;
            }
        }
    } else if (pos < len && (s[pos] == '+' || s[pos] == '-')) {
        int sign = s[pos] == '-' ? -1 : 1;
        int offset_hour = 0, offset_minute = 0;
        ++pos;
        if (!spdf_props_read_two_digits(s, len, &pos, &offset_hour) || offset_hour > 23) goto reject;
        if (pos < len && s[pos] == '\'') ++pos;
        if (pos < len && isdigit((unsigned char)s[pos])) {
            if (!spdf_props_read_two_digits(s, len, &pos, &offset_minute) || offset_minute > 59) goto reject;
        }
        zone = g_time_zone_new_offset(sign * (offset_hour * 3600 + offset_minute * 60));
    }
    if (!zone) zone = g_time_zone_new_local();
    g_free(trimmed);
    trimmed = NULL;

    date = g_date_time_new(zone, year, month, day, hour, minute, (gdouble)second);
    g_time_zone_unref(zone);
    if (!date) return NULL;

    /* GDateTime normalizes some impossible dates (Feb 30 -> Mar 1 on older
     * glib); require a round-trip match so those are rejected instead of
     * silently shifted (Mac NSCalendar round-trip check). */
    if (g_date_time_get_year(date) != year || g_date_time_get_month(date) != month ||
        g_date_time_get_day_of_month(date) != day || g_date_time_get_hour(date) != hour ||
        g_date_time_get_minute(date) != minute || g_date_time_get_second(date) != second) {
        g_date_time_unref(date);
        return NULL;
    }
    return date;

reject:
    if (zone) g_time_zone_unref(zone);
    g_free(trimmed);
    return NULL;
}

/* "2,437,120" — en-US style grouping (Mac used a POSIX-locale formatter so
 * both platforms print the same string). Caller frees. */
static inline char* spdf_props_grouped_number(guint64 value) {
    char plain[32];
    GString* out = g_string_new("");
    gsize len;

    g_snprintf(plain, sizeof(plain), "%" G_GUINT64_FORMAT, value);
    len = strlen(plain);
    for (gsize i = 0; i < len; ++i) {
        if (i > 0 && (len - i) % 3 == 0) g_string_append_c(out, ',');
        g_string_append_c(out, plain[i]);
    }
    return g_string_free(out, FALSE);
}

/* "2.4" / "2" (trailing ".0" trimmed, Mac spdf_one_decimal). */
static inline void spdf_props_one_decimal(double value, char* buf, gsize len) {
    gsize n;
    g_snprintf(buf, len, "%.1f", value);
    n = strlen(buf);
    if (n >= 2 && strcmp(buf + n - 2, ".0") == 0) buf[n - 2] = '\0';
}

/* "614 bytes", "2.4 MB (2,437,120 bytes)". 1000-based units (Finder
 * convention); the exact grouped byte count is appended from 1 KB up.
 * Caller frees. */
static inline char* spdf_props_format_file_size(guint64 bytes) {
    static const char* const units[] = {"KB", "MB", "GB", "TB", "PB"};
    double value;
    gsize unit = 0;
    char scaled[32];
    char* grouped;
    char* result;

    if (bytes == 1) return g_strdup("1 byte");
    if (bytes < 1000) return g_strdup_printf("%" G_GUINT64_FORMAT " bytes", bytes);
    value = (double)bytes / 1000.0;
    while (value >= 1000.0 && unit + 1 < G_N_ELEMENTS(units)) {
        value /= 1000.0;
        ++unit;
    }
    spdf_props_one_decimal(value, scaled, sizeof(scaled));
    grouped = spdf_props_grouped_number(bytes);
    result = g_strdup_printf("%s %s (%s bytes)", scaled, units[unit], grouped);
    g_free(grouped);
    return result;
}

/* "210 × 297 mm · 8.27 × 11.69 in · 595 × 842 pt" from PDF points (1/72 in).
 * Returns "" when either dimension is not a positive finite number. Caller
 * frees. */
static inline char* spdf_props_format_page_size(double width_pt, double height_pt) {
    if (!isfinite(width_pt) || !isfinite(height_pt) || width_pt <= 0 || height_pt <= 0) return g_strdup("");
    return g_strdup_printf("%.0f × %.0f mm · %.2f × %.2f in · %.0f × %.0f pt", width_pt * 25.4 / 72.0,
                           height_pt * 25.4 / 72.0, width_pt / 72.0, height_pt / 72.0, width_pt, height_pt);
}

/* One-line security summary: "Not encrypted",
 * "Encrypted — Standard V4 R4 128-bit AES", optionally followed by
 * " · printing and copying not allowed" for denied permissions. encryption
 * detail is used trimmed; empty/whitespace means unencrypted. Caller frees. */
static inline char* spdf_props_security_summary(const char* encryption_detail, gboolean can_print, gboolean can_copy,
                                                gboolean can_edit, gboolean can_annotate) {
    char* detail = g_strstrip(g_strdup(encryption_detail ? encryption_detail : ""));
    char* base =
        *detail ? g_strdup_printf("Encrypted — %s", detail) : g_strdup("Not encrypted");
    const char* denied[4];
    int denied_count = 0;
    GString* out;

    g_free(detail);
    if (!can_print) denied[denied_count++] = "printing";
    if (!can_copy) denied[denied_count++] = "copying";
    if (!can_edit) denied[denied_count++] = "editing";
    if (!can_annotate) denied[denied_count++] = "annotating";
    if (denied_count == 0) return base;

    out = g_string_new(base);
    g_free(base);
    g_string_append(out, " · ");
    for (int i = 0; i < denied_count; ++i) {
        if (i > 0) g_string_append(out, i == denied_count - 1 ? " and " : ", ");
        g_string_append(out, denied[i]);
    }
    g_string_append(out, " not allowed");
    return g_string_free(out, FALSE);
}

G_END_DECLS
