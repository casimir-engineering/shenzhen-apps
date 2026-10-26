/* friends-gtk-conversation-check, widget probes: the conversation page built by the real Friends button and dropdown
 * against the fake helper, driven through its handlers, and rendered offscreen in light and dark. Nothing is mapped
 * on screen: popovers are recorded rather than popped up, and links are recorded rather than opened. */

#ifndef SZFRIENDS_GTK_CONVERSATION_PROBE_H
#define SZFRIENDS_GTK_CONVERSATION_PROBE_H

#include "szfriends_gtk_list_probe_clock.h"
#include "szfriends_gtk_probe.h"
#include "gtk/szfriends_gtk_conversation.h"

/* What the host and the page handed out instead of reaching the system. */
typedef struct {
    GPtrArray *opened;   /* URIs the link menu opened */
    GPtrArray *revealed; /* paths Show in Shenzhen Files revealed */
    GPtrArray *popovers; /* GtkPopover * popped up (weak) */
} SZFGConvRecords;
extern SZFGConvRecords szfg_conv_records;

/* A fake helper speaking `capabilities_json` (NULL: the welcome fixture's), and a link whose host offers `#` items
 * and reveals files into the records. */
SZFGHarness *szfg_conv_harness(const char *label, const char *capabilities_json);

/* The dropdown of a fresh window, open on `conversation_id`, its content laid out at 400 x 640 in a probe window,
 * once the first snapshot has arrived. */
typedef struct {
    SZFGHarness *harness;
    GtkWidget *window, *anchor, *probe_window;
    SZFriendsGtkDropdown *dropdown;
} SZFGConv;
SZFGConv *szfg_conv_open(SZFGHarness *harness, const char *conversation_id);
void szfg_conv_close(SZFGConv *conv);
SZFriendsGtkPage *szfg_conv_page(SZFGConv *conv);
GtkWidget *szfg_conv_content(SZFGConv *conv); /* the dropdown's, every page */
GtkWidget *szfg_conv_root(SZFGConv *conv);    /* the conversation page's own widget */
void szfg_conv_layout(SZFGConv *conv);
void szfg_conv_render(SZFGConv *conv, const char *name);
/* Renders a widget of its own (a card, a menu) at `width` and frees its window. */
void szfg_conv_render_widget(GtkWidget *widget, int width, const char *name);

/* Widgets under `root`: a label whose text starts with `prefix`, a button whose label is `label`. */
GtkWidget *szfg_find_label(GtkWidget *root, const char *prefix);
GtkWidget *szfg_find_button(GtkWidget *root, const char *label);
guint szfg_count_buttons(GtkWidget *root, const char *label);
guint szfg_count_type(GtkWidget *root, GType type);
/* Waits until the fake received one more `type` frame than `before`. */
gboolean szfg_conv_wait_frames(SZFGHarness *harness, const char *type, guint before);
/* A conversation fixture's data with every preview pointing at a PNG written into the harness's cache (or at a
 * missing file there when `missing` names its item). */
char *szfg_conv_data_with_previews(SZFGHarness *harness, const char *fixture, const char *missing);
GValue *szfg_files_value(const char *const *paths);
void szfg_value_free(GValue *value);

void szfg_run_conversation_mention_probes(void);
void szfg_run_conversation_composer_probes(void);
void szfg_run_conversation_transfer_probes(void);
void szfg_run_conversation_look_probes(void); /* szfriends_gtk_conversation_probe_look.c */
void szfg_run_conversation_card_probes(void); /* szfriends_gtk_conversation_probe_cards.c */
void szfg_run_conversation_route_probes(void); /* szfriends_gtk_conversation_probe_routes.c */
void szfg_run_conversation_online_probes(void); /* szfriends_gtk_conversation_probe_online.c */
void szfg_run_conversation_device_probes(void); /* szfriends_gtk_conversation_probe_devices.c */
void szfg_run_conversation_follow_probes(void); /* szfriends_gtk_conversation_probe_follow.c */

#endif /* SZFRIENDS_GTK_CONVERSATION_PROBE_H */
