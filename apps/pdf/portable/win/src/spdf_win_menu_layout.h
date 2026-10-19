#pragma once

/* spdf_win_menu_layout.h -- accelerators that survive a non-US KEYBOARD LAYOUT,
 * for spdf_win_menu.h only.
 *
 * Not a new layer: this is the second half of spdf_win_menu_command_for_key(),
 * split out because that header is at its 500-line cap and
 * tools/file-size-limits.md asks for an extracted file rather than a raised one.
 * Included from spdf_win_menu.h immediately after the exact matcher it wraps,
 * and from nowhere else.
 *
 * ------------------------------------------------------------------------
 * WHAT WAS WRONG, MEASURED.
 *
 * The table (spdf_win_menu_table.h) names its keys by VIRTUAL-KEY code, and a
 * virtual-key code is a property of the LAYOUT, not of the keyboard. On the
 * French AZERTY layout (0000040C), measured on this machine with
 * MapVirtualKeyExW(vk, MAPVK_VK_TO_CHAR, hkl):
 *
 *     vk=0xBD (VK_OEM_MINUS)   US sc=0x0C '-'      FR sc=0x00  -- NOT ON THE LAYOUT
 *     vk=0x36 (VK_6)           US '6'              FR '-'
 *     vk=0xBB (VK_OEM_PLUS)    US '='              FR '='
 *     vk=0xBC (VK_OEM_COMMA)   US ','              FR ','
 *
 * VK_OEM_MINUS does not exist on a French keyboard AT ALL: no key produces it,
 * MapVirtualKeyExW maps it to scan code 0. So every row keyed on it was dead
 * for a French reader -- Zoom Out (Ctrl+-), Smaller Text (Ctrl+Alt+-), and the
 * bare '-' in spdf_win_chrome_commands.h's keymap. The '-' key a French reader
 * presses reports VK_6, which no row names. Zoom In survived only because
 * VK_OEM_PLUS happens to sit on both layouts.
 *
 * THE ORIGINAL DOES NOT HAVE THIS PROBLEM, and the way it avoids it is the fix.
 * ShenzhenPDFMac.mm:1963-1964 binds Zoom In and Zoom Out with
 * `keyEquivalent:@"+"` and `keyEquivalent:@"-"` -- CHARACTERS. AppKit matches a
 * key equivalent against the characters the active layout produces, so the mac's
 * accelerators are layout-independent for free. The port's rule is to port the
 * original's logic, so the port matches characters too.
 *
 * ------------------------------------------------------------------------
 * HOW, AND WHY IT CANNOT CHANGE THE US CASE.
 *
 * The VK match runs FIRST and unchanged. Only when it finds nothing does the
 * character match run, and it asks a question that on a US layout has the same
 * answer: "does this key's own character equal the character this row's key
 * stands for?" On US, MapVirtualKeyW(VK_OEM_MINUS, MAPVK_VK_TO_CHAR) is '-',
 * which is exactly what the OEM_MINUS row stands for -- so the fallback can only
 * ever agree with a VK match that already fired. Every existing assertion in
 * menu_test.c is therefore untouched, which is the point of the ordering.
 *
 * A row can only be reached by character if its key stands for one:
 * spdf_win_menu_key_us_char() answers for letters, digits and the three OEM keys
 * the table actually uses, and 0 for everything else -- so no function key, no
 * arrow and no Delete row is reachable this way, however a layout numbers them.
 *
 * ------------------------------------------------------------------------
 * ALTGR IS CTRL+ALT, AND THAT IS TEXT.
 *
 * On every European layout AltGr is reported as Ctrl+Alt. Measured on FR:
 * AltGr+VK_OEM_PLUS is '}', AltGr+VK_0 is '@', AltGr+VK_4 is '{'. The table has
 * two Ctrl+Alt rows (Smaller/Larger Text, from the mac's Cmd+Alt+-/=), so a
 * French reader typing '}' -- in the find field, in the page field, anywhere --
 * also resized the Markdown text. Cmd+Alt is not AltGr on macOS, so the original
 * has nothing to say about this; it is a porting incompatibility and it is
 * settled here in the only direction that can be right: a keystroke the LAYOUT
 * turns into a character is text, and text is not an accelerator.
 *
 * `text_key` is the window's answer to that (spdf_win_window.cpp, from the
 * WM_CHAR TranslateMessage has already queued behind the WM_KEYDOWN). It gates
 * ONLY the Ctrl+Alt rows: Ctrl+letter also produces a WM_CHAR -- a control
 * character -- and gating on it would kill every accelerator in the table.
 */
#ifndef SPDF_WIN_MENU_LAYOUT_H
#define SPDF_WIN_MENU_LAYOUT_H

/* The US character an accelerator row's key stands for, or 0 for a key that
 * stands for no character at all (a function key, an arrow, Delete, Tab).
 *
 * Only the three OEM codes the table actually uses are listed. Adding a row on
 * a fourth means adding it here too, and leaving it out is not silent: the row
 * simply stays VK-only, which is what every row was before this file existed. */
static SPDF_WIN_MENU_INLINE unsigned spdf_win_menu_key_us_char(unsigned key) {
    if (key >= 'A' && key <= 'Z') return key;
    if (key >= '0' && key <= '9') return key;
    switch (key) {
        case SPDF_WIN_KEY_OEM_PLUS: return '=';
        case SPDF_WIN_KEY_OEM_MINUS: return '-';
        case SPDF_WIN_KEY_OEM_COMMA: return ',';
        default: return 0;
    }
}

/* THE ONE ENTRY POINT FOR A KEYSTROKE OFF A REAL KEYBOARD.
 *
 * `key`      the virtual-key code WM_KEYDOWN reported;
 * `key_char` the character that key produces on the ACTIVE layout with no
 *            modifiers, uppercased for letters, or 0 when it produces none --
 *            spdf_win_input::key_char, from MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR);
 * `mods`     the three modifier bits, matched exactly as ever;
 * `text_key` non-zero when the layout turned this keystroke into a printable
 *            character, i.e. when it is TEXT (see the AltGr note above).
 *
 * A caller with no layout information passes key_char = 0 and text_key = 0 and
 * gets exactly spdf_win_menu_command_for_key(). */
static SPDF_WIN_MENU_INLINE int spdf_win_menu_command_for_key_ex(unsigned key, unsigned key_char, unsigned mods,
                                                                int text_key) {
    int i, n = 0;
    const SpdfWinMenuItem* table;
    int command;
    unsigned wanted = mods & (SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT | SPDF_WIN_ACCEL_ALT);

    /* A printable character produced with AltGr is text. Refused BEFORE the VK
     * match, not after: on FR the VK match is exactly what fires (AltGr+'=' is
     * VK_OEM_PLUS with Ctrl+Alt, which IS the Larger Text row). */
    if (text_key && wanted == (SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_ALT)) return SPDF_WIN_CMD_NONE;

    command = spdf_win_menu_command_for_key(key, mods);
    if (command != SPDF_WIN_CMD_NONE) return command;
    if (!key_char || key_char == key) return SPDF_WIN_CMD_NONE;

    table = spdf_win_menu_table(&n);
    for (i = 0; i < n; ++i) {
        if (!table[i].key || table[i].command == SPDF_WIN_CMD_NONE) continue;
        if (table[i].mods != wanted) continue;
        if (spdf_win_menu_key_us_char(table[i].key) == key_char) return table[i].command;
    }

    /* A DIGIT ROW ON A LAYOUT WHERE THE DIGITS ARE SHIFTED.
     *
     * On AZERTY the top row is unshifted punctuation -- '&', 'e-acute', '"' --
     * and the digits are the SHIFTED positions, so a reader typing what the
     * menu prints
     * as "Ctrl+1" naturally presses Ctrl+Shift on that key, and the row wanted
     * plain Ctrl. Ctrl alone on the same key already matched above (the
     * virtual-key code is VK_1 either way), so this only ADDS the shifted
     * spelling, and only where the layout actually shifts its digits:
     * key_char is the digit itself on a US keyboard, and this is skipped there.
     *
     * It cannot shadow anything. The exact match ran over the whole table first,
     * so any real Ctrl+Shift+digit row would already have won. */
    if ((wanted & SPDF_WIN_ACCEL_SHIFT) && key >= '0' && key <= '9' && key_char != key)
        return spdf_win_menu_command_for_key(key, wanted & ~(unsigned)SPDF_WIN_ACCEL_SHIFT);
    return SPDF_WIN_CMD_NONE;
}

/* The same question for a BARE key that is not in the table -- the unmodified
 * '+' and '-' spdf_win_chrome_commands.h's keymap has always had. Answers with
 * the character the key produces on the active layout, falling back to the US
 * virtual-key code when the caller has no layout information.
 *
 * Returns the US character ('+', '-', '=') or 0. Shift is not consulted: a
 * layout that puts '+' on an unshifted key (FR does not; the Belgian and German
 * ones do for other glyphs) must work the same as one that does not, and the
 * caller is asking "which zoom key is this", not "what did the reader type". */
static SPDF_WIN_MENU_INLINE unsigned spdf_win_menu_zoom_char(unsigned key, unsigned key_char) {
    if (key_char == '+' || key_char == '-' || key_char == '=') return key_char;
    if (key_char) return 0;
    if (key == SPDF_WIN_KEY_OEM_PLUS) return '=';
    if (key == SPDF_WIN_KEY_OEM_MINUS) return '-';
    return 0;
}

#endif /* SPDF_WIN_MENU_LAYOUT_H */
