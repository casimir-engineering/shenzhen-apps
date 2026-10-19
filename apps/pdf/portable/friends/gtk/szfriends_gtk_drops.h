/* Shenzhen Friends GTK views: what a drag carries, decided once for every drop target (internal to gtk/).
 *
 * The button, rows, the conversation and the composer accept the same things (brief § Interface, drag and drop):
 * files as a GdkFileList (from the host's own views, or Finder through GDK's macOS backend) and the host's own
 * types. Folders, links and special files are refused while dragging, before any intent, with the helper's words
 * (PROTOCOL.md § Intents, files). Display-free: GdkFileList and GIO only. */

#ifndef SZFRIENDS_GTK_DROPS_H
#define SZFRIENDS_GTK_DROPS_H

#include "gtk/szfriends_gtk_link.h"

G_BEGIN_DECLS

typedef enum {
    SZFRIENDS_GTK_DROP_NONE,               /* nothing Friends can send */
    SZFRIENDS_GTK_DROP_ACCEPT,             /* regular files or host items */
    SZFRIENDS_GTK_DROP_REFUSE_FOLDER,      /* at least one folder (or link to one): one bad file sends none */
    SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE   /* no folder, but a link or a FIFO, socket or device the helper refuses */
} SZFriendsGtkDropVerdict;

/* GDK_TYPE_FILE_LIST first, then the host's extra types; free with g_free. */
GType *szfriends_gtk_drop_types(const SZFriendsGtkHost *host, gsize *n_types);
/* For a list of GFile, classified without following links: folders (packages included, and links to folders)
 * refuse, then links to anything else and FIFOs, sockets and devices, which the helper refuses unread; files without
 * a local path cannot be sent, so they make the drop NONE. */
SZFriendsGtkDropVerdict szfriends_gtk_drop_verdict_for_files(GSList *files);
/* Whether `verdict` is one of the refusals: a target shows szfriends_gtk_drop_refusal's words and takes nothing. */
gboolean szfriends_gtk_drop_refused(SZFriendsGtkDropVerdict verdict);
/* For a dropped value: a GdkFileList is classified by its files; a host type counts by its presence alone, since
 * resolving it can be slow (a ShenzhenPDF tab hashes its file) and happens once, on the drop. */
SZFriendsGtkDropVerdict szfriends_gtk_drop_verdict(const SZFriendsGtkHost *host, const GValue *value);
/* The items a drop sends (SZFriendsGtkHostItem *), empty unless the verdict is ACCEPT. */
GPtrArray *szfriends_gtk_drop_items(const SZFriendsGtkHost *host, const GValue *value,
                                    SZFriendsGtkDropVerdict *verdict_out);

/* What a refusing target says while files hover: welcome.strings drop_folders_refused or drop_not_a_file, "" for
 * anything else and while a helper has no such string. */
const char *szfriends_gtk_drop_refusal(SZFriendsGtkLink *link, SZFriendsGtkDropVerdict verdict);
/* "Send 2 files to…": drop_send_file / drop_send_file_and_more with the first name when every file's name is known,
 * drop_send_one / drop_send_many otherwise (PROTOCOL.md § Static strings); NULL when the helper has neither. */
char *szfriends_gtk_send_picker_title(SZFriendsGtkLink *link, const char *const *names, gsize n_names, gsize count);

G_END_DECLS

#endif /* SZFRIENDS_GTK_DROPS_H */
