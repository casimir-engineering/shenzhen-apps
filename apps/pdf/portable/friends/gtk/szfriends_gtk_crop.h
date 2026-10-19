/* Shenzhen Friends GTK views: your own photo, placed under the circle before it becomes your picture (internal to
 * gtk/; mirrors mac/SZFriendsCropView.m).
 *
 * Only the crop square travels (set_picture crop, in the photo's displayed pixels, EXIF orientation applied); the
 * helper decodes, crops and re-encodes the photo itself, so the views never produce image data. The views decode a
 * photo only to show it: on a worker thread, reduced, and only JPEG and PNG within the helper's own input limits
 * (PROTOCOL.md § Limits; avatars/README.md § Photos). Anything else goes to the helper uncropped, so it either takes
 * the centred square or refuses with words written for the person ("This picture is over 5 MB…"). */

#ifndef SZFRIENDS_GTK_CROP_H
#define SZFRIENDS_GTK_CROP_H

#include "gtk/szfriends_gtk_link.h"

G_BEGIN_DECLS

/* ---- Geometry (display-free) ------------------------------------------------------------------------------- */

#define SZFRIENDS_GTK_CROP_MAX_ZOOM 4.0
#define SZFRIENDS_GTK_CROP_VIEWPORT 200 /* the circle's diameter on screen, in pixels */

typedef struct {
    double width, height; /* the photo in displayed pixels */
    double zoom;          /* 1 shows the whole shorter side; at most SZFRIENDS_GTK_CROP_MAX_ZOOM */
    double x, y;          /* the visible square's top-left, in displayed pixels, y down */
} SZFriendsGtkCropGeometry;

/* Centred, zoom 1. */
void szfriends_gtk_crop_init(SZFriendsGtkCropGeometry *crop, double width, double height);
double szfriends_gtk_crop_side(const SZFriendsGtkCropGeometry *crop);
/* Zooms about the visible square's centre, clamped to 1…4 and to the photo. */
void szfriends_gtk_crop_set_zoom(SZFriendsGtkCropGeometry *crop, double zoom);
/* A drag of (dx, dy) screen pixels from a gesture that began with the square at (start_x, start_y): the photo
 * follows the pointer, and the square never leaves the photo. */
void szfriends_gtk_crop_drag(SZFriendsGtkCropGeometry *crop, double start_x, double start_y, double dx, double dy);
/* The square in whole pixels, always inside the photo: what set_picture's crop carries. */
szfriends_crop szfriends_gtk_crop_square(const SZFriendsGtkCropGeometry *crop);

/* set_picture for `path`: with the square when the person placed it, uncropped (NULL geometry) when the views
 * could not show the photo, so the helper takes the centred square or says why it cannot. */
szfriends_intent *szfriends_gtk_crop_intent(const char *path, const SZFriendsGtkCropGeometry *geometry);

/* ---- What the views decode (display-free) -------------------------------------------------------------- */

#define SZFRIENDS_GTK_PHOTO_MAX_BYTES (5 * 1024 * 1024) /* the helper's input limits */
#define SZFRIENDS_GTK_PHOTO_MAX_SIDE 8192

typedef struct {
    gboolean showable;     /* the views may decode it to show the crop step */
    int width, height;     /* displayed pixels (orientation applied once decoded; the header's until then) */
} SZFriendsGtkPhotoCheck;

/* Reads only the file's metadata and header: a regular file (never a link, a pipe or a device), at most 5 MiB,
 * JPEG or PNG, at most 8192 px a side, not a decompression bomb (over 4 megapixels with more than 1,024 pixels per
 * byte, the helper's rule), and for PNG, which decodes at full size, at most 4096 x 4096 so showing it stays cheap. */
SZFriendsGtkPhotoCheck szfriends_gtk_photo_check(const char *path);

/* Decodes a showable photo, reduced to at most 1600 px a side with its EXIF orientation applied, as the crop step
 * shows it; updates `check` to displayed pixels. NULL (and check->showable FALSE) when it cannot. Any thread. */
cairo_surface_t *szfriends_gtk_photo_decode(const char *path, SZFriendsGtkPhotoCheck *check);

/* ---- The crop step ---------------------------------------------------------------------------------------- */

/* `geometry` is the placed square for Use Picture, or NULL when the views cannot show this photo: send it uncropped
 * and let the helper decide (szfriends_gtk_crop_intent). */
typedef void (*SZFriendsGtkCropUse)(const char *path, const SZFriendsGtkCropGeometry *geometry, gpointer data);
typedef void (*SZFriendsGtkCropCancel)(gpointer data);

/* The crop step for `path`: "Loading…" while a worker decodes it, then the photo under the circle with the zoom
 * slider, Cancel and Use Picture. Its strings are welcome.strings crop_title, crop_use, cancel and loading. */
GtkWidget *szfriends_gtk_crop_new(SZFriendsGtkLink *link, const char *path, SZFriendsGtkCropUse use,
                                  SZFriendsGtkCropCancel cancel, gpointer data);
/* For the probes: whether the photo is on screen, and the geometry the buttons would send. */
gboolean szfriends_gtk_crop_is_loaded(GtkWidget *crop);
SZFriendsGtkCropGeometry *szfriends_gtk_crop_geometry(GtkWidget *crop);

G_END_DECLS

#endif /* SZFRIENDS_GTK_CROP_H */
