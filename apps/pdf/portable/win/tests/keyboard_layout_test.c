/* keyboard_layout_test.c -- the accelerators, replayed off a FRENCH AZERTY
 * keyboard, and required to fire the same commands as off a US one.
 *
 * WHY THIS FILE EXISTS. The app was reported as taking no keyboard input at
 * all on a machine with the French layout loaded. Nobody could reproduce it
 * with synthetic input, because every synthetic test sent US virtual-key codes
 * -- which is precisely the assumption under test. A virtual-key code is a
 * property of the LAYOUT, not of the keyboard, and measured on this machine:
 *
 *     MapVirtualKeyExW(VK_OEM_MINUS, MAPVK_VK_TO_VSC, 0000040C) == 0
 *
 * VK_OEM_MINUS is on NO French key. Every row of spdf_win_menu_table.h keyed on
 * it -- Zoom Out (Ctrl+-), Smaller Text (Ctrl+Alt+-) -- and the bare '-' in
 * spdf_win_chrome_commands.h's keymap were unreachable for a French reader. The
 * '-' key they do press reports VK_6, which no row named.
 *
 * HOW THE KEYSTROKES ARE OBTAINED. Not transcribed: MEASURED, from the layout
 * itself. LoadKeyboardLayoutW(L"0000040C", KLF_NOTELLSHELL) loads the French
 * layout into the process without disturbing the desktop's, VkKeyScanExW says
 * which key and which shift state a character is on, and MapVirtualKeyExW(...,
 * MAPVK_VK_TO_CHAR, ...) says what a key produces -- which is exactly what
 * spdf_win_window_input.h's key_char_for() asks of the ACTIVE layout at run
 * time. So the test feeds the router the same four values a real WM_KEYDOWN
 * from a real French keyboard feeds it, and the only thing standing in for the
 * message pump is the struct those values live in.
 *
 * WHAT IT DOES NOT NEED. No window, no HWND, no document, no desktop -- which
 * is the only kind of evidence this port collects in bulk (spdf_win_chrome_input.h
 * paragraph 2). If the French layout is not installed on the machine running
 * this, the layout cases are SKIPPED and said so out loud; the US cases and the
 * layout-free invariants still run, and the run still fails on a real
 * regression.
 */
#include "spdf_win_menu.h"

#include <windows.h>
#include <stdio.h>

#pragma comment(lib, "user32.lib")

static int g_failures = 0;
static int g_checks = 0;
static int g_skipped = 0;

#define CHECK_EQI(a, b)                                                                                                \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if ((int)(a) != (int)(b)) {                                                                                    \
            fprintf(stderr, "FAIL %s == %s (%d vs %d) (%s:%d)\n", #a, #b, (int)(a), (int)(b), __FILE__, __LINE__);      \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);                                           \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- one keystroke, as the window would report it ------------------------ */

/* The four values spdf_win_window.cpp puts in a SPDF_WIN_INPUT_KEY event. */
typedef struct Stroke {
    unsigned vk;
    unsigned key_char;
    unsigned mods;
    int text_key;
    int valid;
} Stroke;

/* key_char_for() from spdf_win_window_input.h, against a chosen layout rather
 * than the active one. Kept a copy rather than #included because that header
 * dereferences `struct spdf_win_window` and belongs to one translation unit;
 * the two are three lines each and the equality is what the FR '-' case below
 * actually exercises. */
static unsigned char_of_key(HKL hkl, unsigned vk) {
    UINT ch = MapVirtualKeyExW(vk, 2 /* MAPVK_VK_TO_CHAR */, hkl);
    if (ch == 0 || (ch & 0x80000000u)) return 0;
    ch &= 0x7FFFFFFFu;
    if (ch >= L'a' && ch <= L'z') ch -= 32;
    return ch < 0x10000u ? (unsigned)ch : 0u;
}

/* WHAT A READER PRESSES TO GET `want` WITH `extra` HELD DOWN.
 *
 * `want` is the character printed on the key cap the reader aims at, so this is
 * "the key that bears '-'", not "VK_OEM_MINUS". VkKeyScanExW answers with the
 * virtual-key code and the shift state the LAYOUT needs; `extra` is what the
 * reader adds (Ctrl, Alt).
 *
 * `shifted` chooses which of the two questions is being asked. 0 means "the key
 * '-' is printed on, pressed the way an accelerator is pressed" -- the reader
 * does NOT add the layout's own shift, because on AZERTY that would type a
 * digit rather than reach the key. 1 means "pressed exactly as if typing the
 * character", which is the AltGr and shifted-digit case.
 *
 * `text` says the layout turns the keystroke into a printable character, which
 * is what spdf_win_window_input.h's key_is_text() reports off the queue. */
static Stroke stroke_for(HKL hkl, wchar_t want, unsigned extra, int shifted, int text) {
    Stroke s;
    SHORT scan = VkKeyScanExW(want, hkl);
    memset(&s, 0, sizeof(s));
    if (scan == -1) return s; /* the character is not on this layout at all */
    s.valid = 1;
    s.vk = (unsigned)(scan & 0xFF);
    s.mods = extra;
    if (shifted) {
        unsigned state = (unsigned)((scan >> 8) & 0xFF);
        if (state & 1u) s.mods |= SPDF_WIN_ACCEL_SHIFT;
        if (state & 2u) s.mods |= SPDF_WIN_ACCEL_CTRL;
        if (state & 4u) s.mods |= SPDF_WIN_ACCEL_ALT;
    }
    s.key_char = char_of_key(hkl, s.vk);
    s.text_key = text;
    return s;
}

static int command_of(Stroke s) {
    return spdf_win_menu_command_for_key_ex(s.vk, s.key_char, s.mods, s.text_key);
}

/* --- the cases ----------------------------------------------------------- */

/* Every accelerator whose key is a CHARACTER, aimed at by the character on the
 * key cap. `shifted` is 0 throughout: an accelerator is pressed with the
 * modifiers the menu prints and nothing else. Run over both layouts, and the
 * assertion is the same for both -- which IS the property being tested. */
static void test_character_accelerators(HKL hkl, const char* name) {
    struct {
        wchar_t cap;
        unsigned mods;
        int command;
    } rows[] = {
        {L'-', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_ZOOM_OUT},
        {L'=', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_ZOOM_IN},
        {L',', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_OPEN_SETTINGS_FILE},
        {L'0', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_ZOOM_ACTUAL},
        {L'1', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_FIT_PAGE},
        {L'2', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_FIT_WIDTH},
        {L'3', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_FIT_HEIGHT},
        {L'o', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_OPEN},
        {L'f', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_FIND},
        {L'w', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_CLOSE_TAB},
        {L'q', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_QUIT},
        {L'a', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_SELECT_ALL},
        {L'z', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_NONE}, /* unbound on both */
        {L'm', SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, SPDF_WIN_CMD_ADD_COMMENT},
        {L'g', SPDF_WIN_ACCEL_CTRL, SPDF_WIN_CMD_FIND_NEXT},
        {L'g', SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, SPDF_WIN_CMD_FIND_PREV},
        {L'o', SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, SPDF_WIN_CMD_OPEN_PATH},
    };
    size_t i;
    for (i = 0; i < sizeof(rows) / sizeof(rows[0]); ++i) {
        Stroke s = stroke_for(hkl, rows[i].cap, rows[i].mods, 0, 0);
        if (!s.valid) {
            fprintf(stderr, "SKIP %s: '%lc' is not on that layout\n", name, rows[i].cap);
            ++g_skipped;
            continue;
        }
        ++g_checks;
        if (command_of(s) != rows[i].command) {
            fprintf(stderr, "FAIL %s: the '%lc' key (vk=0x%02X char='%lc' mods=%u) gave %d, wanted %d\n", name,
                    rows[i].cap, s.vk, s.key_char ? (wchar_t)s.key_char : L'?', s.mods, command_of(s),
                    rows[i].command);
            ++g_failures;
        }
    }
}

/* THE ONE THAT WAS BROKEN, spelled out. On AZERTY the '-' key is VK_6 and
 * VK_OEM_MINUS is on no key at all, so this is the exact keystroke that did
 * nothing before spdf_win_menu_layout.h existed. */
static void test_the_french_minus(HKL fr) {
    Stroke s = stroke_for(fr, L'-', SPDF_WIN_ACCEL_CTRL, 0, 0);
    CHECK(s.valid);
    CHECK_EQI(s.vk, '6');                       /* NOT VK_OEM_MINUS */
    CHECK_EQI(s.key_char, '-');                 /* which is how it is recovered */
    /* THE REGRESSION, PINNED. spdf_win_menu_command_for_key() is what
     * key_for_window() used to call, and this is what it says about the
     * keystroke a French reader makes to zoom out. */
    CHECK_EQI(spdf_win_menu_command_for_key(s.vk, s.mods), SPDF_WIN_CMD_NONE);
    CHECK_EQI(command_of(s), SPDF_WIN_CMD_ZOOM_OUT);
    /* And the code the table names really is absent, which is the measurement
     * the whole file rests on. */
    CHECK_EQI(MapVirtualKeyExW(SPDF_WIN_KEY_OEM_MINUS, 0 /* MAPVK_VK_TO_VSC */, fr), 0);
    /* The bare key, through the keymap's own helper. */
    CHECK_EQI(spdf_win_menu_zoom_char(s.vk, s.key_char), '-');
}

/* ALTGR IS CTRL+ALT. On AZERTY '}' is AltGr+'=', which is VK_OEM_PLUS with
 * Ctrl and Alt reported -- byte for byte the Larger Text accelerator. The
 * keystroke that produces a character is text. */
static void test_altgr_is_not_an_accelerator(HKL fr) {
    Stroke typing = stroke_for(fr, L'}', 0, 1, 1);
    Stroke pressing;
    CHECK(typing.valid);
    CHECK_EQI(typing.vk, SPDF_WIN_KEY_OEM_PLUS);
    CHECK_EQI(typing.mods, SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_ALT);
    CHECK_EQI(command_of(typing), SPDF_WIN_CMD_NONE);
    /* The same keystroke that produced NO character is the accelerator, which is
     * what a US reader pressing Ctrl+Alt+= is doing. */
    pressing = typing;
    pressing.text_key = 0;
    CHECK_EQI(command_of(pressing), SPDF_WIN_CMD_MD_TEXT_LARGER);
    /* Only Ctrl+Alt is gated. Ctrl+F queues a WM_CHAR too (0x06) -- but that is
     * not printable, so key_is_text() reports 0 and nothing here would ever see
     * it; even if it did, a Ctrl row must still fire. */
    {
        Stroke ctrl_f = stroke_for(fr, L'f', SPDF_WIN_ACCEL_CTRL, 0, 1);
        CHECK_EQI(command_of(ctrl_f), SPDF_WIN_CMD_FIND);
    }
}

/* THE SHIFTED DIGITS. AZERTY's top row is punctuation unshifted, so a reader
 * pressing what the menu prints as Ctrl+1 may well add Shift. Both spellings
 * reach the command; on US, where the digits are unshifted, Ctrl+Shift+1 is
 * still nothing. */
static void test_shifted_digits(HKL fr, HKL us) {
    Stroke fr_plain = stroke_for(fr, L'1', SPDF_WIN_ACCEL_CTRL, 0, 0);
    Stroke fr_shift = stroke_for(fr, L'1', SPDF_WIN_ACCEL_CTRL, 1, 0);
    Stroke us_shift = stroke_for(us, L'1', SPDF_WIN_ACCEL_CTRL, 1, 0);
    CHECK(fr_plain.valid && fr_shift.valid && us_shift.valid);
    /* The layout really does shift its digits, and the US one really does not. */
    CHECK_EQI(fr_shift.mods, SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT);
    CHECK_EQI(us_shift.mods, SPDF_WIN_ACCEL_CTRL);
    CHECK_EQI(command_of(fr_plain), SPDF_WIN_CMD_FIT_PAGE);
    CHECK_EQI(command_of(fr_shift), SPDF_WIN_CMD_FIT_PAGE);
    /* A US Ctrl+Shift+1 -- key_char IS '1' there, so the rule is inert. */
    CHECK_EQI(spdf_win_menu_command_for_key_ex('1', '1', SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, 0),
              SPDF_WIN_CMD_NONE);
}

/* A DEAD KEY IS NOT A COMMAND. On AZERTY VK_OEM_6 is the '^' dead key;
 * MapVirtualKeyExW marks it with the high bit and key_char_for() reports none,
 * so nothing can be bound to it by character. */
static void test_dead_key(HKL fr) {
    UINT raw = MapVirtualKeyExW(0xDD /* VK_OEM_6 */, 2 /* MAPVK_VK_TO_CHAR */, fr);
    CHECK((raw & 0x80000000u) != 0);
    CHECK_EQI(char_of_key(fr, 0xDD), 0);
    CHECK_EQI(spdf_win_menu_command_for_key_ex(0xDD, 0, SPDF_WIN_ACCEL_CTRL, 0), SPDF_WIN_CMD_NONE);
}

/* --- layout-free invariants ---------------------------------------------- */

/* THE US CASE IS UNTOUCHED, and that is the whole argument for the ordering
 * inside spdf_win_menu_command_for_key_ex(): the exact match runs first over
 * the whole table, so the fallback can only ever add. Asserted over EVERY row
 * rather than a sample -- a row the fallback shadowed would be a command that
 * silently changed meaning. */
static void test_ex_never_contradicts_the_exact_matcher(void) {
    int i, n = 0;
    const SpdfWinMenuItem* table = spdf_win_menu_table(&n);
    for (i = 0; i < n; ++i) {
        unsigned us_char;
        if (!table[i].key || table[i].command == SPDF_WIN_CMD_NONE) continue;
        us_char = spdf_win_menu_key_us_char(table[i].key);
        /* A US keyboard reports the row's own character for the row's own key. */
        CHECK_EQI(spdf_win_menu_command_for_key_ex(table[i].key, us_char, table[i].mods, 0),
                  spdf_win_menu_command_for_key(table[i].key, table[i].mods));
        /* And with no layout information at all, _ex IS the exact matcher. */
        CHECK_EQI(spdf_win_menu_command_for_key_ex(table[i].key, 0, table[i].mods, 0),
                  spdf_win_menu_command_for_key(table[i].key, table[i].mods));
    }
}

/* Keys bound by POSITION rather than by glyph must stay bound by position: no
 * layout moves VK_F11 or VK_LEFT, and a character match must never reach them. */
static void test_position_keys_are_not_characters(void) {
    CHECK_EQI(spdf_win_menu_key_us_char(SPDF_WIN_KEY_F11), 0);
    CHECK_EQI(spdf_win_menu_key_us_char(SPDF_WIN_KEY_LEFT), 0);
    CHECK_EQI(spdf_win_menu_key_us_char(SPDF_WIN_KEY_DELETE), 0);
    CHECK_EQI(spdf_win_menu_key_us_char(SPDF_WIN_KEY_TAB), 0);
    CHECK_EQI(spdf_win_menu_key_us_char(SPDF_WIN_KEY_ADD), 0);
    CHECK_EQI(spdf_win_menu_command_for_key_ex(SPDF_WIN_KEY_F11, 0, 0, 0), SPDF_WIN_CMD_FULLSCREEN);
    CHECK_EQI(spdf_win_menu_command_for_key_ex(SPDF_WIN_KEY_LEFT, 0, SPDF_WIN_ACCEL_ALT, 0),
              SPDF_WIN_CMD_PREV_PAGE);
    /* The keypad's own codes, which are the same everywhere. */
    CHECK_EQI(spdf_win_menu_command_for_key_ex(SPDF_WIN_KEY_SUBTRACT, '-', SPDF_WIN_ACCEL_CTRL, 0),
              SPDF_WIN_CMD_ZOOM_OUT);
}

/* The bare zoom keys the keymap reads through spdf_win_menu_zoom_char(). */
static void test_zoom_char(void) {
    CHECK_EQI(spdf_win_menu_zoom_char(SPDF_WIN_KEY_OEM_PLUS, '='), '=');   /* US and FR alike */
    CHECK_EQI(spdf_win_menu_zoom_char(SPDF_WIN_KEY_OEM_MINUS, '-'), '-');  /* US */
    CHECK_EQI(spdf_win_menu_zoom_char('6', '-'), '-');                     /* FR: the '-' key is VK_6 */
    CHECK_EQI(spdf_win_menu_zoom_char('6', '6'), 0);                       /* US: VK_6 is just a digit */
    CHECK_EQI(spdf_win_menu_zoom_char('0', 0xE0u), 0);                     /* FR: VK_0 bears 'a-grave' */
    /* No layout information: the US codes still answer, which is what keeps a
     * caller that never fills key_char working exactly as before. */
    CHECK_EQI(spdf_win_menu_zoom_char(SPDF_WIN_KEY_OEM_PLUS, 0), '=');
    CHECK_EQI(spdf_win_menu_zoom_char(SPDF_WIN_KEY_OEM_MINUS, 0), '-');
    CHECK_EQI(spdf_win_menu_zoom_char(SPDF_WIN_KEY_F5, 0), 0);
}

int main(void) {
    /* KLF_NOTELLSHELL (0x80): load the layout for this process without telling
     * the shell, so a test run does not add a language to the user's task bar. */
    HKL fr = LoadKeyboardLayoutW(L"0000040c", 0x80);
    HKL us = LoadKeyboardLayoutW(L"00000409", 0x80);

    test_ex_never_contradicts_the_exact_matcher();
    test_position_keys_are_not_characters();
    test_zoom_char();

    if (us) test_character_accelerators(us, "US 00000409");
    else fprintf(stderr, "SKIP: the US layout could not be loaded\n"), ++g_skipped;

    if (fr) {
        test_character_accelerators(fr, "FR 0000040c");
        test_the_french_minus(fr);
        test_altgr_is_not_an_accelerator(fr);
        test_dead_key(fr);
        if (us) test_shifted_digits(fr, us);
    } else {
        fprintf(stderr, "SKIP: the French layout (0000040c) is not installed on this machine;\n"
                        "      the AZERTY cases did not run. Install it to get the real evidence.\n");
        ++g_skipped;
    }

    printf("keyboard_layout_test: %d checks, %d failures, %d skipped\n", g_checks, g_failures, g_skipped);
    return g_failures == 0 ? 0 : 1;
}
