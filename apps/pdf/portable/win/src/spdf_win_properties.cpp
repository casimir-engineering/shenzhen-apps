/* spdf_win_properties.cpp — the properties MODEL. The window that shows it is
 * spdf_win_properties_dialog.cpp; see spdf_win_properties.h for why the two are
 * separate files. */

#include "spdf_win_properties.h"

#include "spdf_win_props_format.h"

#include <stdio.h>
#include <string.h>

/* --- row building --------------------------------------------------------- */

static void props_add(spdf_win_properties* p, const char* section, const char* label, const char* value) {
    spdf_win_props_row* row;
    if (!p || p->count >= SPDF_WIN_PROPS_MAX_ROWS) return;
    row = &p->rows[p->count++];
    _snprintf_s(row->section, sizeof(row->section), _TRUNCATE, "%s", section ? section : "");
    _snprintf_s(row->label, sizeof(row->label), _TRUNCATE, "%s", label ? label : "");
    _snprintf_s(row->value, sizeof(row->value), _TRUNCATE, "%s", value ? value : "");
}

/* Both originals omit a metadata row whose value is empty rather than showing
 * an empty one; a panel full of blank labels tells the reader nothing. */
static void props_add_nonempty(spdf_win_properties* p, const char* section, const char* label, const char* value) {
    if (value && *value) props_add(p, section, label, value);
}

static void props_metadata(spdf_document* doc, const char* key, char* out, size_t out_len) {
    char raw[4096];
    if (!out || out_len == 0) return;
    out[0] = '\0';
    if (!doc || !spdf_lookup_metadata(doc, key, raw, sizeof(raw))) return;
    spdf_win_props_strip(raw, out, out_len);
}

/* --- dates ----------------------------------------------------------------
 *
 * The parse is spdf_win_props_parse_pdf_date() (shared, differentially tested);
 * everything here is the Windows half: turning six numbers into the reader's
 * own date format, and comparing a PDF date against a file time. */

/* A parsed PDF date as a UTC FILETIME, so it can be compared with the file's
 * own times. `has_offset` decides which conversion: an explicit offset is
 * subtracted to reach UTC, and a bare date means LOCAL time (PDF 32000-1
 * 7.9.4), which is what TzSpecificLocalTimeToSystemTime is for — it applies the
 * DST rule in force on THAT date, which subtracting the current bias would
 * get wrong for half the year. Returns 0 when the date cannot be represented. */
static int props_pdf_date_to_filetime(const spdf_win_props_pdf_date* date, FILETIME* out) {
    SYSTEMTIME local;
    SYSTEMTIME utc;
    ULARGE_INTEGER value;

    if (!date || !date->valid || !out) return 0;
    memset(&local, 0, sizeof(local));
    local.wYear = (WORD)date->year;
    local.wMonth = (WORD)date->month;
    local.wDay = (WORD)date->day;
    local.wHour = (WORD)date->hour;
    local.wMinute = (WORD)date->minute;
    local.wSecond = (WORD)date->second;

    if (date->has_offset) {
        if (!SystemTimeToFileTime(&local, out)) return 0;
        value.LowPart = out->dwLowDateTime;
        value.HighPart = out->dwHighDateTime;
        /* 100 ns ticks. Subtracting the offset converts "this wall clock at
         * UTC+offset" into UTC. */
        value.QuadPart -= (LONGLONG)date->offset_seconds * 10000000LL;
        out->dwLowDateTime = value.LowPart;
        out->dwHighDateTime = value.HighPart;
        return 1;
    }
    if (!TzSpecificLocalTimeToSystemTime(NULL, &local, &utc)) return 0;
    return SystemTimeToFileTime(&utc, out) ? 1 : 0;
}

/* "13/04/2024 14:07" in the reader's own locale: the short date plus hours and
 * minutes. GTK formats "%x %R" and macOS uses medium date + short time; the
 * Windows spelling of the same intent is DATE_SHORTDATE + TIME_NOSECONDS, and
 * like both originals it deliberately follows the machine's locale rather than
 * pinning a format — a date is for the reader, unlike the file size, which is
 * pinned to en-US on all three platforms so two readers can compare it. */
static void props_format_filetime_local(const FILETIME* utc, char* out, size_t out_len) {
    FILETIME local_ft;
    SYSTEMTIME local;
    wchar_t date_text[128];
    wchar_t time_text[128];
    wchar_t joined[264];

    if (!out || out_len == 0) return;
    out[0] = '\0';
    if (!utc) return;
    if (!FileTimeToLocalFileTime(utc, &local_ft)) return;
    if (!FileTimeToSystemTime(&local_ft, &local)) return;
    if (GetDateFormatEx(LOCALE_NAME_USER_DEFAULT, DATE_SHORTDATE, &local, NULL, date_text,
                        (int)(sizeof(date_text) / sizeof(date_text[0])), NULL) <= 0)
        return;
    if (GetTimeFormatEx(LOCALE_NAME_USER_DEFAULT, TIME_NOSECONDS, &local, NULL, time_text,
                        (int)(sizeof(time_text) / sizeof(time_text[0]))) <= 0)
        return;
    _snwprintf_s(joined, sizeof(joined) / sizeof(joined[0]), _TRUNCATE, L"%s %s", date_text, time_text);
    WideCharToMultiByte(CP_UTF8, 0, joined, -1, out, (int)out_len, NULL, NULL);
}

/* On-disk dates show only when there is no PDF counterpart or when the two
 * differ by more than a minute — the Mac rule (60 s), which exists because a
 * PDF written by a tool that stamps its own ModDate is normally within a second
 * of the file's, and two rows saying the same thing is noise. */
#define PROPS_DATE_SLOP_TICKS (60LL * 10000000LL)

static int props_times_differ(const FILETIME* a, const FILETIME* b) {
    ULARGE_INTEGER x, y;
    LONGLONG diff;
    x.LowPart = a->dwLowDateTime;
    x.HighPart = a->dwHighDateTime;
    y.LowPart = b->dwLowDateTime;
    y.HighPart = b->dwHighDateTime;
    diff = (LONGLONG)x.QuadPart - (LONGLONG)y.QuadPart;
    if (diff < 0) diff = -diff;
    return diff > PROPS_DATE_SLOP_TICKS;
}

typedef struct props_disk_info {
    int have;
    unsigned long long size;
    FILETIME created;
    FILETIME modified;
} props_disk_info;

static void props_read_disk_info(const wchar_t* path, props_disk_info* out) {
    WIN32_FILE_ATTRIBUTE_DATA data;
    memset(out, 0, sizeof(*out));
    if (!path || !*path) return;
    if (!GetFileAttributesExW(path, GetFileExInfoStandard, &data)) return;
    out->have = 1;
    out->size = ((unsigned long long)data.nFileSizeHigh << 32) | (unsigned long long)data.nFileSizeLow;
    out->created = data.ftCreationTime;
    out->modified = data.ftLastWriteTime;
}

/* One "Created"/"Modified" pair: the PDF date when it parses, the raw string
 * verbatim when it does not (a date this app cannot read is still information),
 * then the on-disk date when it adds something. */
static void props_add_date_pair(spdf_win_properties* p, spdf_document* doc, const char* meta_key, const char* label,
                                const char* disk_label, const FILETIME* disk_time, int have_disk) {
    char raw[256];
    char text[256];
    spdf_win_props_pdf_date parsed;
    FILETIME pdf_time;
    int have_pdf = 0;

    props_metadata(doc, meta_key, raw, sizeof(raw));
    if (spdf_win_props_parse_pdf_date(raw, &parsed) && props_pdf_date_to_filetime(&parsed, &pdf_time)) {
        have_pdf = 1;
        props_format_filetime_local(&pdf_time, text, sizeof(text));
        props_add(p, "Dates", label, text[0] ? text : raw);
    } else if (raw[0]) {
        props_add(p, "Dates", label, raw);
    }
    if (!have_disk) return;
    if (have_pdf && !props_times_differ(disk_time, &pdf_time)) return;
    props_format_filetime_local(disk_time, text, sizeof(text));
    props_add_nonempty(p, "Dates", disk_label, text);
}

/* --- the four groups ------------------------------------------------------ */

static void props_document_group(spdf_win_properties* p, spdf_document* doc) {
    static const struct {
        const char* label;
        const char* key;
    } k_rows[] = {
        {"Title", "info:Title"},       {"Author", "info:Author"},     {"Subject", "info:Subject"},
        {"Keywords", "info:Keywords"}, {"Creator", "info:Creator"},   {"Producer", "info:Producer"},
    };
    char value[SPDF_WIN_PROPS_VALUE_MAX];
    char encryption[256];
    char security[SPDF_WIN_PROPS_VALUE_MAX];
    size_t i;

    for (i = 0; i < sizeof(k_rows) / sizeof(k_rows[0]); ++i) {
        props_metadata(doc, k_rows[i].key, value, sizeof(value));
        props_add_nonempty(p, "Document", k_rows[i].label, value);
    }
    props_metadata(doc, "encryption", encryption, sizeof(encryption));
    /* MuPDF reports "None" for an unencrypted PDF; both originals blank it so
     * the summary reads "Not encrypted" rather than "Encrypted - None". */
    if (strcmp(encryption, "None") == 0) encryption[0] = '\0';
    if (encryption[0] && spdf_needs_password(doc)) {
        char with_note[256];
        _snprintf_s(with_note, sizeof(with_note), _TRUNCATE, "%s (password protected)", encryption);
        _snprintf_s(encryption, sizeof(encryption), _TRUNCATE, "%s", with_note);
    }
    /* 'c' is passed through rather than hard-coded to 1: the core already
     * answers 1 unconditionally, and asking it keeps the one place that
     * decision lives in the core. No gate is built on the answer. */
    spdf_win_props_security_summary(encryption, spdf_has_permission(doc, 'p'), spdf_has_permission(doc, 'c'),
                                    spdf_has_permission(doc, 'e'), spdf_has_permission(doc, 'n'), security,
                                    sizeof(security));
    props_add(p, "Document", "Security", security);
}

static void props_file_group(spdf_win_properties* p, spdf_document* doc, const wchar_t* path,
                             const props_disk_info* disk) {
    char utf8[SPDF_WIN_PROPS_VALUE_MAX];
    char format[64];
    char size_text[64];

    if (path && *path && WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8, (int)sizeof(utf8), NULL, NULL) > 0)
        props_add(p, "File", "Location", utf8);
    if (disk->have) {
        spdf_win_props_format_file_size(disk->size, size_text, sizeof(size_text));
        props_add(p, "File", "Size", size_text);
    }
    props_metadata(doc, "format", format, sizeof(format));
    if (!format[0] && path) {
        /* No format handler answer: fall back to the uppercased extension, the
         * same fallback spdf_props.c makes. */
        const wchar_t* dot = wcsrchr(path, L'.');
        if (dot && dot[1]) {
            size_t i;
            WideCharToMultiByte(CP_UTF8, 0, dot + 1, -1, format, (int)sizeof(format), NULL, NULL);
            for (i = 0; format[i]; ++i)
                if (format[i] >= 'a' && format[i] <= 'z') format[i] = (char)(format[i] - 'a' + 'A');
        }
    }
    props_add_nonempty(p, "File", "Format", format);
}

static void props_statistics_group(spdf_win_properties* p, spdf_document* doc, int page_index, int outline_count,
                                   int comment_count) {
    int page_count = spdf_page_count(doc);
    char grouped[40];
    char value[SPDF_WIN_PROPS_VALUE_MAX];

    spdf_win_props_grouped_number((unsigned long long)(page_count > 0 ? page_count : 0), grouped, sizeof(grouped));
    props_add(p, "Statistics", "Pages", grouped);

    if (page_index >= 0 && page_index < page_count) {
        float width = 0.0f, height = 0.0f;
        char err[256] = "";
        if (spdf_page_size(doc, page_index, &width, &height, err, sizeof(err))) {
            char size_text[128];
            spdf_win_props_format_page_size(width, height, size_text, sizeof(size_text));
            if (size_text[0]) {
                char label[SPDF_WIN_PROPS_LABEL_MAX];
                _snprintf_s(label, sizeof(label), _TRUNCATE, "Page %d size", page_index + 1);
                props_add(p, "Statistics", label, size_text);
            }
        }
    }

    if (outline_count > 0) {
        spdf_win_props_grouped_number((unsigned long long)outline_count, grouped, sizeof(grouped));
        _snprintf_s(value, sizeof(value), _TRUNCATE, "%s entries", grouped);
        props_add(p, "Statistics", "Table of contents", value);
    } else {
        props_add(p, "Statistics", "Table of contents", "None");
    }
    if (comment_count > 0) {
        spdf_win_props_grouped_number((unsigned long long)comment_count, grouped, sizeof(grouped));
        props_add(p, "Statistics", "Annotations", grouped);
    } else {
        props_add(p, "Statistics", "Annotations", "None");
    }
}

/* --- the model ------------------------------------------------------------ */

int spdf_win_properties_collect(spdf_document* doc, const wchar_t* path, int page_index, int outline_count,
                                int comment_count, spdf_win_properties* out) {
    props_disk_info disk;

    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!doc) return 0;

    /* -1 means "the caller has no cached count": load it here, once, on the
     * way to a dialog the reader explicitly asked for. Nothing loads an
     * outline or a comment list on the caller's behalf at any other time. */
    if (outline_count < 0) {
        spdf_outline outline;
        char err[256] = "";
        memset(&outline, 0, sizeof(outline));
        outline_count = 0;
        if (spdf_load_outline(doc, &outline, err, sizeof(err))) {
            outline_count = outline.count;
            spdf_free_outline(&outline);
        }
    }
    if (comment_count < 0) {
        spdf_comments comments;
        char err[256] = "";
        memset(&comments, 0, sizeof(comments));
        comment_count = 0;
        if (spdf_load_comments(doc, &comments, err, sizeof(err))) {
            comment_count = comments.count;
            spdf_free_comments(&comments);
        }
    }

    props_read_disk_info(path, &disk);
    props_document_group(out, doc);
    props_add_date_pair(out, doc, "info:CreationDate", "Created", "Created (on disk)", &disk.created, disk.have);
    props_add_date_pair(out, doc, "info:ModDate", "Modified", "Modified (on disk)", &disk.modified, disk.have);
    props_file_group(out, doc, path, &disk);
    props_statistics_group(out, doc, page_index, outline_count, comment_count);
    return out->count;
}

int spdf_win_properties_transcript(const spdf_win_properties* props, char* out, size_t out_len) {
    size_t used = 0;
    const char* section = NULL;
    int i;

    if (!out || out_len == 0) return 0;
    out[0] = '\0';
    if (!props) return 0;
    for (i = 0; i < props->count; ++i) {
        const spdf_win_props_row* row = &props->rows[i];
        int written;
        if (!section || strcmp(section, row->section) != 0) {
            written = _snprintf_s(out + used, out_len - used, _TRUNCATE, "%s%s\n", used ? "\n" : "", row->section);
            /* _TRUNCATE returns -1 AND leaves a NUL-terminated partial string,
             * so `used` must be re-derived rather than left where it was: a
             * caller that trusted the return value would otherwise index into
             * the middle of the truncated line. */
            if (written < 0) {
                used = strlen(out);
                break;
            }
            used += (size_t)written;
            section = row->section;
        }
        written = _snprintf_s(out + used, out_len - used, _TRUNCATE, "  %s: %s\n", row->label, row->value);
        if (written < 0) {
            used = strlen(out);
            break;
        }
        used += (size_t)written;
    }
    return (int)used;
}
