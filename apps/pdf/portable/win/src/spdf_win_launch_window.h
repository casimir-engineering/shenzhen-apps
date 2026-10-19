#pragma once

/* spdf_win_launch_window.h -- THE WINDOWED LAUNCH: restore the session, start
 * the sibling windows, open the launch document, create and place the window,
 * show it, run it, and save on the way out.
 *
 * Header-only and included from spdf_win_main.cpp after every glue header,
 * because it calls into all of them (chrome_find_push, app_canvas_viewport,
 * scene_for_window, input_for_window, app_on_watch ...). It is the `else`
 * branch main() used to hold, moved whole when the session-restore work --
 * the saved placement, the siblings, the focused window -- took that file to
 * its 500-line cap; tools/file-size-limits.md asks for an extracted file rather
 * than a raised one, and this is the seam that was already there: main() parses
 * the command line and picks one of three runs, and this is the third. Not
 * part of the port's public surface.
 *
 * `path_arg` is the document named on the command line, or NULL for a bare
 * launch; `behind` is --behind, the sibling's promise not to take the
 * foreground (spdf_win_window_show_ex). Returns the process exit code.
 */

static int run_window(app* a, spdf_win_d2d* d2d, const wchar_t* path_arg, int window_page, int theme_explicit,
                      spdf_win_tabs_app_restore restore, const wchar_t* cli_find_text, int behind) {
    char err[256] = {0};
    int rc = 0;
    /* Whether this was the foreground window when it closed; 0 when it never
     * ran, so a launch that failed before the show stamps nothing. */
    int exit_focused = 0;
    /* The settings, then the theme -- BEFORE the canvas exists, which takes
     * its render flags at construction. Windowed path only; the headless
     * ones must not depend on a file or a registry value. Both points are
     * argued at spdf_win_system_prefers_dark() in spdf_win_window.h. */
    /* AND THE GPU DEVICE, ON A WORKER, FIRST. Nothing between here and the
     * first paint needs it and nothing here needs more than one core, so
     * the driver load overlaps the settings read, the session restore, the
     * document open and CreateWindowExW instead of following them. Windowed
     * path only: see spdf_win_gpu_prewarm.h. */
    spdf_win_gpu_prewarm_start(d2d);
    {
        const spdf_win_settings* settings = spdf_win_settings_shared();
        if (!theme_explicit) a->render_flags = app_initial_render_flags();
        a->show_sidebar = settings->default_sidebar_visible;
        a->show_minimap = settings->default_minimap_visible;
        a->sidebar_w = (float)settings->sidebar_width;
        a->minimap_w = (float)settings->minimap_width;
    }
    /* markdownFontScale, once, before the first Markdown tab is laid out;
     * the headless paths keep the default so a pixel case depends on no
     * file. */
    spdf_win_md_load_settings();

    spdf_win_enable_dark_menus(); /* before any menu exists */

    /* NULL when launched bare: utf8_from_wide(NULL) is NULL, and
     * spdf_win_tabs_app_start(NULL, ...) restores the saved session and
     * selects its tab, or leaves the model empty. */
    char* launch_path = path_arg ? utf8_from_wide(path_arg) : NULL;
    spdf_win_session_frame frame;
    spdf_win_enable_dpi_awareness();
    /* The watcher before the model: the launch document is opened by the
     * show below and its watch is registered by the open hook
     * (spdf_win_tabs_open.h), which needs somewhere to register it. */
    spdf_win_tabs_open_configure(app_on_watch, a);
    spdf_win_tabs_open_start_watching();
    a->tabs = spdf_win_tabs_app_start(launch_path, restore, a->window_id, sizeof(a->window_id), &frame);
    free(launch_path);
    /* THE OTHER WINDOWS, NOW -- the moment the session has named them and
     * before this window's document is even open, so their launches overlap
     * this one and every window reaches the screen together
     * (app_spawn_siblings). A plain launch only: a sibling restores one window
     * and starts none, and a detached or new window has no siblings to start. */
    if (restore == SPDF_WIN_TABS_APP_RESTORE_FIRST) app_spawn_siblings(a);
    /* A NAMED document that will not open is an error the user must see. No
     * document at all is not: the window opens empty, with the chrome drawn
     * and a line saying how to open one (scene_for_window's no-canvas
     * branch), and every canvas call in the frontend tolerates a NULL
     * canvas -- which was checked rather than assumed. The selected tab's own
     * Keep Image Colors goes into the flags first, as every later show does. */
    a->render_flags = app_render_flags_for_selected_tab(a);
    if (!spdf_win_tabs_app_show(a->tabs, &a->canvas, a->render_flags, &a->pending_page) && path_arg &&
        !spdf_win_tabs_open_cancelled()) {
        report(L"That document could not be opened.", true);
        rc = 1;
    } else {
        int client_w, client_h;
        if (window_page > 0) a->pending_page = window_page;
        initial_client_size(&client_w, &client_h);

        spdf_win_window* window = spdf_win_window_create(d2d, NULL, client_w, client_h, scene_for_window,
                                                        input_for_window, a, err, sizeof(err));
        if (!window) {
            wchar_t message[400];
            _snwprintf_s(message, _TRUNCATE, L"Could not create the window: %hs", err);
            report(message, true);
            rc = 72;
        } else {
            /* All of these before the show: no placeholder title, no light
             * caption, and no window that visibly grows a menu bar. */
            a->window = window;
            /* Password prompts from here on are modal to the window. */
            spdf_win_tabs_open_set_owner(spdf_win_window_native_handle(window));
            /* The frame the session remembered, on the display it remembered
             * -- RAW, and parked centred on the main display when that display
             * is not attached, without the parked position ever being saved
             * (spdf_win_placement.h). */
            if (frame.w > 0 && frame.h > 0) {
                spdf_win_placement saved = app_placement_of(&frame);
                spdf_win_window_restore_placement(window, &saved);
            }
            /* The restored tab's view -- fit mode, page, exact offset --
             * placed now against the canvas rect the first paint will use,
             * rather than the page alone on the first paint. */
            a->view_dpi = spdf_win_window_dpi_scale(window);
            app_canvas_viewport(a, (unsigned)(client_w * a->view_dpi), (unsigned)(client_h * a->view_dpi), a->view_dpi,
                                &a->view_w, &a->view_h);
            if (spdf_win_tabs_app_apply_view(a->tabs, a->canvas, a->view_w, a->view_h, a->view_dpi) && window_page <= 0)
                a->pending_page = -1;
            app_restore_find_text(a);
            /* THE COMMAND LINE OUTRANKS THE TAB'S MEMORY. --find is how the
             * capture scripts and a reader with a shortcut ask to open
             * searching for something; app_restore_find_text() above has
             * just replaced the field with the selected tab's remembered
             * query, which a tab opened by this very launch does not have.
             * So it cleared the query and --find did nothing on a windowed
             * launch, while the headless path -- which never restores a
             * session -- kept working, which is why no test caught it.
             * Re-pushed through chrome_find_push() rather than by hand, so
             * the bridge and the Search section agree the way they do for a
             * keystroke. */
            if (cli_find_text[0]) {
                wcsncpy_s(a->find_text, cli_find_text, _TRUNCATE);
                a->find_caret = (int)wcslen(a->find_text);
                chrome_find_push(a);
            }
            sync_window_title(a);
            spdf_win_window_set_tick(window, SPDF_WIN_SESSION_TICK_MS, app_tick);
            /* The deferred sweep of orphaned read-only copies, on its own
             * one-shot rather than on the session tick -- see
             * app_watch_sweep_once() for why thirty seconds was too late. */
            spdf_win_window_set_once(window, SPDF_WIN_WATCH_SWEEP_MS, app_watch_sweep_once);
            /* NO MENU BAR, deliberately: macOS's menus are in the system
             * menu bar, not the window, and a Win32 bar cannot be themed
             * dark. The same menu opens from the toolbar's `...` instead.
             * The full reasoning, and how to put the bar back, is at
             * spdf_win_menu_app_popup() in spdf_win_menu.h. */
            a->menu = NULL;
            spdf_win_window_set_dark_frame(window, (a->render_flags & SPDF_RENDER_DARK_THEME) != 0);
            /* ARMED BEFORE THE FIRST PAINT, WITH A BOUND ON IT -- and this is
             * the one launch that does, which is why it is here and not in
             * show_selected_tab().
             *
             * The launch tab was shown before this window existed, so it missed
             * the arming in show_selected_tab() and used to be armed AFTER the
             * show: the first frame was rendered on this thread come what may,
             * so the window that ShowWindow revealed was always complete. What
             * that costs is that the frame has no end. Measured here: a page of
             * 400,000 stroked paths took 4.5 s and one of 2,000,000 took 35 s,
             * and for all of it there was NO WINDOW OF THIS APP ON SCREEN and
             * the process was IsHungAppWindow-hung -- "the app was never
             * responsive to any user input and not even focusable", exactly
             * (windows-native-observations.md sections 16 and 18).
             *
             * So async goes on FIRST and the first frame gets a budget. Inside
             * it nothing about this launch changes: the same page, rendered
             * once, presented before the same ShowWindow. Past it the window
             * goes up NOW with "Opening…" in the canvas area, enabled,
             * activatable and answering messages, and canvas_render_ready --
             * armed above, which is the whole reason the order moved -- posts
             * the repaint that puts the page in when it lands. */
            spdf_win_canvas_set_async_visible(a->canvas, canvas_render_ready,
                                              (HWND)spdf_win_window_native_handle(window));
            spdf_win_canvas_set_first_frame_budget(a->canvas, SPDF_WIN_CANVAS_FIRST_FRAME_BUDGET_MS);
            /* A sibling shows behind the window the reader left focused; every
             * other launch claims the foreground (spdf_win_window_show_ex). */
            spdf_win_window_show_ex(window, !behind);
            /* THE APP NOW WRITES DOWN WHAT STATE IT CAME UP IN. Three lines
             * into <state dir>\launch-health.log, at 1 s, 5 s and 30 s from
             * here, plus a `stall` line whenever the watchdog finds the UI
             * thread's heartbeat older than three seconds. Right after the show
             * because that is the moment every field of the line becomes
             * meaningful (there is no z-index and no foreground before it), and
             * because a launch nobody is standing over is the only witness to
             * the report this exists for -- spdf_win_health_log.h, and section
             * 13 of portable/docs/windows-native-observations.md. */
            spdf_win_health_log_start(spdf_win_window_native_handle(window));
            /* The fetch of a Markdown document's remote images stays AFTER the
             * show, where the arming used to be: it now has a window for the
             * completion to reach, and nothing about the first frame waits on
             * it. */
            spdf_win_md_command_after_open(a, (HWND)spdf_win_window_native_handle(window));
            /* The taskbar identity (AppUserModelID, the window's icons) and the
             * updater's timers, both after the show: nothing in either runs
             * before first paint (spdf_win_about.h, spdf_win_updater.h). */
            spdf_win_about_apply_identity(spdf_win_window_native_handle(window));
            spdf_win_updater_start_background(spdf_win_window_native_handle(window));
            rc = spdf_win_window_run(window);
            /* What the session and the settings need from the window, read
             * while it still exists: the frame, whether this was the window in
             * front when it closed, and the panel widths. */
            a->exit_frame = app_session_frame(a);
            exit_focused = spdf_win_window_is_foreground(window);
            app_settings_record(a);
            a->window = NULL;
            /* DestroyWindow destroys the menu attached to the window, so
             * there is nothing to free here -- only a pointer that must stop
             * being followed. */
            a->menu = NULL;
            spdf_win_window_destroy(window);
        }
    }
    /* session.yaml, under the shared lock, then close what is still open.
     * The frame and the focus were read before the window went away. */
    spdf_win_tabs_app_finish(a->tabs, a->canvas, a->window_id, &a->exit_frame, exit_focused);
    spdf_win_tabs_open_stop_watching(); /* after the model: no callback can reach a closed tab */
    /* A Markdown re-read the watcher started (spdf_win_md_reload.h) may
     * still be running; its result has no window to land in now. Waiting
     * for it here ends the thread inside MuPDF cleanly rather than under
     * ExitProcess, and closes the document it parked. */
    spdf_win_md_reload_shutdown();
    a->canvas = NULL;                   /* the model closed it; close_document() must not */
    return rc;
}
