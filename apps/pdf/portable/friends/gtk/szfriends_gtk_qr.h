/* Shenzhen Friends GTK views: your Friends ID as a QR code (internal to gtk/; mirrors SZFriendsQRView in
 * mac/SZFriendsProfilePage.m, which asks Core Image for one at correction level M).
 *
 * PROTOCOL.md § Views, profile: id.qr_payload is null in M1, and the views then show no QR and no QR button, since
 * nothing can open the code yet. Once the helper sends one (szfriends:add?id=…&key=…) it is drawn here, always
 * dark on white with hard module edges, so a camera reads it in either appearance. GTK has no QR generator, so this
 * is a small ISO/IEC 18004 encoder: byte mode, correction level M, versions 1 to 10 (up to 213 bytes, well over
 * the 85 or so a payload takes). */

#ifndef SZFRIENDS_GTK_QR_H
#define SZFRIENDS_GTK_QR_H

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* Display-free: the modules of `payload`, row-major, 1 for dark, and the side in `size`; NULL when it does not fit
 * version 10. `mask` -1 picks the mask by the standard's penalty rules; 0 to 7 forces one (the suite compares
 * against another encoder's output with its mask). Free with g_free. */
guint8 *szfriends_gtk_qr_encode(const char *payload, int mask, int *size);

GtkWidget *szfriends_gtk_qr_new(void);
/* FALSE, and nothing drawn, when the payload cannot be encoded. */
gboolean szfriends_gtk_qr_set_payload(GtkWidget *qr, const char *payload);
/* Where the code sits: at the end of `beside` (a horizontal box) while small, centred at the end of `below` (a
 * vertical box) while large. Appends it to `beside`. */
void szfriends_gtk_qr_set_slots(GtkWidget *qr, GtkWidget *beside, GtkWidget *below);
/* 92 px beside the ID, or 200 px under it when the person asks for a bigger one to scan, as the AppKit card does. */
void szfriends_gtk_qr_set_large(GtkWidget *qr, gboolean large);

G_END_DECLS

#endif /* SZFRIENDS_GTK_QR_H */
