/* The composer's Paste (Ctrl+V, Cmd+V on a Mac; mirrors mac/SZFriendsComposerAttach.m): files copied in a file manager
 * become chips, as dropped files do, and so does an image (a screenshot), saved as a PNG named for when it was
 * pasted. Text pastes as text, and an image that comes with words pastes them, unless the words are only the image's
 * own link (a browser's Copy Image). Files go from where they are; nothing is read or sent until Send. */

#include "gtk/szfriends_gtk_composer_private.h"

#include <glib/gstdio.h>

typedef struct {
    SZFriendsGtkComposerView *composer; /* held by its conversation's reference below */
    GtkWidget *root;                    /* weak: a composer gone by the time the clipboard answers takes nothing */
    SZFriendsGtkConversation *conversation;
    char *text; /* the clipboard's words, while the picture is asked for */
} SZFriendsGtkPaste;

static SZFriendsGtkPaste *paste_new(SZFriendsGtkComposerView *composer) {
    SZFriendsGtkPaste *paste = g_new0(SZFriendsGtkPaste, 1);
    paste->composer = composer;
    paste->conversation = szfriends_gtk_conversation_ref(composer->conversation);
    g_set_weak_pointer(&paste->root, composer->root);
    return paste;
}

static SZFriendsGtkComposerView *paste_composer(SZFriendsGtkPaste *paste) {
    return paste->root && paste->conversation->composer == paste->composer ? paste->composer : NULL;
}

static void paste_free(SZFriendsGtkPaste *paste) {
    g_clear_weak_pointer(&paste->root);
    g_free(paste->text);
    szfriends_gtk_conversation_unref(paste->conversation);
    g_free(paste);
}

static gboolean takes_attachments(SZFriendsGtkComposerView *composer) {
    return composer->enabled && composer->accepts_drops && !composer->sending;
}

/* Words, unless they are only a link (an image's own address) or empty. */
static gboolean holds_words(const char *text) {
    g_autofree char *trimmed = g_strstrip(g_strdup(text ? text : ""));
    if (!*trimmed) return FALSE;
    for (const char *c = trimmed; *c; c++)
        if (g_ascii_isspace(*c)) return TRUE;
    const char *scheme = g_uri_peek_scheme(trimmed); /* lowercase, interned */
    return !scheme || !(strcmp(scheme, "http") == 0 || strcmp(scheme, "https") == 0 || strcmp(scheme, "file") == 0);
}

/* As GTK's own paste: over the selection, one step for Undo. */
static void insert_text(SZFriendsGtkComposerView *composer, const char *text) {
    if (!text || !*text) return;
    gtk_text_buffer_begin_user_action(composer->buffer);
    gtk_text_buffer_delete_selection(composer->buffer, TRUE, TRUE);
    gtk_text_buffer_insert_interactive_at_cursor(composer->buffer, text, -1, TRUE);
    gtk_text_buffer_end_user_action(composer->buffer);
}

/* "Pasted image 2026-10-28 at 14.02.05.png", in a new private folder of its own. */
static char *save_png(GdkTexture *texture) {
    g_autoptr(GDateTime) now = g_date_time_new_now_local();
    g_autofree char *when = g_date_time_format(now, "%Y-%m-%d at %H.%M.%S");
    g_autofree char *name = g_strdup_printf("Pasted image %s.png", when);
    g_autofree char *folder = g_dir_make_tmp("Shenzhen Friends paste XXXXXX", NULL);
    if (!folder) return NULL;
    char *path = g_build_filename(folder, name, NULL);
    g_autoptr(GBytes) png = gdk_texture_save_to_png_bytes(texture);
    gsize size = 0;
    const char *data = png ? g_bytes_get_data(png, &size) : NULL;
    if (!data || !g_file_set_contents_full(path, data, (gssize)size, G_FILE_SET_CONTENTS_CONSISTENT, 0600, NULL)) {
        g_free(path);
        return NULL;
    }
    return path;
}

static void texture_read(GObject *source, GAsyncResult *result, gpointer data) {
    SZFriendsGtkPaste *paste = data;
    g_autoptr(GdkTexture) texture = gdk_clipboard_read_texture_finish(GDK_CLIPBOARD(source), result, NULL);
    SZFriendsGtkComposerView *composer = paste_composer(paste);
    g_autofree char *path = composer && texture ? save_png(texture) : NULL;
    if (path) {
        GPtrArray *items = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_host_item_free);
        g_autofree char *name = g_path_get_basename(path);
        g_ptr_array_add(items, szfriends_gtk_host_item_new(name, NULL, NULL, path, NULL));
        szfriends_gtk_composer_set_error(composer, NULL);
        szfriends_gtk_composer_add_items(composer, items);
        szfriends_gtk_composer_save_draft(composer);
        g_ptr_array_unref(items);
    } else if (composer && !texture) {
        insert_text(composer, paste->text); /* no picture: the link, as text */
    }
    paste_free(paste);
}

static void text_read(GObject *source, GAsyncResult *result, gpointer data) {
    SZFriendsGtkPaste *paste = data;
    paste->text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, NULL);
    SZFriendsGtkComposerView *composer = paste_composer(paste);
    if (composer && holds_words(paste->text)) {
        insert_text(composer, paste->text);
        paste_free(paste);
        return;
    }
    if (composer) gdk_clipboard_read_texture_async(GDK_CLIPBOARD(source), NULL, texture_read, paste);
    else paste_free(paste);
}

/* A URI list as GDK's macOS backend writes Finder's files into it: each URL escaped once more, "file%3A///Users/..."
 * for "file:///Users/...", which its own file list reader then refuses. Read leniently, local files only. */
static GSList *files_from_uri_list(const char *list) {
    GSList *files = NULL;
    g_auto(GStrv) lines = g_strsplit(list ? list : "", "\n", -1);
    for (char **line = lines; *line && g_slist_length(files) < 100; line++) {
        g_strstrip(*line);
        if (!**line || **line == '#') continue;
        if (g_ascii_strncasecmp(*line, "file%3A", 7) == 0) {
            g_autofree char *url = g_uri_unescape_string(*line, NULL);
            if (url && g_str_has_prefix(url, "file://")) files = g_slist_prepend(files, g_file_new_for_path(url + 7));
        } else if (g_str_has_prefix(*line, "file://")) {
            files = g_slist_prepend(files, g_file_new_for_uri(*line));
        }
    }
    return g_slist_reverse(files);
}

static void uri_list_read(GObject *source, GAsyncResult *result, gpointer data) {
    SZFriendsGtkPaste *paste = data;
    g_autoptr(GInputStream) stream = gdk_clipboard_read_finish(GDK_CLIPBOARD(source), result, NULL, NULL);
    g_autoptr(GByteArray) bytes = g_byte_array_new();
    guint8 chunk[4096];
    gssize got;
    while (stream && bytes->len < 1 << 20 && (got = g_input_stream_read(stream, chunk, sizeof chunk, NULL, NULL)) > 0)
        g_byte_array_append(bytes, chunk, (guint)got);
    g_byte_array_append(bytes, (const guint8 *)"", 1);
    GSList *files = files_from_uri_list((const char *)bytes->data);
    SZFriendsGtkComposerView *composer = paste_composer(paste);
    if (composer && files) {
        szfriends_gtk_composer_attach_files(composer, files);
        paste_free(paste);
    } else if (composer) {
        gdk_clipboard_read_text_async(GDK_CLIPBOARD(source), NULL, text_read, paste);
    } else {
        paste_free(paste);
    }
    g_slist_free_full(files, g_object_unref);
}

static void files_read(GObject *source, GAsyncResult *result, gpointer data) {
    SZFriendsGtkPaste *paste = data;
    const GValue *value = gdk_clipboard_read_value_finish(GDK_CLIPBOARD(source), result, NULL);
    SZFriendsGtkComposerView *composer = paste_composer(paste);
    GSList *files = value && G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)
        ? gdk_file_list_get_files(g_value_get_boxed(value)) : NULL;
    gboolean local = files != NULL;
    for (GSList *file = files; file; file = file->next) local = local && g_file_is_native(file->data);
    if (composer && local) {
        szfriends_gtk_composer_attach_files(composer, files);
        g_slist_free(files);
        paste_free(paste);
        return;
    }
    g_slist_free(files); /* none, or URLs GDK's macOS backend mangled: read the list itself */
    static const char *uri_list[] = {"text/uri-list", NULL};
    if (composer)
        gdk_clipboard_read_async(GDK_CLIPBOARD(source), uri_list, G_PRIORITY_DEFAULT, NULL, uri_list_read, paste);
    else paste_free(paste);
}

/* Files first, then words, then a picture. Asked for in that order rather than judged from the clipboard's advertised
 * formats, which GDK's macOS backend refreshes only when the app is activated: a screenshot taken while the app is in
 * front would otherwise paste nothing. */
static void paste_clipboard(GtkTextView *view, gpointer data) {
    SZFriendsGtkComposerView *composer = data;
    if (!takes_attachments(composer)) return; /* GTK pastes the text */
    g_signal_stop_emission_by_name(view, "paste-clipboard");
    gdk_clipboard_read_value_async(gtk_widget_get_clipboard(GTK_WIDGET(view)), GDK_TYPE_FILE_LIST, G_PRIORITY_DEFAULT,
                                   NULL, files_read, paste_new(composer));
}

void szfriends_gtk_composer_add_paste(SZFriendsGtkComposerView *composer) {
    g_signal_connect(composer->text_view, "paste-clipboard", G_CALLBACK(paste_clipboard), composer);
}
