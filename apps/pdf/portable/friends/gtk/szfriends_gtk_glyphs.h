/* Shenzhen Friends GTK views: the small vector glyphs the rows, footer and Nearby draw (internal to gtk/).
 *
 * The same 16-unit paths as mac/SZFriendsIcons.m (12 units for the route icons), so both toolkits draw one set: the
 * route icons and the circle with a slash have no equivalent in an icon theme, and a theme the host does not ship
 * would draw nothing. A glyph strokes in its CSS `color`, so styles pick it (@szfriends_local_route, a destructive
 * Block); it is decorative, since the control around it carries the words. Both suites check the route icons
 * against one table of their shapes (tests/szfriends_gtk_route_cells.h). */

#ifndef SZFRIENDS_GTK_GLYPHS_H
#define SZFRIENDS_GTK_GLYPHS_H

#include "gtk/szfriends_gtk_snapshot.h"

#include <gtk/gtk.h>

G_BEGIN_DECLS

typedef enum {
    SZFRIENDS_GTK_GLYPH_NONE,
    SZFRIENDS_GTK_GLYPH_CHECK,   /* Accept, and the confirmed-ID mark */
    SZFRIENDS_GTK_GLYPH_CLOSE,   /* Decline */
    SZFRIENDS_GTK_GLYPH_BLOCK,   /* a circle with a slash: "no entry", never a hand or a stop sign */
    SZFRIENDS_GTK_GLYPH_ROUTE_LAN,       /* waves either side of a dot: nearby, on the same network */
    SZFRIENDS_GTK_GLYPH_ROUTE_P2P_WIFI,  /* two laptops joined by a wave: Wi-Fi straight between the two Macs */
    SZFRIENDS_GTK_GLYPH_ROUTE_BLUETOOTH, /* the Bluetooth rune */
    SZFRIENDS_GTK_GLYPH_ROUTE_INTERNET,  /* a globe: straight to their Mac over the internet */
    SZFRIENDS_GTK_GLYPH_ROUTE_RELAY,     /* a server: through the Friends relay */
    SZFRIENDS_GTK_GLYPH_ROUTE_OFFLINE,   /* a hollow dot with a slash: not reachable now */
    SZFRIENDS_GTK_GLYPH_INFO,
    SZFRIENDS_GTK_GLYPH_COPY,
    SZFRIENDS_GTK_GLYPH_PENCIL,
    SZFRIENDS_GTK_GLYPH_ARC,     /* "still looking": an open ring, not an animated spinner */
    SZFRIENDS_GTK_GLYPH_PAPERCLIP /* Attach files: a paperclip leaning right */
} SZFriendsGtkGlyphKind;

/* The route icon for a PROTOCOL.md route: its `method` when the helper names one, else by `kind` (local: the LAN
 * waves, online: the globe); the globe for connecting (styles draw it in the offline colour), OFFLINE for a route
 * that is down, NONE for kind none or one this view does not know. */
SZFriendsGtkGlyphKind szfriends_gtk_route_glyph(SZFriendsGtkRouteKind kind, SZFriendsGtkRouteMethod method);

/* A `size` px square drawing `kind`; NONE draws nothing. */
GtkWidget *szfriends_gtk_glyph_new(SZFriendsGtkGlyphKind kind, int size);
void szfriends_gtk_glyph_set_kind(GtkWidget *glyph, SZFriendsGtkGlyphKind kind);
SZFriendsGtkGlyphKind szfriends_gtk_glyph_get_kind(GtkWidget *glyph);
void szfriends_gtk_glyph_set_size(GtkWidget *glyph, int size);

G_END_DECLS

#endif /* SZFRIENDS_GTK_GLYPHS_H */
