/* A glib shim LAYERED on portable/win/tests/glib_shim, wide enough to compile
 * portable/linux/gtk4/spdf_props_internal.h with MSVC.
 *
 * WHY A SECOND DIRECTORY rather than a bigger shared shim: the same reason
 * glib_shim_search exists. The shared shim's header says it "must never grow
 * into" a glib port; the props header needs GString, g_strdup_printf and a
 * GDateTime, which nothing else in this port's differentials wants, so they
 * live here and this directory goes on the include path FIRST -- it is the one
 * that must resolve as <glib.h> -- with glib_shim behind it for the typedefs,
 * TRUE/FALSE, MAX/MIN/CLAMP, G_N_ELEMENTS and the allocators.
 *
 * WHAT IS REAL HERE, AND WHAT IS AN INSTRUMENT. This distinction decides what
 * the props differential proves, so it is spelled out rather than assumed:
 *
 *   - g_strdup, g_strstrip, g_str_has_prefix, g_strdup_printf, g_string_* and
 *     g_ascii_strup are REAL: the same truncation, the same trimming set
 *     (g_ascii_isspace), the same printf semantics. Every string the props
 *     header produces goes through these, so a difference the differential
 *     reports is a difference in the header and not in the shim.
 *
 *   - GDateTime and GTimeZone are an INSTRUMENT, not a port of glib's calendar.
 *     g_date_time_new() here stores the six components it was given and
 *     returns NULL for a date that does not exist (February 30th, and the
 *     31st of a 30-day month), which is glib's documented contract for the
 *     ranges this parser can produce. It does NOT reimplement glib's
 *     leap-second-free Julian arithmetic, because the parser never asks it to:
 *     the header validates every component's RANGE itself and uses the return
 *     value only as an existence check plus a round-trip.
 *
 *     So the props differential proves the PARSE -- which strings are accepted,
 *     what six numbers and what offset come out -- against the GTK original,
 *     and it does not independently prove the Gregorian calendar rule, because
 *     both sides would then be reading it from code in this repository.
 *     props_format_test.c closes that gap separately by sweeping every
 *     (year, month, day) triple past Windows' OWN calendar via
 *     SystemTimeToFileTime, which is an implementation nobody here wrote.
 *
 *   - g_shim_date_time_zone_kind() and g_shim_date_time_zone_offset() are NOT
 *     glib API. They report which zone the GTK code chose, so the differential
 *     can compare that decision against the port's has_offset/offset_seconds.
 *     Real glib would answer g_date_time_get_utc_offset() with the machine's
 *     actual local offset, which is not a comparable quantity.
 */
#ifndef SPDF_GLIB_SHIM_PROPS_H
#define SPDF_GLIB_SHIM_PROPS_H

/* By relative path: this directory shadows <glib.h>, so an angle-bracket
 * include here would find this same file. */
#include "../glib_shim/glib.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* --- strings -------------------------------------------------------------- */

#define G_GUINT64_FORMAT "llu"

static gchar* g_strdup(const gchar* s) {
    size_t n;
    gchar* out;
    if (!s) return NULL;
    n = strlen(s) + 1;
    out = (gchar*)malloc(n);
    if (!out) abort(); /* glib aborts on OOM; matching it keeps the sides equal */
    memcpy(out, s, n);
    return out;
}

static int g_shim_ascii_isspace(gchar c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

static gchar* g_strstrip(gchar* text) {
    size_t len;
    gchar* start;
    if (!text) return NULL;
    start = text;
    while (*start && g_shim_ascii_isspace(*start)) start++;
    if (start != text) memmove(text, start, strlen(start) + 1);
    len = strlen(text);
    while (len > 0 && g_shim_ascii_isspace(text[len - 1])) text[--len] = '\0';
    return text;
}

static gboolean g_str_has_prefix(const gchar* s, const gchar* prefix) {
    if (!s || !prefix) return FALSE;
    return strncmp(s, prefix, strlen(prefix)) == 0 ? TRUE : FALSE;
}

static gchar* g_strdup_printf(const gchar* fmt, ...) {
    va_list ap;
    int need;
    gchar* out;

    va_start(ap, fmt);
    need = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (need < 0) return NULL;
    out = (gchar*)malloc((size_t)need + 1);
    if (!out) abort();
    va_start(ap, fmt);
    vsnprintf(out, (size_t)need + 1, fmt, ap);
    va_end(ap);
    return out;
}

static gchar* g_strconcat(const gchar* first, ...) {
    va_list ap;
    size_t total;
    const gchar* piece;
    gchar* out;

    if (!first) return NULL;
    total = strlen(first);
    va_start(ap, first);
    while ((piece = va_arg(ap, const gchar*)) != NULL) total += strlen(piece);
    va_end(ap);
    out = (gchar*)malloc(total + 1);
    if (!out) abort();
    strcpy(out, first);
    va_start(ap, first);
    while ((piece = va_arg(ap, const gchar*)) != NULL) strcat(out, piece);
    va_end(ap);
    return out;
}

/* --- GString --------------------------------------------------------------
 * glib's public layout: only `str` and `len` are ABI, and the props header
 * touches nothing else. */

typedef struct {
    gchar* str;
    gsize len;
    gsize allocated_len;
} GString;

static void g_shim_string_reserve(GString* s, gsize want) {
    gsize capacity = s->allocated_len ? s->allocated_len : 32;
    gchar* grown;
    if (want + 1 <= s->allocated_len) return;
    while (capacity < want + 1) capacity *= 2;
    grown = (gchar*)realloc(s->str, capacity);
    if (!grown) abort();
    s->str = grown;
    s->allocated_len = capacity;
}

static GString* g_string_new(const gchar* init) {
    GString* s = (GString*)calloc(1, sizeof(GString));
    if (!s) abort();
    g_shim_string_reserve(s, init ? strlen(init) : 0);
    s->len = init ? strlen(init) : 0;
    if (init)
        memcpy(s->str, init, s->len + 1);
    else
        s->str[0] = '\0';
    return s;
}

static GString* g_string_append(GString* s, const gchar* text) {
    gsize n;
    if (!s || !text) return s;
    n = strlen(text);
    g_shim_string_reserve(s, s->len + n);
    memcpy(s->str + s->len, text, n + 1);
    s->len += n;
    return s;
}

static GString* g_string_append_c(GString* s, gchar c) {
    if (!s) return s;
    g_shim_string_reserve(s, s->len + 1);
    s->str[s->len++] = c;
    s->str[s->len] = '\0';
    return s;
}

static gchar* g_string_free(GString* s, gboolean free_segment) {
    gchar* data;
    if (!s) return NULL;
    data = s->str;
    if (free_segment) {
        free(data);
        data = NULL;
    }
    free(s);
    return data;
}

/* --- GDateTime / GTimeZone (the instrument; see this file's header) -------- */

typedef struct {
    int is_local; /* 1 when g_time_zone_new_local() made it */
    int offset;   /* seconds east of UTC; 0 for local and for UTC */
} GTimeZone;

typedef struct {
    int year;
    int month;
    int day;
    int hour;
    int minute;
    int second;
    int zone_is_local;
    int zone_offset;
} GDateTime;

static GTimeZone* g_shim_zone_new(int is_local, int offset) {
    GTimeZone* z = (GTimeZone*)calloc(1, sizeof(GTimeZone));
    if (!z) abort();
    z->is_local = is_local;
    z->offset = offset;
    return z;
}

static GTimeZone* g_time_zone_new_utc(void) {
    return g_shim_zone_new(0, 0);
}
static GTimeZone* g_time_zone_new_offset(int seconds) {
    return g_shim_zone_new(0, seconds);
}
static GTimeZone* g_time_zone_new_local(void) {
    return g_shim_zone_new(1, 0);
}
static void g_time_zone_unref(GTimeZone* zone) {
    free(zone);
}

static int g_shim_days_in_month(int year, int month) {
    static const int k_days[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (month < 1 || month > 12) return 0;
    if (month == 2 && ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0)) return 29;
    return k_days[month - 1];
}

static GDateTime* g_date_time_new(GTimeZone* zone, int year, int month, int day, int hour, int minute,
                                  gdouble seconds) {
    GDateTime* d;
    if (year < 1 || year > 9999) return NULL;
    if (month < 1 || month > 12) return NULL;
    if (day < 1 || day > g_shim_days_in_month(year, month)) return NULL;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return NULL;
    if (seconds < 0.0 || seconds >= 60.0) return NULL;
    d = (GDateTime*)calloc(1, sizeof(GDateTime));
    if (!d) abort();
    d->year = year;
    d->month = month;
    d->day = day;
    d->hour = hour;
    d->minute = minute;
    d->second = (int)seconds;
    d->zone_is_local = zone ? zone->is_local : 1;
    d->zone_offset = zone ? zone->offset : 0;
    return d;
}

static void g_date_time_unref(GDateTime* d) {
    free(d);
}
static int g_date_time_get_year(GDateTime* d) {
    return d ? d->year : 0;
}
static int g_date_time_get_month(GDateTime* d) {
    return d ? d->month : 0;
}
static int g_date_time_get_day_of_month(GDateTime* d) {
    return d ? d->day : 0;
}
static int g_date_time_get_hour(GDateTime* d) {
    return d ? d->hour : 0;
}
static int g_date_time_get_minute(GDateTime* d) {
    return d ? d->minute : 0;
}
static int g_date_time_get_second(GDateTime* d) {
    return d ? d->second : 0;
}

/* NOT glib API -- the instrument hooks. See this file's header. */
static int g_shim_date_time_zone_kind(GDateTime* d) {
    return d && d->zone_is_local ? 0 : 1; /* 0 = local (no offset in the string) */
}
static int g_shim_date_time_zone_offset(GDateTime* d) {
    return d ? d->zone_offset : 0;
}

#endif /* SPDF_GLIB_SHIM_PROPS_H */
