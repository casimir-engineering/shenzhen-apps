/* Drop classification and the drag strings (szfriends_gtk_drops.h). */

#include "gtk/szfriends_gtk_drops.h"

#include <gdk/gdk.h>
#include <string.h>

GType *szfriends_gtk_drop_types(const SZFriendsGtkHost *host, gsize *n_types) {
    gsize extra = host && host->extra_drop_types ? host->n_extra_drop_types : 0;
    GType *types = g_new0(GType, extra + 1);
    types[0] = GDK_TYPE_FILE_LIST;
    for (gsize i = 0; i < extra; i++) types[i + 1] = host->extra_drop_types[i];
    *n_types = extra + 1;
    return types;
}

/* What the helper does with one file (SZFriendsOpenSnapshotSource): it reads a regular file, refuses a folder, and
 * refuses a link without following it, as it does a FIFO, a socket or a device. Classified without following links,
 * then, so the drag says no before the person lets go. A link to a folder counts as a folder, the words the person
 * expects for what Files shows as one; a file that vanished stays acceptable while dragging, and the helper answers
 * file_missing with its own words. */
static SZFriendsGtkDropVerdict verdict_for_file(GFile *file) {
    switch (g_file_query_file_type(file, G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL)) {
    case G_FILE_TYPE_REGULAR:
    case G_FILE_TYPE_UNKNOWN:
        return SZFRIENDS_GTK_DROP_ACCEPT;
    case G_FILE_TYPE_DIRECTORY:
        return SZFRIENDS_GTK_DROP_REFUSE_FOLDER;
    case G_FILE_TYPE_SYMBOLIC_LINK:
        return g_file_query_file_type(file, G_FILE_QUERY_INFO_NONE, NULL) == G_FILE_TYPE_DIRECTORY
                   ? SZFRIENDS_GTK_DROP_REFUSE_FOLDER
                   : SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE;
    default:
        return SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE;
    }
}

SZFriendsGtkDropVerdict szfriends_gtk_drop_verdict_for_files(GSList *files) {
    if (!files) return SZFRIENDS_GTK_DROP_NONE;
    SZFriendsGtkDropVerdict verdict = SZFRIENDS_GTK_DROP_ACCEPT;
    for (GSList *item = files; item; item = item->next) {
        GFile *file = item->data;
        char *path = G_IS_FILE(file) ? g_file_get_path(file) : NULL;
        if (!path) return SZFRIENDS_GTK_DROP_NONE;
        g_free(path);
        /* One bad file sends none; a folder's words win, being the ones a person meets most. */
        SZFriendsGtkDropVerdict one = verdict_for_file(file);
        if (one == SZFRIENDS_GTK_DROP_REFUSE_FOLDER || verdict == SZFRIENDS_GTK_DROP_ACCEPT) verdict = one;
    }
    return verdict;
}

gboolean szfriends_gtk_drop_refused(SZFriendsGtkDropVerdict verdict) {
    return verdict == SZFRIENDS_GTK_DROP_REFUSE_FOLDER || verdict == SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE;
}

static gboolean is_host_type(const SZFriendsGtkHost *host, GType type) {
    for (gsize i = 0; host && host->extra_drop_types && i < host->n_extra_drop_types; i++)
        if (host->extra_drop_types[i] == type) return TRUE;
    return FALSE;
}

SZFriendsGtkDropVerdict szfriends_gtk_drop_verdict(const SZFriendsGtkHost *host, const GValue *value) {
    if (!value || !G_IS_VALUE(value)) return SZFRIENDS_GTK_DROP_NONE;
    if (G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) {
        GdkFileList *list = g_value_get_boxed(value);
        GSList *files = list ? gdk_file_list_get_files(list) : NULL;
        SZFriendsGtkDropVerdict verdict = szfriends_gtk_drop_verdict_for_files(files);
        g_slist_free(files);
        return verdict;
    }
    return is_host_type(host, G_VALUE_TYPE(value)) ? SZFRIENDS_GTK_DROP_ACCEPT : SZFRIENDS_GTK_DROP_NONE;
}

GPtrArray *szfriends_gtk_drop_items(const SZFriendsGtkHost *host, const GValue *value,
                                    SZFriendsGtkDropVerdict *verdict_out) {
    GPtrArray *items = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_host_item_free);
    SZFriendsGtkDropVerdict verdict = szfriends_gtk_drop_verdict(host, value);
    if (verdict == SZFRIENDS_GTK_DROP_ACCEPT && G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) {
        GdkFileList *list = g_value_get_boxed(value);
        GSList *files = gdk_file_list_get_files(list);
        for (GSList *item = files; item; item = item->next) {
            char *path = g_file_get_path(item->data);
            char *name = g_file_get_basename(item->data);
            g_ptr_array_add(items, szfriends_gtk_host_item_new(name, NULL, NULL, path, NULL));
            g_free(path);
            g_free(name);
        }
        g_slist_free(files);
    } else if (verdict == SZFRIENDS_GTK_DROP_ACCEPT && host && host->items_from_drop) {
        GPtrArray *resolved = host->items_from_drop(host->host_data, value);
        for (guint i = 0; resolved && i < resolved->len; i++) {
            SZFriendsGtkHostItem *item = g_ptr_array_index(resolved, i);
            g_ptr_array_add(items, szfriends_gtk_host_item_copy(item));
        }
        if (resolved) g_ptr_array_unref(resolved);
    }
    if (verdict_out) *verdict_out = verdict;
    return items;
}

const char *szfriends_gtk_drop_refusal(SZFriendsGtkLink *link, SZFriendsGtkDropVerdict verdict) {
    if (verdict == SZFRIENDS_GTK_DROP_REFUSE_FOLDER) return szfriends_gtk_link_string(link, "drop_folders_refused");
    return verdict == SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE ? szfriends_gtk_link_string(link, "drop_not_a_file") : "";
}

/* Fills only the placeholders PROTOCOL.md § Static strings names, in one pass over the format: what was put in is
 * never read again, so a file named "{count}.pdf" shows as itself. */
static char *fill(const char *format, const char *name, gsize number) {
    char count[32];
    g_snprintf(count, sizeof count, "%" G_GSIZE_FORMAT, number);
    GString *text = g_string_sized_new(strlen(format) + 32);
    for (const char *at = format; *at;) {
        if (g_str_has_prefix(at, "{name}")) {
            g_string_append(text, name ? name : "");
            at += strlen("{name}");
        } else if (g_str_has_prefix(at, "{count}")) {
            g_string_append(text, count);
            at += strlen("{count}");
        } else {
            g_string_append_c(text, *at++);
        }
    }
    return g_string_free(text, FALSE);
}

char *szfriends_gtk_send_picker_title(SZFriendsGtkLink *link, const char *const *names, gsize n_names, gsize count) {
    if (count == 0) return NULL;
    /* Named, so the person sees which files are about to go ("Send Site photos.pdf and 1 more to…"); a helper
     * without those strings gets the count alone, never words the views made up. */
    const char *named = szfriends_gtk_link_string(link, count == 1 ? "drop_send_file" : "drop_send_file_and_more");
    if (names && n_names == count && names[0] && *names[0] && *named) return fill(named, names[0], count - 1);
    const char *counted = szfriends_gtk_link_string(link, count == 1 ? "drop_send_one" : "drop_send_many");
    return *counted ? fill(counted, NULL, count) : NULL;
}

/* ---- Host items ---------------------------------------------------------------------------------- */

SZFriendsGtkHostItem *szfriends_gtk_host_item_new(const char *title, const char *detail, const char *kind_label,
                                                  const char *path, const char *revision_json) {
    SZFriendsGtkHostItem *item = g_new0(SZFriendsGtkHostItem, 1);
    item->title = g_strdup(title ? title : "");
    item->detail = g_strdup(detail ? detail : "");
    item->kind_label = g_strdup(kind_label ? kind_label : "");
    item->path = g_strdup(path);
    item->revision_json = g_strdup(revision_json);
    return item;
}

SZFriendsGtkHostItem *szfriends_gtk_host_item_copy(const SZFriendsGtkHostItem *item) {
    if (!item) return NULL;
    SZFriendsGtkHostItem *copy =
        szfriends_gtk_host_item_new(item->title, item->detail, item->kind_label, item->path, item->revision_json);
    copy->badge = g_strdup(item->badge);
    return copy;
}

void szfriends_gtk_host_item_free(SZFriendsGtkHostItem *item) {
    if (!item) return;
    g_free(item->title);
    g_free(item->detail);
    g_free(item->kind_label);
    g_free(item->path);
    g_free(item->revision_json);
    g_free(item->badge);
    g_free(item);
}
