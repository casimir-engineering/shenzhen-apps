/* spdf_win_settings.h — the reader's preferences, across launches: settings.yaml.
 *
 * THE SAME FILE THE OTHER TWO FRONTENDS WRITE, key for key. The schema is the
 * mac app's (ShenzhenPDFMac.mm:1155-1210 reads it, :1786-1813 writes it) as the
 * GTK4 frontend already transcribed it (portable/linux/gtk4/spdf_state_internal.h:61-95,
 * spdf_state.c parse_settings / settings_to_json), through the same codec
 * (portable/core/spdf_yaml.c) and the same file shell (spdf_win_state.h) the
 * session already uses. THERE IS NO WINDOWS SERIALIZER HERE, exactly as
 * spdf_win_session.h says of itself; what this file adds is the shape of one
 * document -- which keys mean what, their defaults and their clamps -- and it
 * takes every one of them from the two shipping frontends:
 *
 *   fitMode 0..4, zoom, sidebarWidth, minimapWidth,
 *   defaultSidebarVisibleForNewDocuments, defaultMinimapVisibleForNewDocuments,
 *   searchJumpsToNearestResult, preventSleepInPresentation,
 *   printScalingMode 0..2, printCustomScale, printerName, windowSize {width, height},
 *   markdownTheme "light"|"dark", darkThemePreservesImages, commentAuthor.
 *
 * "markdownTheme" IS THE READING THEME FOR EVERY DOCUMENT, and it keeps that
 * name deliberately: SPDFMacReadingThemeIntegration.mm:18 -- "users who had
 * chosen it for Markdown keep their choice". A Windows build that wrote
 * "theme" instead would leave a mac user's dark theme behind on every
 * round trip, so the misnomer is the format.
 *
 * ONE DEPARTURE, AND IT IS ABOUT ABSENCE. The mac app reads a missing
 * markdownTheme as light; a Windows window FOLLOWS THE SYSTEM THEME until told
 * otherwise (spdf_win_system_prefers_dark, from actual use: "it does not respect
 * the system theme"). So the key is tri-state here -- absent means "the
 * system's" and is written back as absent -- and it becomes "light" or "dark"
 * the first time the reader toggles the theme, which is the moment they have
 * expressed a preference. A file the mac app wrote is read exactly as the mac
 * app reads it.
 *
 * WHAT IT REFUSES TO DO, inherited from spdf_win_session.h:
 *
 *   1. It never drops a key it does not model. The mac app's
 *      fullDiskAccessPromptDismissed, permissionsWizardShown,
 *      translate*Language, the GTK app's ocrLanguage and instantLaunchResident
 *      -- all carried through a save byte for byte, so opening a shared
 *      settings.yaml on Windows and quitting re-triggers no mac prompt and
 *      forgets no Linux choice.
 *   2. It never writes over a file it could not read. SPDF_WIN_SETTINGS_UNREADABLE
 *      on load means the defaults are in force for this run and a save writes
 *      NOTHING (spdf_win_state.h's "SILENT FAILURE IF WRONG").
 *
 * PURE HALVES FOR THE TEST. spdf_win_settings_parse_json() and
 * spdf_win_settings_to_json() take and return JSON text with no file behind
 * them, so portable/win/tests/settings_test.c pins the clamps and the
 * carry-through without a state directory; the load/save pair is the file shell
 * around them.
 *
 * FOR THE OTHER TRACKS: spdf_win_settings_shared() is the process-wide copy,
 * loaded on first use. Read a key from it
 * (`spdf_win_settings_shared()->search_jumps_to_nearest_result`); to change
 * one, write the field and call spdf_win_settings_commit().
 */
#ifndef SPDF_WIN_SETTINGS_H
#define SPDF_WIN_SETTINGS_H

#ifdef __cplusplus
extern "C" {
#endif

/* "markdownTheme": absent, "light", "dark". */
typedef enum spdf_win_theme_pref {
    SPDF_WIN_THEME_SYSTEM = 0,
    SPDF_WIN_THEME_LIGHT = 1,
    SPDF_WIN_THEME_DARK = 2
} spdf_win_theme_pref;

/* Clamps, from the two readers. spdf_state_internal.h:61-64 for the widths and
 * the zoom, ShenzhenPDFMac.mm:1187 for the minimap, :1203-1204 for print. */
#define SPDF_WIN_SETTINGS_MIN_ZOOM 0.10
#define SPDF_WIN_SETTINGS_MAX_ZOOM 8.0
#define SPDF_WIN_SETTINGS_MIN_SIDEBAR_W 140
#define SPDF_WIN_SETTINGS_MAX_SIDEBAR_W 560
#define SPDF_WIN_SETTINGS_MIN_MINIMAP_W 72.0
#define SPDF_WIN_SETTINGS_MAX_MINIMAP_W 260.0
#define SPDF_WIN_SETTINGS_DEFAULT_WINDOW_W 1120
#define SPDF_WIN_SETTINGS_DEFAULT_WINDOW_H 800
/* A Windows printer name is at most 220 characters plus a server prefix; 256 is
 * what the spooler's own headers use and what spdf_win_print_dialog.h holds. */
#define SPDF_WIN_SETTINGS_PRINTER_MAX 256

typedef struct spdf_win_settings {
    int fit_mode;                       /* "fitMode" 0..4 (custom/actual/width/height/page) */
    double zoom;                        /* "zoom" 0.10..8.0 */
    int sidebar_width;                  /* "sidebarWidth" 140..560, points */
    double minimap_width;               /* "minimapWidth" 72..260, points */
    int default_sidebar_visible;        /* "defaultSidebarVisibleForNewDocuments" */
    int default_minimap_visible;        /* "defaultMinimapVisibleForNewDocuments" */
    int search_jumps_to_nearest_result; /* "searchJumpsToNearestResult" */
    int prevent_sleep_in_presentation;  /* "preventSleepInPresentation" */
    int print_scaling_mode;             /* "printScalingMode" 0 fit, 1 actual, 2 custom */
    double print_custom_scale;          /* "printCustomScale" 0.10..8.0 */
    /* "printerName": the printer the port's own print dialog opens with, UTF-8.
     * WINDOWS-ONLY, like setupPromptAnswered above, and for the same reason it
     * is safe: a settings.yaml shared with macOS or Linux gains one key those
     * readers carry through and ignore. It exists because the fallback print
     * dialog (spdf_win_print_dialog.h) has to remember a choice Windows' own
     * dialog would have remembered for us. Written only when non-empty, so a
     * reader who has never printed adds nothing to the file. */
    char printer_name[SPDF_WIN_SETTINGS_PRINTER_MAX];
    int window_width;                   /* "windowSize": { "width", "height" }, content points */
    int window_height;
    int theme;                          /* spdf_win_theme_pref, "markdownTheme" */
    int dark_theme_preserves_images;    /* "darkThemePreservesImages" */
    /* "setupPromptAnswered": the first-run question ("Run this copy" /
     * "Install" / "Install and run") has been answered, so it is never asked
     * again. WINDOWS-ONLY, and the Windows analogue of the mac app's own
     * one-shot flags (fullDiskAccessPromptDismissed, permissionsWizardShown),
     * which this file carries through untouched -- so a settings.yaml shared
     * with macOS gains one key those readers will likewise carry through and
     * ignore. Dismissing the dialog with Esc deliberately does NOT set it:
     * "I did not answer" must not be recorded as an answer. */
    int setup_prompt_answered;
    /* "commentAuthor": the author new comments are signed with (mac
     * setCommentAuthor:, GTK spdf_state_internal.h:78). UTF-8; "" means "the
     * account's display name", which is what both apps fall back to. Written
     * always, as both apps write it. */
    char comment_author[256];
} spdf_win_settings;

typedef enum spdf_win_settings_status {
    SPDF_WIN_SETTINGS_LOADED = 0,
    /* No file, or one this build cannot parse: defaults apply and a save is
     * correct and expected. */
    SPDF_WIN_SETTINGS_ABSENT = 1,
    /* A file IS there and could not be read. Defaults apply for this run and
     * MUST NOT be saved over it -- see the header. */
    SPDF_WIN_SETTINGS_UNREADABLE = 2
} spdf_win_settings_status;

/* The defaults every frontend starts from (spdf_state.c settings_init_defaults,
 * ShenzhenPDFMac.mm:561-597, :1153). */
void spdf_win_settings_init_defaults(spdf_win_settings* s);

/* --- the pure halves ------------------------------------------------------ */

/* Apply the keys present in `json` (the compact JSON spdf_json_from_yaml
 * returns) over `s`, clamping as the other readers do. Keys that are absent
 * leave the field alone, so call init_defaults first. Returns the number of
 * recognised keys applied; 0 for NULL or a non-object. */
int spdf_win_settings_parse_json(spdf_win_settings* s, const char* json);

/* The settings as JSON text for spdf_yaml_from_json, malloc'd, caller free()s.
 * `existing_json` may be NULL; when it is the on-disk document, every member
 * of it this file does not own is carried through verbatim. NULL on
 * allocation failure. */
char* spdf_win_settings_to_json(const spdf_win_settings* s, const char* existing_json);

/* --- the file ------------------------------------------------------------- */

/* Fill `s` with defaults, then with whatever settings.yaml holds. */
spdf_win_settings_status spdf_win_settings_load(spdf_win_settings* s);

/* Write settings.yaml, carrying through the keys on disk this file does not
 * model. Returns 1 on success, 0 when nothing was written: the state
 * directory cannot be resolved, the existing file is present but unreadable,
 * or the write failed. A 0 means nothing changed on disk. */
int spdf_win_settings_save(const spdf_win_settings* s);

/* --- the process-wide copy ------------------------------------------------ */

/* Loaded from disk on first call; defaults when there is nothing to load.
 * Never NULL. */
spdf_win_settings* spdf_win_settings_shared(void);

/* How the shared copy loaded, for a caller that must know whether saving is
 * allowed (a caller need not: commit refuses on its own). */
spdf_win_settings_status spdf_win_settings_shared_status(void);

/* Save the shared copy. Same return as spdf_win_settings_save(), and 0 without
 * writing when the load found the file unreadable. */
int spdf_win_settings_commit(void);

/* Tests only: forget the shared copy so the next call reloads. */
void spdf_win_settings_reset_shared(void);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_SETTINGS_H */
