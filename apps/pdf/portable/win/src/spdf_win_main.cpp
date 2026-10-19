/* ShenzhenPDF for Windows -- entry point.
 *
 *   ShenzhenPDF.exe [--dark|--light] [--page N] [--window ID | --new-window] [--state-dir DIR] [file.pdf]
 *       Opens a window on the continuous scrolling canvas, restoring the last
 *       session (or the window another process handed over as ID, or nothing).
 *
 *   ShenzhenPDF.exe --render-png [--dark] <file.pdf> <page> <zoom> <out.png>
 *       One page through the core, written 1:1 as a PNG. No window, no window
 *       class, nothing touched in user32. This is the byte-for-byte comparison
 *       path against the macOS renderer.
 *
 *   ShenzhenPDF.exe --render-window-png [options] <file.pdf> <page> <w> <h> <out.png>
 *       The WINDOW's viewport -- the continuous canvas, scrolled and zoomed --
 *       composed into a WIC bitmap of the given size and written as a PNG,
 *       with the geometry it used printed to stdout. This is how Phase 2 is
 *       verified: `prlctl exec` runs in the SYSTEM session with no desktop, so
 *       a scrolled frame that could only be produced by a real window would be
 *       a frame no agent could ever check.
 *
 * PAGE NUMBERS ARE 0-BASED EVERYWHERE. Phase 1 took a 1-based page here while
 * spdf_win_probe took a 0-based one, so the two tools disagreed about which
 * page they had rendered -- the quietest possible way for a pixel comparison
 * to compare the wrong pair of images and pass. The core's own API
 * (spdf_page_size, spdf_render_page_rgba_opts) is 0-based, so that is the one
 * that wins; a human-facing 1-based page indicator is a presentation concern
 * for whoever draws one.
 */
#include "spdf_win_canvas.h"
#include "spdf_win_chrome_model.h" /* the chrome model the window paints */
/* The launch-health log the windowed launch arms, and the two switches that
 * read it back: --diagnose (every live window of this app, plus the tail of
 * every log it can find) and --print-layout (where the toolbar's controls are,
 * so a test that sends real input clicks where the router hit-tests). */
#include "spdf_win_diagnose.h"
#include "spdf_win_health_log.h"
#include "spdf_win_layout_print.h"
#include "spdf_win_layout.h" /* SPDF_WIN_PAGE_MARGIN_* for the initial window size */
#include "spdf_win_open_app.h" /* the process opener every by-path open goes through, and its seam */
#include "spdf_win_paths.h"    /* spdf_win_paths_set_state_dir_override, for --state-dir */
#include "spdf_win_settings.h" /* settings.yaml: theme, panels, print, window size */
#include "spdf_win_setup.h"    /* --install / --uninstall / --portable: the exe is its own installer */
#include "spdf_win_tabs_app.h" /* the tab model, the session, and the glue to this canvas */
#include "spdf_win_usage.h"
#include "spdf_win_window.h"

#include <math.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "user32.lib")

/* `struct app`, the one window's state: in its own header since this file reached
 * its cap. Everything below depends on it. */
#include "spdf_win_app.h"

/* utf8_from_wide(), report(), open_document() and close_document(). Depends on
 * `struct app` above; everything below reports through it. */
#include "spdf_win_window_doc.h"

/* The window title, the selected tab with its remembered view, the frame, the
 * periodic session save and the opening size. Depends on `struct app` above
 * and on report(); everything below calls show_selected_tab() from it. */
#include "spdf_win_session_app.h"

/* The watcher's app half: a CHANGED reopens the tab in place, a MISSING marks
 * it, the first tick sweeps orphaned shadow copies. After show_selected_tab. */
#include "spdf_win_watch_app.h"

/* --- the window ---------------------------------------------------------- */

/* scene_for_window() -- the paint-time glue -- and the mouse routing. Both
 * depend on `struct app` and on show_selected_tab() above them, and both stay
 * out of this file because this file is at its 500-line cap and
 * tools/file-size-limits.md asks for an extracted file rather than a raised one.
 * Same arrangement as spdf_win_tabs_app.h and spdf_win_headless_viewport.h.
 *
 * The scene half comes FIRST: the input half calls two of its functions. */
#include "spdf_win_chrome_scene.h"
/* Presentation mode and full screen: what F5 and F11 do, and the pointer while
 * presenting. Before the tab strip's commands, which detach into new windows,
 * and before the router, which hands it the pointer. */
#include "spdf_win_window_presentation.h"
/* The tab strip's own commands -- select, close, open, the overflow menu,
 * drag-to-reorder, tear-off and new windows -- which chrome_perform() next door
 * calls. */
#include "spdf_win_chrome_tabs_ui.h"
/* The strip's hover preview, which the router's hover branch shows. */
#include "spdf_win_tabs_hover.h"
/* What the pointer does over the PAGE: select text, follow a link, or pan. */
#include "spdf_win_chrome_canvas_ui.h"
/* The find group, which field has the keyboard, and the sidebar's rows. */
#include "spdf_win_chrome_field_ui.h"
#include "spdf_win_chrome_actions.h"
/* The Markdown commands -- the A-/A+ text size and the image-cache arrival --
 * in the shape the command switch expects. After the tab strip and the
 * actions, whose show_selected_tab and spdf_win_tabs_app_remember it calls. */
#include "spdf_win_md_commands.h"
/* The keymap, the three typeable fields and the one command switch. LAST,
 * because it calls into all three above it. */
#include "spdf_win_chrome_commands.h"
/* The windowed launch itself -- restore, siblings, create, place, show, run,
 * save -- which calls into everything above, so it comes after all of it. */
#include "spdf_win_launch_window.h"

/* --- headless ------------------------------------------------------------ */

#include "spdf_win_headless_viewport.h"

/* Depends on `app` and spdf_win_d2d above, so it is included here rather
 * than with the headers at the top. */
#include "spdf_win_headless.h"


int main(void) {
    int argc = 0;
    wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return 70;

    /* THE ONE CALL, INSTALLED ONCE (spdf_win_open_app.h): from here on every
     * by-path open in the process -- the headless paths, the tab model, the
     * render workers, search, thumbnails, links, print -- opens a Markdown file
     * as pages, opens a read-only source's working copy when one exists, and
     * opens everything else exactly as before. Before the flag parse, because
     * --render-png and --render-window-png open too. */
    spdf_win_open_set_hook(spdf_win_open_app_document);

    /* THE EXE IS ITS OWN INSTALLER (spdf_win_setup.h), so --install and
     * --uninstall are answered HERE -- before the option loop, before Direct2D,
     * before any settings file is read and long before a window exists. An
     * installer that had already restored the last session would be an
     * installer with a document open. */
    spdf_win_setup_args setup;
    spdf_win_setup_parse(argc, argv, &setup);
    if (setup.install || setup.uninstall) {
        int setup_rc = setup.install ? spdf_win_setup_install(setup.quiet, setup.file, 1)
                                     : spdf_win_setup_uninstall(setup.quiet, setup.purge);
        LocalFree(argv);
        return setup_rc;
    }
    /* Any flag that already states what the reader wants of the install: the
     * first-run question must not second-guess it. --state-dir is in the list
     * for a reason that is not cosmetic -- screenshot-window.ps1, and so
     * verify-phase1.ps1 through it, launches a real window with a fresh temp
     * state directory, which would otherwise read as "never asked" and hang it
     * on a modal dialog. (measure-launch.ps1 and drive-window.ps1 cannot use
     * --state-dir and set SPDF_WIN_SETUP_NO_PROMPT instead; spdf_win_setup.h
     * says why, and spdf_win_setup_first_run() folds it in here.) */
    const int setup_explicit = setup.install || setup.uninstall || setup.quiet || setup.purge || setup.portable ||
                               (setup.state_dir && !spdf_win_setup_prompt_allowed_by_env());
    /* Portable mode, before anything reads state: the marker file next to the
     * exe (or --portable) moves settings.yaml and session.yaml to
     * <exe dir>\ShenzhenPDF-data. A no-op when --state-dir was given, whose own
     * override the loop below installs and which therefore keeps precedence. */
    spdf_win_setup_apply_portable(setup.portable, setup.state_dir);

    app a;
    /* What --find asked for, kept apart from a.find_text because the session
     * restore below overwrites that from the tab. See its use further down. */
    wchar_t cli_find_text[256];
    viewport_opts opts;
    int window_page = 0;
    /* Set by --dark or --light. Until one of them appears the theme is the
     * SYSTEM's, resolved below -- but only for the windowed path. */
    int theme_explicit = 0;
    /* --window / --new-window: how the windowed path finds its tabs. */
    spdf_win_tabs_app_restore restore = SPDF_WIN_TABS_APP_RESTORE_FIRST;
    /* --behind: a sibling of a session-restore launch, shown without taking
     * the foreground from the window the reader left focused. */
    int behind = 0;
    memset(&a, 0, sizeof(a));
    memset(&opts, 0, sizeof(opts));
    a.render_flags = SPDF_RENDER_DEFAULT;
    /* Both side panels open, as macOS does for a new document
     * (ShenzhenPDFMac.mm:836-840). 0 width asks spdf_win_chrome.h for
     * its default. */
    a.show_sidebar = 1;
    a.show_minimap = 1;
    /* -1, not the 0 the memset left: 0 is a valid tab index, so a zeroed hover
     * state would draw the first tab hovered before the pointer has ever
     * entered the window. */
    a.hot_tab = -1;
    a.hot_close = -1;
    /* -1 for the same reason: 0 is a valid tab index and a valid drop slot, so a
     * zeroed drag state is a drag nobody started. */
    a.drag_tab = -1;
    a.drop_slot = -1;
    opts.mode = SPDF_WIN_ZOOM_FIT_WIDTH;
    opts.dpi_scale = 1.0f;
    opts.zoom_at_x = -1.0f;
    opts.zoom_factor = 2.0f;
    opts.frames = 1;

    int i = 1;
    bool exact = i < argc && wcscmp(argv[i], L"--render-png") == 0;
    bool viewport = i < argc && wcscmp(argv[i], L"--render-window-png") == 0;
    /* Leading, like the two above, because it takes positional arguments of its
     * own and answers before there is a document, a device or a window
     * (spdf_win_layout_print.h). */
    bool layout = i < argc && wcscmp(argv[i], L"--print-layout") == 0;
    /* Valueless and position-free, because the moment it is needed is a moment
     * nobody wants to look up an argument order for (spdf_win_diagnose.h). */
    int diagnose = 0;
    if (exact || viewport || layout) ++i;

    for (; i < argc && argv[i][0] == L'-'; ++i) {
        const wchar_t* flag = argv[i];
        const wchar_t* value = i + 1 < argc ? argv[i + 1] : NULL;
        if (wcscmp(flag, L"--dark") == 0) {
            a.render_flags |= SPDF_RENDER_DARK_THEME | SPDF_RENDER_PRESERVE_IMAGES;
            theme_explicit = 1;
            continue;
        }
        /* The counterpart, so a dark machine can still be told to open light and
         * a pixel case can pin either. */
        if (wcscmp(flag, L"--light") == 0) {
            a.render_flags &= ~(unsigned)(SPDF_RENDER_DARK_THEME | SPDF_RENDER_PRESERVE_IMAGES);
            theme_explicit = 1;
            continue;
        }
        /* Valueless, like --dark. Composes the window chrome into the headless
         * frame, so the whole window's pixels can be compared without a desktop. */
        if (wcscmp(flag, L"--chrome") == 0) {
            opts.chrome = 1;
            continue;
        }
        /* Valueless. Acted on right after this loop, so --state-dir (which may
         * come on either side of it) has already installed its override and the
         * log dumped is the one that launch belongs to. */
        if (wcscmp(flag, L"--diagnose") == 0) {
            diagnose = 1;
            continue;
        }
        /* Valueless, like --chrome; pairs with --find below. */
        if (wcscmp(flag, L"--find-regex") == 0) {
            a.find_regex = 1;
            continue;
        }
        /* A fresh empty window with its own session id: what File > New Window
         * spawns. Restores nothing. */
        if (wcscmp(flag, L"--new-window") == 0) {
            restore = SPDF_WIN_TABS_APP_RESTORE_NONE;
            continue;
        }
        /* Valueless. Passed by app_spawn_siblings() with --window: show behind. */
        if (wcscmp(flag, L"--behind") == 0) {
            behind = 1;
            continue;
        }
        /* Already acted on above, before any state was read; accepted here so
         * `--portable file.pdf` is not a usage error. */
        if (wcscmp(flag, L"--portable") == 0) continue;
        /* The chrome collapsed, as F5 leaves it, so the headless compose can
         * show the presentation frame with no desktop. */
        if (wcscmp(flag, L"--presentation") == 0) {
            spdf_win_chrome_presentation_set(1);
            a.presentation = 1;
            continue;
        }
        if (!value) return usage();
        /* The window another process handed over through session.yaml
         * (spdf_win_session_detach_tab): restore exactly that one. */
        if (wcscmp(flag, L"--window") == 0) {
            if (WideCharToMultiByte(CP_UTF8, 0, value, -1, a.window_id, (int)sizeof(a.window_id), NULL, NULL) <= 0)
                return usage();
            restore = SPDF_WIN_TABS_APP_RESTORE_ID;
            ++i;
            continue;
        }
        /* Where settings.yaml and session.yaml live, instead of %APPDATA%: the
         * explicit portable-mode switch spdf_win_paths.h reserves for the
         * frontend, and what lets a test drive a real window without touching
         * the reader's own state. Inherited by every window this one spawns. */
        if (wcscmp(flag, L"--state-dir") == 0) {
            char* dir = utf8_from_wide(value);
            if (!dir) return usage();
            spdf_win_paths_set_state_dir_override(dir);
            free(dir);
            wcsncpy_s(a.state_dir, value, _TRUNCATE);
            ++i;
            continue;
        }
        /* THE HEADLESS ROUTE TO A LIVE SEARCH, and the reason it exists.
         *
         * SPDF_FIND_QUERY used to be the only way to see the find chrome in a
         * frame, and this change deletes it -- the field is typeable now, and a
         * debugging hook that bypasses the real control is a hook that keeps
         * working after the real control has broken. But the session on this
         * machine can be locked, and then `--render-window-png --chrome` is the
         * ONLY way anyone can look at the window at all, so deleting the bridge
         * without replacing it would take the find chrome out of the one
         * verification path this port has.
         *
         * So it is a FLAG rather than an environment variable, and it goes
         * through spdf_win_find_set_query() -- the same function a keystroke
         * calls, on the same buffer, with the same conversion. It exercises the
         * real path instead of going round it. */
        if (wcscmp(flag, L"--find") == 0) wcsncpy_s(a.find_text, value, _TRUNCATE);
        else if (wcscmp(flag, L"--page") == 0) window_page = _wtoi(value);
        else if (wcscmp(flag, L"--zoom") == 0) opts.zoom = (float)_wtof(value);
        else if (wcscmp(flag, L"--scroll-x") == 0) opts.scroll_x = (float)_wtof(value);
        else if (wcscmp(flag, L"--scroll-y") == 0) opts.scroll_y = (float)_wtof(value);
        else if (wcscmp(flag, L"--dpi") == 0) opts.dpi_scale = (float)_wtof(value);
        else if (wcscmp(flag, L"--zoom-factor") == 0) opts.zoom_factor = (float)_wtof(value);
        else if (wcscmp(flag, L"--frames") == 0) opts.frames = _wtoi(value);
        else if (wcscmp(flag, L"--sidebar-section") == 0) opts.sidebar_section = _wtoi(value);
        else if (wcscmp(flag, L"--zoom-at") == 0) {
            wchar_t* comma = NULL;
            opts.zoom_at_x = (float)wcstod(value, &comma);
            opts.zoom_at_y = comma && *comma == L',' ? (float)wcstod(comma + 1, NULL) : 0.0f;
        } else if (wcscmp(flag, L"--fit") == 0) {
            if (wcscmp(value, L"width") == 0) opts.mode = SPDF_WIN_ZOOM_FIT_WIDTH;
            else if (wcscmp(value, L"height") == 0) opts.mode = SPDF_WIN_ZOOM_FIT_HEIGHT;
            else if (wcscmp(value, L"page") == 0) opts.mode = SPDF_WIN_ZOOM_FIT_PAGE;
            else if (wcscmp(value, L"actual") == 0) opts.mode = SPDF_WIN_ZOOM_ACTUAL;
            else return usage();
        } else {
            return usage();
        }
        ++i; /* consumed the value */
    }

    /* THE TWO DIAGNOSTICS ANSWER HERE: after the parse, so --state-dir has been
     * honoured, and before the first-run question, the Direct2D device and any
     * state file is touched. Neither opens a document, and neither may ever
     * become a reason the app fails to start. */
    if (diagnose) {
        int diagnose_rc = run_diagnose();
        LocalFree(argv);
        return diagnose_rc;
    }
    if (layout) {
        if (argc - i < 3 || argc - i > 4) return usage();
        int layout_rc = run_print_layout((unsigned)_wtoi(argv[i]), (unsigned)_wtoi(argv[i + 1]),
                                         (float)_wtof(argv[i + 2]), argc - i == 4 ? _wtoi(argv[i + 3]) : 0);
        LocalFree(argv);
        return layout_rc;
    }

    /* After the whole parse, so --find-regex may come on either side of --find.
     * A no-op with no query: spdf_win_find_set_query(NULL) creates no session. */
    a.find_caret = (int)wcslen(a.find_text);
    wcsncpy_s(cli_find_text, a.find_text, _TRUNCATE);
    chrome_find_push(&a);

    int remaining = argc - i;
    /* The windowed path takes AT MOST one document, and may take none: a bare
     * launch restores the session, or opens an empty window that File > Open,
     * the strip's `+` and a dropped file can all fill. That is macOS's launch
     * behaviour, and it is what a double-click on the exe has to do -- until now
     * that printed this usage text and exited 64, so the app could only ever be
     * started from a command line that named a file. */
    if ((exact && remaining != 4) || (viewport && remaining != 5) || (!exact && !viewport && remaining > 1))
        return usage();

    /* THE FIRST-RUN QUESTION -- "Run this copy", "Install", or "Install and run
     * the installed app" (spdf_win_setup.h). AFTER the usage check above, so a
     * bad command line still exits 64 without a dialog in front of it, and
     * BEFORE the Direct2D device and the GPU prewarm below, so a launch that is
     * about to install nothing does not load a driver first. It declines to ask
     * on its own for the headless paths and for every explicit flag; when it
     * does ask and the answer was Install, the install has already happened and
     * this process is finished. */
    {
        int first_rc = 0;
        int first_action = spdf_win_setup_first_run(setup_explicit, exact || viewport,
                                                   remaining ? argv[i] : NULL, &first_rc);
        if (spdf_win_setup_action_exits(first_action)) {
            LocalFree(argv);
            return first_rc;
        }
    }

    char err[256] = {0};
    spdf_win_d2d* d2d = spdf_win_d2d_create(err, sizeof(err));
    if (!d2d) {
        wchar_t message[400];
        _snwprintf_s(message, _TRUNCATE, L"Direct2D is unavailable: %hs", err[0] ? err : "unknown error");
        report(message, !exact && !viewport);
        return 71;
    }

    int rc;
    if (exact) {
        float zoom = (float)_wtof(argv[i + 2]);
        if (!(zoom > 0.0f)) zoom = 1.0f;
        rc = run_exact(&a, d2d, argv[i], _wtoi(argv[i + 1]), zoom, argv[i + 3]);
    } else if (viewport) {
        rc = run_viewport(&a, d2d, argv[i], _wtoi(argv[i + 1]), (unsigned)_wtoi(argv[i + 2]),
                          (unsigned)_wtoi(argv[i + 3]), &opts, argv[i + 4]);
    } else {
        /* The window: spdf_win_launch_window.h, whole. */
        rc = run_window(&a, d2d, remaining ? argv[i] : NULL, window_page, theme_explicit, restore, cli_find_text,
                        behind);
    }

    close_document(&a);
    spdf_win_d2d_destroy(d2d);
    LocalFree(argv);
    return rc;
}
