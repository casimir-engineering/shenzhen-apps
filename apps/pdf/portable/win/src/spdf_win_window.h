/* The Win32 shell around spdf_win_paint().
 *
 * This layer is deliberately thin and deliberately DOWNSTREAM of the compose
 * layer. It owns an HWND, an ID2D1HwndRenderTarget and a message pump, and
 * the only thing it does with them is hand the render target to
 * spdf_win_paint(). Nothing about how a page is drawn lives here, which is
 * what keeps the headless probe drawing the same pixels as the window.
 *
 * It also knows nothing about documents. What to draw arrives through a
 * callback the caller supplies, so spdf_win_main.cpp owns the document and
 * this file owns the window, and neither includes the other's header.
 */
#ifndef SPDF_WIN_WINDOW_H
#define SPDF_WIN_WINDOW_H

#include "spdf_win_d2d.h"
/* For spdf_win_chrome_button and spdf_win_chrome_cursor, which the mouse events
 * below carry. Taking them from there rather than declaring a parallel pair here
 * is deliberate: two enums with the same meaning and independent numbering is
 * how a middle click becomes a left click at a layer boundary. It costs nothing
 * -- that header is pure, toolkit-free and header-only -- and it does not make
 * this file know about documents, which is the layering rule it actually has. */
#include "spdf_win_chrome_input.h"
/* The placement struct and its rules: pure, toolkit-free, tested on their own. */
#include "spdf_win_placement.h"

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_WINDOW_INLINE __inline
#else
#define SPDF_WIN_WINDOW_INLINE inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spdf_win_window spdf_win_window;

/* Called on the UI thread immediately before each paint, with the client area
 * in device pixels and the window's current DPI scale. Fill `scene` and
 * return non-zero; return 0 to paint an empty window. `scene` arrives zeroed
 * except for target_px_w/h and dpi_scale, which are already set and must not
 * be changed.
 *
 * Phase 1 renders synchronously inside this callback. That is a deliberate
 * limitation, not an oversight: it keeps Phase 1 free of any dependency on
 * the worker pool (T5) or the layout header (T3). The moment those land, this
 * callback becomes a lookup in the render cache instead. */
typedef int (*spdf_win_scene_fn)(void* user, spdf_win_scene* scene);

/* Input, reduced to the three things a document canvas actually reacts to.
 *
 * The window translates Win32 messages into these and knows nothing else; the
 * caller maps them onto the canvas and knows no Win32. That split is what lets
 * the headless viewport probe drive the same canvas with the same numbers and
 * get the same pixels -- if wheel handling lived next to the scroll offset,
 * there would be no way to reproduce a scrolled frame without a desktop. */
typedef enum spdf_win_input_kind {
    /* dx/dy in device pixels, in CONTENT direction: positive dy means the
     * document moves up, i.e. the reader goes further down the document. */
    SPDF_WIN_INPUT_SCROLL = 0,
    /* Multiply the zoom by `factor`, keeping whatever is under (x, y) put. */
    SPDF_WIN_INPUT_ZOOM = 1,
    /* A raw VK_* in `key`. The caller owns the keymap: which key means
     * "next page" is product policy, not window plumbing. */
    SPDF_WIN_INPUT_KEY = 2,

    /* THE MOUSE, RAW. `button` says which, `x`/`y` where, in CLIENT device
     * pixels -- the space every rect in SpdfWinChromeLayout lives in.
     *
     * These deliberately do NOT say "pan". Drag-to-pan used to be resolved
     * inside this file, which was correct while the whole client area was
     * canvas; it is not correct now that the top 84 pt of it is chrome, because
     * "does this drag pan the document" became a question about where the
     * pointer is, and where anything is is the caller's knowledge. So the window
     * holds the CAPTURE and the caller holds the MEANING -- the same split this
     * file already states for the keymap, one device over. The caller is
     * expected to route these through spdf_win_chrome_input.h.
     *
     * MOUSE_MOVE is sent whether or not a button is down, because hover state is
     * what lights the tab strip's close boxes. A handler that changes nothing
     * must return 0, or every pixel of pointer travel costs a repaint. */
    SPDF_WIN_INPUT_MOUSE_DOWN = 3,
    SPDF_WIN_INPUT_MOUSE_UP = 4,
    SPDF_WIN_INPUT_MOUSE_MOVE = 5,

    /* A MENU ITEM (or an accelerator the caller resolved to one) was chosen.
     * `key` carries the command, already stripped of SPDF_WIN_MENU_ID_BASE. The
     * window does not know what any of them mean -- exactly as it does not know
     * what a key means -- it only knows that WM_COMMAND's low word is a command
     * id and that spdf_win_main.cpp owns the map. */
    SPDF_WIN_INPUT_COMMAND = 7,

    /* One UTF-16 code unit the user TYPED, from WM_CHAR, in `key`. Separate from
     * SPDF_WIN_INPUT_KEY because the two answer different questions: a VK is a
     * key on the keyboard, a WM_CHAR is a character produced by the layout, the
     * dead keys and the IME. Typing "ü" is one WM_CHAR and no VK anybody could
     * name, and typing on a French layout produces different characters from the
     * same VKs -- so a text field that read VKs would work only on the layout it
     * was written on. Control characters below space arrive here too (Windows
     * sends WM_CHAR for Backspace, Tab, Return and Escape); a handler ignores
     * them and acts on the VK instead, which is where the caret keys are anyway.
     *
     * SURROGATE PAIRS arrive as two events. A handler that stores what it
     * receives is correct; one that inspects individual code units is not. */
    SPDF_WIN_INPUT_CHAR = 8,

    /* A file was dropped on the window. `text` is its path, valid only for the
     * duration of the call. One event per file, in the order Windows reports
     * them, so a caller that opens each in a new tab needs no array. */
    SPDF_WIN_INPUT_DROP_FILE = 9,

    /* A MESSAGE IN THE WM_APP RANGE, posted to the window by a worker of the
     * app's -- the Markdown image fetch, say -- with the message number in
     * `key`. The window knows no message in that range and never will: which
     * numbers mean what is the app's, exactly as the command ids are, so
     * every WM_APP..0xBFFF message is handed over rather than dropped on the
     * floor by DefWindowProc. wParam and lParam are not carried; a worker
     * that has more to say than "done" keeps it where the handler can read it.
     * THAT RANGE IS ALSO A LIMIT: three messages were WM_APP plus a two-letter
     * mnemonic ("RD" = 0x5244 -> 0xD244), above 0xBFFF, so all three were
     * posted, dropped here and silently dead (observations sec 18). Declare a
     * number with SPDF_WIN_APP_MSG_OK below and the build says so instead. */
    SPDF_WIN_INPUT_APP_MESSAGE = 11, /* 10 is SPDF_WIN_INPUT_CONTEXT, declared below */

    /* THE POSITION QUERY: what is at (x, y)? Sent for WM_SETCURSOR, asking
     * which cursor belongs there, and for WM_NCHITTEST, asking whether the point
     * is the app's or the window manager's. The handler writes `cursor` and `nc`
     * and MUST return 0: both queries happen on every pointer move and must
     * never invalidate. A separate event rather than a value cached from the
     * last MOUSE_MOVE because Windows sends WM_SETCURSOR BEFORE WM_MOUSEMOVE, so
     * a cache would always answer for the previous position -- visible as a
     * resize cursor that lags a pixel behind a divider's edge. One event for
     * both questions because they are the same question -- "what is here" --
     * answered by the same routing, and a second kind would be a second switch
     * arm in the caller for no second decision. */
    SPDF_WIN_INPUT_CURSOR = 6,

    /* THE RIGHT BUTTON, as its own event rather than as a fourth
     * spdf_win_chrome_button: that enum belongs to the chrome router, which
     * routes no right clicks -- nothing in the chrome has a context menu -- and
     * the one thing this app does with the right button is turn the page BACK
     * in presentation mode (SPDFMacPresentationIntegration.mm:22, "right mouse
     * down returns -1"). `x`/`y` are client device pixels like every other mouse
     * event. Sent on the press; there is no matching release, because nothing
     * drags with this button. A handler that does not care returns 0. */
    SPDF_WIN_INPUT_CONTEXT = 10
} spdf_win_input_kind;

/* Put this beside an app message's #define: a number outside WM_APP..0xBFFF
 * makes the array size negative and the build stops, which is the only kind of
 * check that survives a mnemonic that looked fine. */
#define SPDF_WIN_APP_MSG_OK(name, msg) typedef char name[((msg) >= WM_APP && (msg) < 0xC000) ? 1 : -1]

/* A button-up whose `button` is SPDF_WIN_CB_NONE is a CANCELLED drag, not a
 * release: the capture was taken away (an Alt+Tab, a system modal), and a
 * handler that treats it as a release would finish a gesture the user abandoned.
 * The old code had the same hazard and solved it the same way -- see
 * WM_CAPTURECHANGED in spdf_win_window.cpp. */

/* These three bits are spdf_win_menu.h's SPDF_WIN_ACCEL_* bits, deliberately the
 * same numbers: an input's `mods` is handed straight to
 * spdf_win_menu_command_for_key() with no conversion, and two spellings of the
 * same three flags is one translation function away from a Shift that means
 * Ctrl. */
#define SPDF_WIN_MOD_CTRL 0x1u
#define SPDF_WIN_MOD_SHIFT 0x2u
#define SPDF_WIN_MOD_ALT 0x4u

typedef struct spdf_win_input {
    spdf_win_input_kind kind;
    float dx;
    float dy;
    float factor;
    float x; /* pointer position in client device pixels */
    float y;
    unsigned key;
    unsigned mods;
    /* SPDF_WIN_INPUT_KEY only: THE SAME KEY, AS THE ACTIVE LAYOUT SPELLS IT.
     *
     * `key` is a virtual-key code, and a virtual-key code is a property of the
     * LAYOUT rather than of the keyboard: VK_OEM_MINUS is on no French key at
     * all (MapVirtualKeyExW maps it to scan code 0 under 0000040C), so a keymap
     * that names it has no '-' on a French machine. This is the character the
     * key produces with no modifiers, uppercased for letters, or 0 when it
     * produces none (a function key, an arrow, a dead key) -- which is what
     * makes an accelerator layout-independent, exactly as the macOS original's
     * character keyEquivalents are. See spdf_win_menu_layout.h.
     *
     * Both are carried, not one: a command keyed to a POSITION (the arrows,
     * Page Up, F11) wants the virtual-key code, and a command keyed to a GLYPH
     * ('-', ',') wants the character. */
    unsigned key_char;
    /* SPDF_WIN_INPUT_KEY only: this keystroke is TEXT -- the layout turned it
     * into a printable character, which TranslateMessage has already queued as
     * a WM_CHAR behind this WM_KEYDOWN.
     *
     * It exists for AltGr. On every European layout AltGr is reported as
     * Ctrl+Alt, so AltGr+'=' (a French '}') is indistinguishable from a
     * deliberate Ctrl+Alt+= accelerator by modifiers alone. The keystroke that
     * produces a character is the one that is text. Only the Ctrl+Alt
     * accelerators consult this; Ctrl+letter produces a WM_CHAR too -- a control
     * character -- and gating on it would kill the whole table. */
    int text_key;
    /* SPDF_WIN_INPUT_DROP_FILE only: the dropped path, UTF-16, BORROWED and
     * valid only for the duration of the call. */
    const wchar_t* text;
    /* Which mouse button, as spdf_win_chrome_button. Mouse events only. */
    int button;
    /* THE ACCUMULATED CLICK COUNT for a multi-click series: 1, 2, 3, ...
     * MOUSE_DOWN only, and 0 on every other event.
     *
     * Accumulated HERE rather than by the caller because Win32 does not
     * accumulate it and the pieces needed to are all Win32: WM_LBUTTONDBLCLK is
     * the SECOND click of a double, a triple is an ordinary WM_LBUTTONDOWN
     * arriving within GetDoubleClickTime() and SM_CXDOUBLECLK of it, and the
     * timestamp that decides "within" is GetMessageTime(), not a clock the caller
     * has. What a count MEANS -- two selects a word, three selects a block -- is
     * still entirely the caller's, which is the same division this file already
     * states for the keymap. */
    unsigned click_count;
    /* Client area in device pixels at the moment of the event, so a handler
     * can express a page-sized scroll without asking the window anything.
     *
     * NOTE that this is the CLIENT area, not the canvas: the canvas is a
     * sub-rect of it now. A handler that wants the canvas divides the client
     * area with spdf_win_chrome_layout(), the same function the painter uses --
     * which is why dpi_scale is here too. */
    unsigned view_px_w;
    unsigned view_px_h;
    /* Device pixels per logical pixel, so a handler can lay the chrome out the
     * same way the painter did and hit-test against the rects that were actually
     * drawn. Without it a handler would have to guess, and a guessed DPI puts
     * every chrome edge in the wrong place at 150%. */
    float dpi_scale;

    /* --- written by the HANDLER, read by the window ---------------------- */
    /* SPDF_WIN_INPUT_CURSOR only: which cursor belongs at (x, y), as
     * spdf_win_chrome_cursor. Pre-set to SPDF_WIN_CC_ARROW, so a handler that
     * does not care leaves it alone. */
    int cursor;
    /* SPDF_WIN_INPUT_CURSOR only: the window manager's view of (x, y), as
     * spdf_win_chrome_nc. Pre-set to SPDF_WIN_NC_CLIENT, so a handler that does
     * not care leaves every pixel the app's -- which is exactly the pre-caption
     * behaviour. WM_NCHITTEST turns it into HTCAPTION / HTMINBUTTON /
     * HTMAXBUTTON / HTCLOSE / HTCLIENT; see spdf_win_window_caption.h. */
    int nc;
} spdf_win_input;

/* Return non-zero when the view changed and needs repainting. Returning 0 for
 * a key the caller does not handle is what keeps unhandled keys from costing a
 * full repaint -- and for SPDF_WIN_INPUT_MOUSE_MOVE and _CURSOR, which arrive
 * on every pixel of pointer travel, it is what keeps the pointer from repainting
 * the window continuously.
 *
 * NON-CONST because the mouse and cursor events carry an answer back (see
 * `cursor` above). Nothing else in the struct may be modified. */
typedef int (*spdf_win_input_fn)(void* user, spdf_win_input* input);

/* Process-wide; call once before creating a window. Asks for per-monitor v2
 * DPI awareness and degrades silently on a Windows too old to offer it. */
void spdf_win_enable_dpi_awareness(void);

/* client_px_w/h are the desired CLIENT area in device pixels at the window's
 * initial DPI. Returns NULL and fills err on failure. */
spdf_win_window* spdf_win_window_create(spdf_win_d2d* d2d, const wchar_t* title, int client_px_w, int client_px_h,
                                        spdf_win_scene_fn scene_fn, spdf_win_input_fn input_fn, void* user, char* err,
                                        size_t err_len);
void spdf_win_window_destroy(spdf_win_window* window);

/* Paint the first frame, show the window and claim the foreground. The
 * sibling windows a session-restore launch starts show BEHIND the one the
 * reader left focused instead: show_ex(window, 0) maps the window without
 * activating it and claims nothing, so a window spawned to reappear cannot
 * steal the foreground from the one that is meant to have it. */
void spdf_win_window_show(spdf_win_window* window);
void spdf_win_window_show_ex(spdf_win_window* window, int claim_foreground);
void spdf_win_window_invalidate(spdf_win_window* window);
float spdf_win_window_dpi_scale(const spdf_win_window* window);

/* THE TWO WINDOW-LEVEL HALVES OF THE READING THEME.
 *
 * Both live here rather than in spdf_win_paint() because both are properties of
 * an HWND, and spdf_win_d2d.h's load-bearing rule is that the compose path never
 * requires one -- the headless PNG probe and WM_PAINT must keep calling the
 * identical function. A title and an OS-drawn frame have no representation in a
 * WIC bitmap, so putting either behind the paint path would buy nothing and cost
 * every pixel test in the port.
 *
 * The title is UTF-16 in: the UTF-8 boundary belongs to whoever owns the
 * document, and this file is *W-only by rule (see the file header). */
void spdf_win_window_set_title(spdf_win_window* window, const wchar_t* title);

/* Ask DWM to draw the border and system menu dark, so `--dark` does not leave
 * a light frame wrapped around a #121212 canvas. Idempotent; a Windows without
 * the attribute simply keeps its light frame.
 *
 * THE CAPTION ITSELF IS OURS NOW. The client area covers the caption
 * (WM_NCCALCSIZE in spdf_win_window_caption.h) and the tab strip is the title
 * bar, with the three caption buttons drawn by the chrome painter from
 * SpdfWinChromeModel::maximized / caption_hot / caption_pressed. The title is
 * no longer visible anywhere on the window -- macOS's titleVisibility = Hidden
 * -- but spdf_win_window_set_title() still matters: the taskbar and Alt-Tab
 * read it. */
void spdf_win_window_set_dark_frame(spdf_win_window* window, int dark);

/* Does the SYSTEM want dark? 1 dark, 0 light.
 *
 * macOS gets this for free -- the reading theme follows the system appearance,
 * and every AppKit control resolves itself. Windows has no equivalent: the app
 * shipped light unless `--dark` was passed, so on a machine set to dark it was
 * the only bright window on the desktop. Reported from actual use: "it does not
 * respect the system theme".
 *
 * Read from HKCU\...\Themes\Personalize\AppsUseLightTheme, which is the APP
 * theme rather than SystemUsesLightTheme (the taskbar's). A missing value means
 * light, which is what Windows itself assumes.
 *
 * Deliberately NOT in spdf_win_chrome_theme.h. That header's palette is
 * concrete sRGB on purpose, so the chrome is pixel-testable with no desktop; a
 * value read from the registry is unavailable in exactly the environment those
 * tests run in. This function is a WINDOW-layer question -- "what should the app
 * start as" -- and its answer is fed in as the initial state, not consulted
 * during paint.
 *
 * TWO THINGS THE CALLER MUST GET RIGHT, both learned the hard way:
 *
 * 1. ASK BEFORE THE CANVAS EXISTS. spdf_win_canvas takes its render flags AT
 *    CONSTRUCTION and has no setter -- the reading-theme button changes them by
 *    rebuilding the canvas over the same document. Applying the system theme
 *    after spdf_win_tabs_app_show() left the PAGES rendering light while the DWM
 *    caption and the minimap thumbnails, which read the flag later, went dark. A
 *    half-dark window is a worse bug than the one being fixed.
 *
 * 2. WINDOWED PATHS ONLY. --render-png and --render-window-png must not consult
 *    it: their output would start depending on a registry value on whichever
 *    machine runs them, so every pixel comparison in this port would quietly
 *    read the developer's personal setting. That is exactly what
 *    spdf_win_chrome_theme.h refuses to do for colours. --dark and --light both
 *    override, so a case can pin either. */
int spdf_win_system_prefers_dark(void);

/* Opt the process into dark menus and common controls, so a Win32 menu bar and
 * every TrackPopupMenu follow the system instead of staying light. Call once,
 * before any menu is created. Cosmetic and best-effort: on a Windows too old to
 * support it, nothing happens and the menus stay light. */
void spdf_win_enable_dark_menus(void);

/* THE MENU BAR. `hmenu` is an HMENU (spdf_win_menu_create()'s return), and the
 * window takes ownership: DestroyWindow destroys the menu with it.
 *
 * Here rather than inside spdf_win_window_create() because a menu bar is
 * PRODUCT POLICY -- which commands exist is the same kind of knowledge as which
 * key means "next page", and spdf_win_window.h's standing rule is that the
 * window owns neither. This file only hangs the handle on the HWND and turns the
 * WM_COMMAND that comes back into SPDF_WIN_INPUT_COMMAND.
 *
 * IT CHANGES THE CLIENT AREA. A menu bar comes out of the window's height, so
 * this is called BEFORE the window is shown and re-runs the sizing that
 * spdf_win_window_create() did -- otherwise the first document opens in a window
 * one menu bar shorter than every measurement in this port assumes.
 *
 * AND IT DOES NOT COMBINE WITH THE CLIENT-OWNED CAPTION: WM_NCCALCSIZE gives the
 * client the whole top of the frame, so a bar installed here would be painted
 * over the tab strip. Nothing calls this any more; see the note at its
 * definition in spdf_win_window_frame.h before bringing a menu bar back. */
void spdf_win_window_set_menu(spdf_win_window* window, void* hmenu);

/* The HWND, as void*, for the two things that genuinely need one: TrackPopupMenu
 * and IFileOpenDialog both take an owner window.
 *
 * THIS IS NOT A CRACK IN spdf_win_d2d.h's RULE. That rule is that
 * spdf_win_paint() must never require an HWND, which is what keeps the chrome
 * pixel-testable offscreen; it says nothing about a modal dialog, which has no
 * pixels in the render target at all. Nothing on the paint path may call this. */
void* spdf_win_window_native_handle(spdf_win_window* window);

/* THE WINDOW CLASS'S NAME, for the one question that can only be asked of an
 * HWND that is not ours: "is that window under the pointer a ShenzhenPDF
 * window?" A tab dragged out of one window and over another is a cross-PROCESS
 * gesture here (one window per process), so the source has nothing but the
 * desktop's HWNDs to go on; GetClassNameW against this is what keeps a tab from
 * being handed to some unrelated application under the pointer. See
 * spdf_win_tabs_handoff.h. Nothing on the paint path may call this either. */
const wchar_t* spdf_win_window_class_name(void);

/* --- full screen ---------------------------------------------------------
 *
 * Borderless, over the whole monitor the window is on, with the previous
 * placement remembered and put back on exit. A WINDOW property and nothing
 * more: what is drawn inside it -- chrome or no chrome -- is the caller's model
 * (SpdfWinChromeModel::presentation), which is how F11 (chrome kept) and F5
 * (chrome collapsed) share this one function. macOS: SPDFMacPresentation*,
 * GTK: gtk_window_fullscreen in spdf_window_set_presentation.
 *
 * THE ONE KEY POLICY THIS FILE HOLDS: an Escape the handler declined, while
 * the window is full screen, is delivered back as SPDF_WIN_INPUT_COMMAND
 * SPDF_WIN_CMD_FULLSCREEN -- "leave full screen", which the caller turns into
 * leaving presentation when that is what it is in. It is here rather than in
 * the keymap because the keymap runs FIRST and gets every Escape: a find field
 * dismisses, then a selection drops, and only an Escape nothing wanted reaches
 * this. Escape with nothing to dismiss and no full screen does NOTHING -- it
 * used to close the window, which macOS never does and which every reader who
 * cancelled a search twice would hit. */
void spdf_win_window_set_fullscreen(spdf_win_window* window, int on);
int spdf_win_window_is_fullscreen(const spdf_win_window* window);

/* The policy above as a pure predicate, so a test can pin it without a
 * window: does an Escape the handler declined leave full screen? 1 only while
 * the window is full screen. There is deliberately no other outcome -- in
 * particular no "close the window", which is what the fallback did until
 * portable/docs/windows-feature-matrix.md listed it as gap 2. */
static SPDF_WIN_WINDOW_INLINE int spdf_win_window_escape_leaves_fullscreen(int fullscreen) {
    return fullscreen ? 1 : 0;
}

/* Keep the display and the system awake while presenting, and let them sleep
 * again afterwards. Process-wide (SetThreadExecutionState on the UI thread),
 * idempotent, and safe to call with no window at all. */
void spdf_win_window_prevent_sleep(int on);

/* --- the placement, for the session -------------------------------------
 *
 * The window's NORMAL frame in virtual-screen device pixels -- what it occupies
 * when neither maximized nor full screen -- plus the display it is on, which
 * is what is worth remembering across launches (session.yaml "frame" as the
 * mac and GTK apps write theirs, and "display" as only this port does). The
 * rules are in spdf_win_placement.h; this is their Win32 half.
 *
 * restore runs BEFORE the first show and applies the saved frame RAW when its
 * display is attached where it was or the frame is visible somewhere. A frame
 * the desktop cannot show is parked centred on the main display instead --
 * and that stand-in is display-only: get keeps returning the frame the reader
 * left until they move or resize the window themselves, and the frame goes
 * back to its display when that display reappears (WM_DISPLAYCHANGE). It used
 * to clamp onto the nearest monitor and let the clamp be saved, which is how
 * one launch with an external display asleep forgot the position for good.
 * get returns 0 when there is no window to ask. */
int spdf_win_window_get_placement(const spdf_win_window* window, spdf_win_placement* out);
void spdf_win_window_restore_placement(spdf_win_window* window, const spdf_win_placement* saved);

/* Whether this window is the foreground window -- live while it exists, and
 * after it closed, whether it was when WM_CLOSE arrived. The session stamps the
 * window it saves with "focusedAt" only when this says so, which is how the
 * window the reader was last using is the one that comes back in front. */
int spdf_win_window_is_foreground(const spdf_win_window* window);

/* --- a periodic tick ------------------------------------------------------
 *
 * Calls `fn(user)` on the UI thread every `ms` milliseconds, with the same
 * `user` the input and scene callbacks get. 0 stops it. The session file is
 * the reason this exists: written only at exit, a crash or a power cut loses
 * every tab the reader opened since launch, so the caller saves on this tick
 * too. The window knows nothing about what the tick is for. */
typedef void (*spdf_win_tick_fn)(void* user);
void spdf_win_window_set_tick(spdf_win_window* window, unsigned ms, spdf_win_tick_fn fn);

/* --- and a ONE-SHOT --------------------------------------------------------
 *
 * Calls `fn(user)` once, `ms` after this returns, on the UI thread, then stops
 * itself. 0 or a NULL fn cancels a pending one.
 *
 * WHY THIS EXISTS RATHER THAN "DO IT ON THE FIRST TICK". Deferred launch work
 * has two requirements and the periodic tick can only meet one of them: it
 * must not run on the launch path, and it must not wait a whole period. The
 * orphan sweep of read-only shadow copies is the case (spdf_win_watch_app.h):
 * riding the 30 s session tick meant that a reader who opened a document and
 * closed the app inside half a minute never swept at all, and the copies
 * accumulated in %APPDATA% forever. Ten seconds is off the launch path by any
 * measure (the first page lands at ~150 ms) and short enough that a brief
 * session still gets one.
 *
 * ONE PENDING ONE-SHOT PER WINDOW, deliberately: two callers each wanting
 * their own delay is a second timer id, and the moment there are two the
 * window is scheduling for people rather than ticking. Setting a second one
 * replaces the first, which the single caller cannot do by accident. */
void spdf_win_window_set_once(spdf_win_window* window, unsigned ms, spdf_win_tick_fn fn);

/* --- a tooltip ------------------------------------------------------------
 *
 * Shows `text` in a tracking tooltip whose top-left is at the client point
 * (x, y), after a short delay so a pointer merely crossing a tab does not
 * flash a path at the reader. NULL text hides it at once. The one caller is
 * the tab strip's hover preview (macOS's hover panel,
 * SPDFMacTabStripView.mm:317-345, which shows the tab's full title); anything
 * that belongs in the window's own pixels is drawn by the chrome painter, not
 * by this. */
void spdf_win_window_tooltip(spdf_win_window* window, const wchar_t* text, int x, int y);

/* Runs the message pump until the window closes. Returns WM_QUIT's exit code,
 * which is 0 for a normal close -- the value main() should return. */
int spdf_win_window_run(spdf_win_window* window);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_WINDOW_H */
