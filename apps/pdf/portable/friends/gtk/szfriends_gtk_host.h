/* Shenzhen Friends GTK views: the host adapter contract, the C binding of mac/SZFriendsHost.h.
 *
 * Everything the GTK views need from the app that hosts them (Shenzhen Files now, ShenzhenPDF's Linux frontend
 * later) goes through this one struct (brief § Containment and porting, host adapter contract): where each window's
 * button goes, the items `#` offers, drop types beyond files, how a received file is opened or revealed, the hello's
 * identity, and appearance. Called on the main thread unless a member says otherwise.
 *
 * Versioning: the host sets struct_size to sizeof (SZFriendsGtkHost) as it was compiled. Members past that size read
 * as NULL or 0, so a host built against an older header keeps working when members are added at the end. New members
 * only ever go at the end. */

#ifndef SZFRIENDS_GTK_HOST_H
#define SZFRIENDS_GTK_HOST_H

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* One file the host can attach: a `#` entry or one of its own dragged items. Attaching transmits nothing until
 * Send. */
typedef struct {
    char *title;         /* "Site photos.pdf" */
    char *detail;        /* "Selected in Downloads" */
    char *kind_label;    /* "PDF" */
    char *path;          /* readable file holding exactly the bytes meant */
    char *revision_json; /* PROTOCOL.md file.revision as a JSON object, NULL for a plain file */
    char *badge;         /* "Current": a pill beside the title in `#`, for what is open in front (first); NULL: none.
                          * The host sets it (g_strdup) after szfriends_gtk_host_item_new(); the item frees it. */
} SZFriendsGtkHostItem;

SZFriendsGtkHostItem *szfriends_gtk_host_item_new(const char *title, const char *detail, const char *kind_label,
                                                  const char *path, const char *revision_json);
SZFriendsGtkHostItem *szfriends_gtk_host_item_copy(const SZFriendsGtkHostItem *item);
void szfriends_gtk_host_item_free(SZFriendsGtkHostItem *item);

/* `items` holds SZFriendsGtkHostItem pointers, ownership passes to the callee (it frees the array). */
typedef void (*SZFriendsGtkItemsReady)(GPtrArray *items, gpointer ready_data);

typedef struct {
    gsize struct_size; /* sizeof (SZFriendsGtkHost) when the host was compiled */
    gpointer host_data;

    /* hello.client and embedded_helper (PROTOCOL.md § Handshake). Required: app_id, app_name, app_version,
     * reveal_in_name. */
    const char *app_id;         /* "com.intuition.shenzhenfiles" */
    const char *app_name;       /* "Shenzhen Files": strings name the app with it */
    const char *app_version;
    const char *reveal_in_name; /* "Shenzhen Files": received files offer "Show in Shenzhen Files" */
    const char *helper_path;    /* the embedded helper executable; NULL: never spawn (development) */
    const char *helper_version; /* NULL: embedded_helper is null in the hello, so it never wins a handover */
    guint64 helper_build_number; /* the pinned Friends build's number, never the host's own release date */
    const char *const *capabilities; /* NULL-terminated; NULL: derived from the members the host implements */
    const char *const *open_formats; /* NULL-terminated lowercase extensions opened in place; NULL: none */
    const char *attach_placeholder;  /* the `#` field's words, naming what it offers */

    /* Placement, used by szfriends_gtk_link_add_window(): one button per window. */
    void (*install_button)(gpointer host_data, GtkWindow *window, GtkWidget *button);
    void (*remove_button)(gpointer host_data, GtkWindow *window, GtkWidget *button);

    /* `#`: items matching `query`, best first; may call `ready` later, once, on the main thread, unless cancelled. */
    void (*attachable_items)(gpointer host_data, GtkWindow *window, const char *query, GCancellable *cancellable,
                             SZFriendsGtkItemsReady ready, gpointer ready_data);

    /* Drops beyond GdkFileList (ShenzhenPDF Linux: its tab type). NULL in Shenzhen Files. */
    const GType *extra_drop_types;
    gsize n_extra_drop_types;
    GPtrArray *(*items_from_drop)(gpointer host_data, const GValue *value); /* SZFriendsGtkHostItem *, full */
    /* Optional veto: FALSE for a drag the host handles itself, so passing over the button does not open Friends. */
    gboolean (*button_accepts_drop)(gpointer host_data, GdkDrop *drop);

    /* Received files: open in place (formats in open_formats) or reveal in the host's file manager. */
    void (*open_received_file)(gpointer host_data, GtkWindow *window, const char *path);
    void (*reveal_file)(gpointer host_data, GtkWindow *window, const char *path);

    /* Appearance: CSS loaded after the views' own, so it can redefine any @szfriends_* color (szfriends_gtk.css).
     * Metrics in pixels: the button's square side, 0 for the header bar's own button size; the dropdown's width and
     * greatest height, 0 for 400 and 640 (it fits the window below that). */
    const char *appearance_css;
    int title_bar_button_size, dropdown_width, dropdown_max_height;

    /* Optional, NULL in Shenzhen Files; reserved for ShenzhenPDF's Linux frontend and not called yet. */
    GtkWidget *(*render_markdown)(gpointer host_data, const char *markdown, int width);
    gpointer (*assistant)(gpointer host_data);
    void (*services_available)(gpointer host_data, gpointer services);
    void (*services_unavailable)(gpointer host_data);

    /* The animal set's manifest.json; NULL: Contents/Resources/Friends/animals/manifest.json of the app bundle
     * around helper_path, where both apps ship it. */
    const char *animals_manifest_path;

    /* hello.client.url_scheme (PROTOCOL.md § Notifications): the scheme the app registers, without "://"
     * ("shenzhenfiles"), so a notification's click opens <scheme>://friends/conversation/<id> in this app. The host
     * routes those URLs to szfriends_gtk_show_conversation(). NULL: not sent, and clicks open another app. */
    const char *url_scheme;
} SZFriendsGtkHost;

/* The smallest struct_size the views accept: everything up to and including reveal_in_name. */
#define SZFRIENDS_GTK_HOST_MIN_SIZE (offsetof(SZFriendsGtkHost, reveal_in_name) + sizeof(const char *))

G_END_DECLS

#endif /* SZFRIENDS_GTK_HOST_H */
