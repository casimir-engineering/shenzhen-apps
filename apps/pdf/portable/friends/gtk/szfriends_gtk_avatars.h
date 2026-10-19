/* Shenzhen Friends GTK views: the animal set and avatars (internal to gtk/; data mirrors avatars/SZFriendsAnimalSet.m).
 *
 * An animal travels as its set and index and every app draws it from its own copy of the set: the SVGs in
 * Resources/Friends/animals/, each animal already on its circle. A photo is the helper's re-encoded JPEG, read only
 * from directly inside <state>/pictures/, never through a link, bounded in size and decoded off the main thread, as
 * transfer previews are: a snapshot's path is never trusted to name anything else. Whatever cannot be drawn (an index
 * newer than this set, a missing or unreadable file, a placeholder, a photo still loading) is the person's initials
 * in white on the avatar's circle colour, which for an animal is that animal's colour, so the fallback resembles
 * it. */

#ifndef SZFRIENDS_GTK_AVATARS_H
#define SZFRIENDS_GTK_AVATARS_H

#include "gtk/szfriends_gtk_link.h"

G_BEGIN_DECLS

typedef struct _SZFriendsGtkAnimalSet SZFriendsGtkAnimalSet;

/* Reads and validates manifest.json (set version, count, per-index name, colour and contained relative paths).
 * NULL with a developer-facing error for a damaged manifest: a packaging bug, never the person's to fix. */
SZFriendsGtkAnimalSet *szfriends_gtk_animal_set_load(const char *manifest_path, GError **error);
void szfriends_gtk_animal_set_free(SZFriendsGtkAnimalSet *set);
gint64 szfriends_gtk_animal_set_version(const SZFriendsGtkAnimalSet *set);
gsize szfriends_gtk_animal_set_count(const SZFriendsGtkAnimalSet *set);
const char *szfriends_gtk_animal_set_name(const SZFriendsGtkAnimalSet *set, gint64 index);     /* NULL outside */
const char *szfriends_gtk_animal_set_color(const SZFriendsGtkAnimalSet *set, gint64 index);    /* "#rrggbb" */
const char *szfriends_gtk_animal_set_svg_path(const SZFriendsGtkAnimalSet *set, gint64 index); /* absolute */

/* Where the set lives: host->animals_manifest_path, else SZFRIENDS_AVATARS_MANIFEST in builds that honour
 * overrides, else Contents/Resources/Friends/animals/manifest.json of the app around host->helper_path. */
char *szfriends_gtk_animals_manifest_path(const SZFriendsGtkHost *host);
/* The link's set, loaded on first use; NULL when it cannot be read (avatars then draw initials). */
SZFriendsGtkAnimalSet *szfriends_gtk_link_animal_set(SZFriendsGtkLink *link);

typedef enum {
    SZFRIENDS_GTK_AVATAR_DRAW_INITIALS,
    SZFRIENDS_GTK_AVATAR_DRAW_ANIMAL,
    SZFRIENDS_GTK_AVATAR_DRAW_PHOTO
} SZFriendsGtkAvatarDraw;

/* The helper's photo directory, <state>/pictures (avatars/README.md § Photos); NULL without a state directory. */
char *szfriends_gtk_avatar_pictures_dir(void);
/* Whether `path` lies directly in `pictures_dir`: a name inside it, no subfolder, no "." or "..". */
gboolean szfriends_gtk_avatar_photo_allowed(const char *path, const char *pictures_dir);
/* Reads a photo on any thread: allowed by the rule above, opened without following a link or blocking on a FIFO, a
 * regular file of at most 256 KiB whose PNG or JPEG header declares 1 to 1024 pixels a side, decoded to exactly that
 * size. NULL with a developer-facing error otherwise. */
GdkTexture *szfriends_gtk_avatar_photo_load(const char *path, const char *pictures_dir, GError **error);
/* For the suite: the decoded photo the views hold for `path`, NULL while it loads or when it could not be read. */
GdkPaintable *szfriends_gtk_avatar_cached_photo(const char *path);

/* What an avatar draws with this set, and the file it draws from (NULL for initials). A photo counts by its path
 * alone (szfriends_gtk_avatar_photo_allowed); reading it is the view's, off the main thread. */
SZFriendsGtkAvatarDraw szfriends_gtk_avatar_draw_kind(const SZFriendsGtkAvatar *avatar,
                                                      const SZFriendsGtkAnimalSet *set, const char **path);
/* Exactly "#rrggbb", nothing looser: avatar colours come from another person's snapshot fields. */
gboolean szfriends_gtk_parse_hex_color(const char *hex, GdkRGBA *rgba);

/* Draws `avatar` as a `size` circle at the snapshot's origin; initials use `context`'s font (a widget's), or a
 * sans-serif one when NULL. */
void szfriends_gtk_avatar_snapshot(GtkSnapshot *snapshot, const SZFriendsGtkAvatar *avatar,
                                   const SZFriendsGtkAnimalSet *set, double size, PangoContext *context);
/* A widget drawing one avatar at `size` pixels; decorative, since the row's accessible name says who it is. A photo
 * shows once read; until then, and if it cannot be read, the initials. */
GtkWidget *szfriends_gtk_avatar_new(SZFriendsGtkLink *link, int size);
void szfriends_gtk_avatar_set(GtkWidget *avatar_view, const SZFriendsGtkAvatar *avatar);

G_END_DECLS

#endif /* SZFRIENDS_GTK_AVATARS_H */
