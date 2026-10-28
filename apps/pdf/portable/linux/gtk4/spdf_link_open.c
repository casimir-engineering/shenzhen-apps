// spdf_link_open.c -- szpdf: links on Linux (spdf_link_open.h).

#include "spdf_link_open.h"

#include <glib/gstdio.h>
#include <string.h>

#include "spdf_link.h"

typedef struct {
    SpdfWindow* win;
    char* path;
    char* part;
    char* host;
    int page;
} LinkDownload;

static void link_download_free(LinkDownload* d) {
    g_object_unref(d->win);
    g_free(d->path);
    g_free(d->part);
    g_free(d->host);
    g_free(d);
}

gboolean spdf_link_open_is_link(const char* argument) {
    return argument && g_ascii_strncasecmp(argument, "szpdf:", 6) == 0;
}

static gboolean starts_like_pdf(const char* path) {
    char head[1024];
    gsize got = 0;
    FILE* f = g_fopen(path, "rb");
    if (!f) return FALSE;
    got = fread(head, 1, sizeof(head), f);
    fclose(f);
    for (gsize i = 0; i + 5 <= got; ++i)
        if (memcmp(head + i, "%PDF-", 5) == 0) return TRUE;
    return FALSE;
}

// What the person who clicked the link reads when it did not open: why, in their terms.
static char* failure_message(int status, const char* http_code, const char* host) {
    long code = http_code ? strtol(http_code, NULL, 10) : 0;
    if (status == 22 && (code == 404 || code == 410))
        return g_strdup_printf("%s says there’s no document at this address. The link may be out of date.", host);
    if (status == 22 && (code == 401 || code == 403))
        return g_strdup_printf("%s didn’t allow the download. The document may need you to sign in on the "
                               "website first.", host);
    if (status == 22)
        return g_strdup_printf("%s couldn’t send the document right now (error %ld). Try the link again later.",
                               host, code);
    if (status == 35 || status == 51 || status == 58 || status == 60)
        return g_strdup_printf("ShenzhenPDF couldn’t make a secure connection to %s, so it didn’t download "
                               "the document.", host);
    if (status == 1)
        return g_strdup_printf("%s sent the download on to an address that isn’t secure (https), so ShenzhenPDF "
                               "stopped it.", host);
    if (status == 63) return g_strdup("The document is larger than 2 GB, too large to open from a link.");
    if (status == 23) return g_strdup("ShenzhenPDF couldn’t save the document. Check that the disk has free space.");
    return g_strdup_printf("ShenzhenPDF couldn’t reach %s. Check your internet connection, then open the link "
                           "again.", host);
}

static void download_done(GObject* source, GAsyncResult* result, gpointer user_data) {
    LinkDownload* d = user_data;
    GSubprocess* process = G_SUBPROCESS(source);
    char* out = NULL;
    GError* error = NULL;
    g_subprocess_communicate_utf8_finish(process, result, &out, NULL, &error);
    int status = !error && g_subprocess_get_if_exited(process) ? g_subprocess_get_exit_status(process) : -1;
    gboolean pdf = g_str_has_suffix(d->path, ".pdf") || g_str_has_suffix(d->path, ".PDF");
    if (status == 0 && pdf && !starts_like_pdf(d->part)) {
        spdf_window_show_toast(d->win, "The link leads to something that isn’t a PDF, so ShenzhenPDF can’t "
                                       "show it.");
        g_unlink(d->part);
    } else if (status == 0 && g_rename(d->part, d->path) == 0) {
        spdf_window_open_path(d->win, d->path, d->page > 0 ? d->page - 1 : 0, TRUE);
    } else {
        char* message = failure_message(status, out ? g_strstrip(out) : NULL, d->host);
        spdf_window_show_toast(d->win, message);
        g_free(message);
        g_unlink(d->part);
    }
    g_free(out);
    g_clear_error(&error);
    link_download_free(d);
}

void spdf_link_open(SpdfWindow* win, const char* text) {
    spdf_link link;
    char relative[1024];
    spdf_link_status status = spdf_link_parse(text, &link);
    if (status == SPDF_LINK_OK && !spdf_link_cache_relative_path(&link, relative, sizeof(relative)))
        status = SPDF_LINK_TOO_LONG;
    if (status != SPDF_LINK_OK) {
        spdf_window_show_toast(win, spdf_link_refusal_message(status));
        return;
    }
    char* path = g_build_filename(g_get_user_data_dir(), "shenzhenpdf", "links", relative, NULL);
    // Downloaded before: it opens from here, the same tab if it is open.
    if (g_file_test(path, G_FILE_TEST_IS_REGULAR)) {
        spdf_window_open_path(win, path, link.page > 0 ? link.page - 1 : 0, TRUE);
        g_free(path);
        return;
    }
    char* curl = g_find_program_in_path("curl");
    if (!curl) {
        spdf_window_show_toast(win, "Opening links needs curl, which isn’t installed on this computer.");
        g_free(path);
        return;
    }
    char* folder = g_path_get_dirname(path);
    g_mkdir_with_parents(folder, 0700);
    g_free(folder);
    LinkDownload* d = g_new0(LinkDownload, 1);
    d->win = g_object_ref(win);
    d->path = path;
    d->part = g_strconcat(path, ".part", NULL);
    d->host = g_strdup(link.host);
    d->page = link.page;
    // https only after a redirect (a link to http is only ever this computer, checked above), no bigger than 2 GB.
    const char* argv[] = {curl, "--fail", "--location", "--silent", "--show-error", "--proto", "=https,http",
                          "--proto-redir", "=https", "--max-filesize", "2147483648", "--connect-timeout", "20",
                          "--write-out", "%{http_code}", "--output", d->part, "--", link.url, NULL};
    GError* error = NULL;
    GSubprocess* process = g_subprocess_newv(argv, G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE,
                                             &error);
    g_free(curl);
    if (!process) {
        spdf_window_show_toast(win, "ShenzhenPDF couldn’t start the download.");
        g_clear_error(&error);
        link_download_free(d);
        return;
    }
    char* notice = g_strdup_printf("Downloading %s…", strrchr(path, '/') + 1);
    spdf_window_show_toast(win, notice);
    g_free(notice);
    g_subprocess_communicate_utf8_async(process, NULL, NULL, download_done, d);
    g_object_unref(process);
}
