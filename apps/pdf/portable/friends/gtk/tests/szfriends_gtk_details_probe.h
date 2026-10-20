/* What the details, profile and Settings probes share: a link to the fake helper whose host records what reaches
 * the host, a recorder for what would leave the process (clipboard, dialogs, file chooser, URIs), a dropdown opened
 * through a presenter that shows nothing, and lookups by widget name and label text. */

#ifndef SZFRIENDS_GTK_DETAILS_PROBE_H
#define SZFRIENDS_GTK_DETAILS_PROBE_H

#include "szfriends_gtk_list_probe_clock.h"
#include "szfriends_gtk_probe.h"
#include "gtk/szfriends_gtk_details_page.h"

/* What the pages tried to do outside the views. Answer a recorded confirmation with szfg_outside_answer. */
typedef struct {
    GPtrArray *copied, *revealed, *opened, *uris, *confirms; /* strings; confirms holds the questions' titles */
    GPtrArray *confirm_bodies;                             /* and their bodies, in the same order */
    char *chosen;                                          /* what the file chooser "picks", NULL for Cancel */
    guint chooser_calls;
    char *folder_start;                                    /* where the folder dialog last opened */
    SZFriendsGtkRun run;
    gpointer run_data;
    GDestroyNotify run_destroy;
} SZFGOutside;
extern SZFGOutside szfg_outside;
void szfg_outside_install(void); /* clears the records and replaces the seams for every page */
void szfg_outside_answer(gboolean confirm);
void szfg_outside_uninstall(void);

/* A link to a fresh fake helper, READY, its host recording open and reveal, with the animal set. */
SZFGHarness *szfg_details_harness(const char *label);

/* A window, its Friends button and its dropdown, opened through a presenter that records instead of showing. */
typedef struct {
    GtkWidget *window, *anchor;
    SZFriendsGtkDropdown *dropdown;
} SZFGRig;
SZFGRig *szfg_rig_new(SZFGHarness *harness);
void szfg_rig_free(SZFGRig *rig);
GtkWidget *szfg_rig_page(SZFGRig *rig); /* the top page's widget */
/* Renders the dropdown's content at 400 x height and returns it to the rig. */
void szfg_rig_render(SZFGRig *rig, int height, const char *name);
/* The same, measuring each of the NULL-terminated `labels` in the render (szfg_text_contrast) into `contrasts`. */
void szfg_rig_render_contrast(SZFGRig *rig, int height, const char *name, GtkWidget *const *labels,
                              double *contrasts);
/* The first widget under `root` whose CSS name is `css_name` (an avatar is "szfriends-avatar"). */
GtkWidget *szfg_find_css_name(GtkWidget *root, const char *css_name);
/* Whether `a` and `b` start within a pixel of each other horizontally, in `root`'s coordinates. */
gboolean szfg_same_left(GtkWidget *root, GtkWidget *a, GtkWidget *b);

GtkWidget *szfg_find_named(GtkWidget *root, const char *name);
GtkWidget *szfg_find_label(GtkWidget *root, const char *text);    /* a label showing exactly `text` */
GtkWidget *szfg_find_button(GtkWidget *root, const char *label);  /* a button labelled exactly `label` */
/* A press as the person makes it: the button's own press watcher hears n_press, then the button is clicked. Time is
 * the hand-moved clock's (szfriends_gtk_list_probe_clock.h): advance it to make a second click a separate one. */
void szfg_press(GtkWidget *button, int n_press);
/* WCAG contrast of the text drawn inside `label` against the page under it, from a render of `root` at scale 2:
 * the most distant pixel from the background in the label's box counts as the text's colour. */
double szfg_text_contrast(GdkTexture *render, GtkWidget *root, GtkWidget *label);
void szfg_leave(GtkWidget *button); /* the pointer leaves it */

/* Waits until the fake has received at least `count` frames of `type` (with key = value when key is set). */
gboolean szfg_wait_frames(SZFGHarness *harness, const char *type, const char *key, const char *value, guint count);
/* Serves `data` (a view's data object) to `view`'s subscribers. */
void szfg_script_view(SZFGHarness *harness, const char *view, JsonObject *data);
/* A fixture's data object, to change before scripting. */
JsonObject *szfg_fixture_data(const char *relative);
/* Pumps until `widget` (a label) shows `text`. */
gboolean szfg_wait_label(GtkWidget *root, const char *text);

/* SZFriendsGtkDetailsProbes */
void szfg_run_details_probes(void);
void szfg_run_profile_probes(void);
void szfg_run_settings_probes(void);
void szfg_run_title_probes(void);
void szfg_run_link_probes(void);
void szfg_run_device_probes(void); /* szfriends_gtk_details_probe_devices.c */
/* SZFriendsGtkDetailsTests, without a display */
void szfg_run_details_tests(void);
void szfg_run_qr_tests(void);

#endif /* SZFRIENDS_GTK_DETAILS_PROBE_H */
