#pragma once

/* The --help / bad-usage text, and nothing else.
 *
 * Extracted from spdf_win_main.cpp, which sat at its 500-line cap
 * (tools/file-size-limits.md asks for a focused file rather than a raised cap --
 * the same move spdf_win_headless.h, spdf_win_headless_viewport.h,
 * spdf_win_d2d_png.h and spdf_win_chrome_state.h all made). It is a genuine
 * seam despite being one function: this text is the app's command-line
 * CONTRACT, it is what a reader consults when a flag does not behave, and it is
 * the thing most often forgotten when a flag is added.
 *
 * Kept in sync with the parser by being next to nothing else. If you add a flag
 * to spdf_win_main.cpp, it belongs here in the same change.
 */

static int usage(void) {
    fwprintf(stderr,
             L"usage: ShenzhenPDF.exe [--dark|--light] [--page N] [--window ID [--behind] | --new-window]\n"
             L"                       [--state-dir DIR] [file.pdf]\n"
             L"       (no file: restores the last session -- the window last used in front,\n"
             L"        every other window started alongside it -- or opens an empty window;\n"
             L"        --window ID restores one session window, as a sibling launch or a\n"
             L"        hand-over asks; --behind shows it without taking the foreground;\n"
             L"        --new-window restores nothing; --state-dir reads and writes the\n"
             L"        settings and session there instead of %%APPDATA%%\\ShenzhenPDF)\n"
             L"       ShenzhenPDF.exe --render-png [--dark] <file.pdf> <page> <zoom> <out.png>\n"
             L"       ShenzhenPDF.exe --render-window-png [opts] <file.pdf> <page> <w> <h> <out.png>\n"
             L"\n"
             /* The two self-diagnostics. --diagnose is the one line a reader
              * types while a bad window is still on screen, so it is spelled out
              * here rather than hidden in the opts list. */
             L"  When a window misbehaves:\n"
             L"       ShenzhenPDF.exe --diagnose [--state-dir DIR]\n"
             L"           prints one line per live ShenzhenPDF window on this desktop -- foreground,\n"
             L"           enabled, visible, iconic, rect, monitor, on-screen, z-index, hung windows,\n"
             L"           modal state -- then the tail of every launch-health.log it can find, and\n"
             L"           exits 0. Every windowed launch writes that log itself, at 1 s, 5 s and 30 s\n"
             L"           after the window is shown, plus a `stall` line whenever the UI thread's\n"
             L"           heartbeat goes stale. Paste the whole block into the report.\n"
             L"       ShenzhenPDF.exe --print-layout <client_w> <client_h> <dpi_scale> [markdown]\n"
             L"           prints the chrome bands and every toolbar control as `kind name x y w h`\n"
             L"           in client device pixels, from the same layout the painter and the input\n"
             L"           router share. For a test that has to click a real button.\n"
             L"\n"
             /* The exe IS the installer; spdf_win_setup.h says why there is no
              * second binary. Portable use is the default, so this block reads
              * as optional, which is what it is. */
             L"  This exe is a portable app: nothing has to be installed to run it. Optionally,\n"
             L"       ShenzhenPDF.exe --install\n"
             L"           copies itself to %%LOCALAPPDATA%%\\Programs\\ShenzhenPDF, adds a Start Menu\n"
             L"           shortcut and an Apps & features entry, registers as a .pdf handler and\n"
             L"           relaunches. Per-user, HKCU only, no administrator rights. Re-run to repair.\n"
             L"       ShenzhenPDF.exe --uninstall [--quiet] [--purge]\n"
             L"           undoes exactly that. Settings, session and recents in\n"
             L"           %%APPDATA%%\\ShenzhenPDF are KEPT unless --purge; documents are never touched.\n"
             L"       ShenzhenPDF.exe --portable\n"
             L"           keep state in <exe dir>\\ShenzhenPDF-data instead of %%APPDATA%%, as a file\n"
             L"           named ShenzhenPDF.portable next to the exe also does. --state-dir wins.\n"
             L"\n"
             L"  <page> is 0-BASED, matching the core API and spdf_win_probe.\n"
             L"  opts:  --dark            dark reading theme, images preserved\n"
             L"         --light           light theme; both override the system theme a window follows\n"
             L"         --fit MODE        width (default) | height | page | actual\n"
             L"         --zoom Z          device pixels per PDF point; overrides --fit\n"
             L"         --scroll-x X      viewport pixels, added to the top of <page>\n"
             L"         --scroll-y Y\n"
             L"         --dpi S           device pixels per logical pixel (default 1)\n"
             L"         --zoom-at X,Y     zoom about this viewport point after scrolling\n"
             L"         --zoom-factor F   how much to zoom there (default 2)\n"
             L"         --frames N        render N frames, a viewport apart; last is written\n"
             L"         --chrome          compose the tab strip, toolbar, sidebar and minimap too\n"
             L"         --presentation    ... collapsed, as F5 leaves them (with --chrome)\n"
             L"         --find Q          run a search for Q, so the frame shows the find chrome\n"
             L"         --find-regex      treat Q as a regular expression\n");
    return 64;
}
