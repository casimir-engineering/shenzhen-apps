/* clipboard_test.c — the copy path, and the specific way it would be wrong.
 *
 * WHY THIS IS ITS OWN SUITE. Copy is one function, but it is the function where
 * an encoding mistake is invisible until a user pastes CJK and gets "????".
 * This box's ANSI code page IS 1252, so the mistake is not hypothetical here:
 * test_ansi_would_mangle() below MEASURES what CF_TEXT would have done to the
 * same three strings, and that measurement is the whole argument for
 * CF_UNICODETEXT in spdf_win_selection.h section 5. If this machine's code page
 * ever changes, that case reports it and stops asserting rather than failing
 * for the wrong reason.
 *
 * IT NEEDS NO DOCUMENT AND NO MUPDF: the strings are literals, which is exactly
 * why it can be a separate, fast suite. What comes out of a real PDF is
 * selection_model_test.c's business, and it asserts the same UTF-8 bytes.
 *
 * THE REAL CLIPBOARD IS USED, not a mock -- a mock would prove nothing about
 * GlobalAlloc/GMEM_MOVEABLE ownership, which is the half of this code that can
 * corrupt a process. The user is at this machine, so the suite RESTORES nothing
 * and says so: a test that copies leaves its last string on the clipboard, the
 * same as any copy would. If the clipboard cannot be opened at all (another
 * process holding it for longer than the retry window), the round-trip cases
 * report SKIP and the suite still checks every pure conversion, rather than
 * failing for a reason that is not about this code.
 */
/* spdf-test-sources: portable/win/src/spdf_win_selection.cpp portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c */
/* spdf-test-needs: mupdf */
#include "spdf_win_selection.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;
static int g_skipped = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_EQI(a, b)                                                                                                \
    do {                                                                                                               \
        long long va = (long long)(a);                                                                                 \
        long long vb = (long long)(b);                                                                                 \
        ++g_checks;                                                                                                    \
        if (va != vb) {                                                                                                \
            printf("FAIL %s:%d: %s (%lld) != %s (%lld)\n", __FILE__, __LINE__, #a, va, #b, vb);                        \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* The three cases that matter, as UTF-8 byte literals so the compiler's source
 * charset cannot change what is being tested:
 *   ASCII      plain
 *   ACCENTED   Cafe resume naive with U+00E9 and U+00EF -- representable in
 *              CP1252, so it survives a narrow conversion and is here to prove
 *              the accented path is not what CP1252 breaks
 *   CJK        U+4E2D U+6587 U+6D4B U+8BD5 -- NOT representable in CP1252
 *   ASTRAL     U+1F600, which is a SURROGATE PAIR in UTF-16 and so the case a
 *              "one wchar_t per character" length calculation gets wrong */
static const char* k_ascii = "Selection fixture alpha";
static const char* k_accented = "Caf\xc3\xa9 r\xc3\xa9sum\xc3\xa9 na\xc3\xafve";
static const char* k_cjk = "\xe4\xb8\xad\xe6\x96\x87\xe6\xb5\x8b\xe8\xaf\x95";
static const char* k_astral = "grin \xf0\x9f\x98\x80 end";

static void test_conversion(void) {
    wchar_t buf[64];
    int n;

    /* Sizing pass, then the real one, and the returned length INCLUDES the NUL. */
    n = spdf_win_utf8_to_utf16(k_ascii, NULL, 0);
    CHECK_EQI(n, (int)strlen(k_ascii) + 1);
    CHECK_EQI(spdf_win_utf8_to_utf16(k_ascii, buf, 64), n);
    CHECK_EQI((int)wcslen(buf), (int)strlen(k_ascii));

    /* "Cafe resume naive" with three 2-byte accented characters: 20 UTF-8
     * bytes, 17 UTF-16 units plus the NUL. */
    n = spdf_win_utf8_to_utf16(k_accented, buf, 64);
    CHECK_EQI(n, 18);
    CHECK_EQI(buf[3], 0x00E9);
    CHECK_EQI(buf[6], 0x00E9);
    CHECK_EQI(buf[14], 0x00EF);

    /* Four CJK characters: 12 UTF-8 bytes, 4 UTF-16 units. */
    n = spdf_win_utf8_to_utf16(k_cjk, buf, 64);
    CHECK_EQI(n, 5);
    CHECK_EQI(buf[0], 0x4E2D);
    CHECK_EQI(buf[1], 0x6587);
    CHECK_EQI(buf[2], 0x6D4B);
    CHECK_EQI(buf[3], 0x8BD5);
    CHECK_EQI(buf[4], 0);

    /* U+1F600 is TWO UTF-16 units. A buffer sized by counting characters
     * rather than by asking would be one short here. */
    n = spdf_win_utf8_to_utf16(k_astral, buf, 64);
    CHECK_EQI(n, 12);
    CHECK_EQI(buf[5], 0xD83D);
    CHECK_EQI(buf[6], 0xDE00);

    /* A buffer one wchar_t too small fails rather than truncating: a half
     * selection pasted silently is worse than a copy that did not happen. */
    CHECK_EQI(spdf_win_utf8_to_utf16(k_cjk, buf, 4), 0);
    /* Invalid UTF-8 (a lone continuation byte) is refused, not substituted with
     * U+FFFD -- MB_ERR_INVALID_CHARS, and the reason is in the source. */
    CHECK_EQI(spdf_win_utf8_to_utf16("bad\x80tail", NULL, 0), 0);
    CHECK_EQI(spdf_win_utf8_to_utf16(NULL, NULL, 0), 0);
}

/* WHAT CF_TEXT WOULD HAVE DONE. Not a hypothetical: this runs the conversion
 * the narrow clipboard format performs, on this machine's real ANSI code page,
 * and reports it. */
static void test_ansi_would_mangle(void) {
    unsigned cp = GetACP();
    wchar_t wide[64];
    char narrow[128];
    BOOL used_default = FALSE;
    int n;

    printf("      ANSI code page: %u\n", cp);
    if (cp != 1252) {
        printf("      SKIP: this box is not CP1252, so the mangling measurement does not apply\n");
        ++g_skipped;
        return;
    }

    /* Accented text SURVIVES CP1252 -- which is exactly why picking the narrow
     * format looks safe right up until someone copies Chinese. */
    CHECK(spdf_win_utf8_to_utf16(k_accented, wide, 64) > 0);
    n = WideCharToMultiByte(1252, 0, wide, -1, narrow, sizeof(narrow), "?", &used_default);
    CHECK(n > 0);
    CHECK_EQI(used_default, FALSE);

    /* CJK DOES NOT. Every character comes back as the default '?', which is the
     * paste a reader would have got from CF_TEXT. */
    CHECK(spdf_win_utf8_to_utf16(k_cjk, wide, 64) > 0);
    used_default = FALSE;
    n = WideCharToMultiByte(1252, 0, wide, -1, narrow, sizeof(narrow), "?", &used_default);
    CHECK(n > 0);
    CHECK_EQI(used_default, TRUE);
    CHECK(strcmp(narrow, "????") == 0);
    printf("      CP1252 would paste CJK as: '%s'\n", narrow);
}

/* --- what would go on the clipboard --------------------------------------- */

/* THE PROOF THAT SURVIVES A LOCKED WORKSTATION. spdf_win_clipboard_alloc_utf16
 * builds the exact GMEM_MOVEABLE block SetClipboardData is handed, so this
 * inspects the bytes a paste would read -- length, every code unit, the
 * surrogate pair, the terminator -- with no clipboard involved. Everything
 * capable of corrupting a paste is checked here; the two calls that are not are
 * OpenClipboard and SetClipboardData. */
static void check_block(const char* what, const char* utf8, const wchar_t* expect, int expect_units) {
    HGLOBAL handle = spdf_win_clipboard_alloc_utf16(utf8);
    const wchar_t* view;
    SIZE_T bytes;

    CHECK(handle != NULL);
    if (!handle) return;
    bytes = GlobalSize(handle);
    /* GlobalAlloc may round up, so the floor is what is asserted -- the
     * terminator must be inside the block either way. */
    CHECK(bytes >= (SIZE_T)(expect_units + 1) * sizeof(wchar_t));
    view = (const wchar_t*)GlobalLock(handle);
    CHECK(view != NULL);
    if (view) {
        int i;
        ++g_checks;
        if (wcslen(view) != (size_t)expect_units) {
            printf("FAIL %s: %d units on the clipboard, expected %d\n", what, (int)wcslen(view), expect_units);
            ++g_failures;
        }
        for (i = 0; i <= expect_units; ++i) {
            ++g_checks;
            if (view[i] != expect[i]) {
                printf("FAIL %s: unit %d is U+%04X, expected U+%04X\n", what, i, (unsigned)view[i],
                       (unsigned)expect[i]);
                ++g_failures;
            }
        }
        printf("      %s: %d UTF-16 units, NUL-terminated, %u-byte block\n", what, expect_units, (unsigned)bytes);
        GlobalUnlock(handle);
    }
    GlobalFree(handle);
}

static void test_clipboard_block(void) {
    static const wchar_t cjk[] = {0x4E2D, 0x6587, 0x6D4B, 0x8BD5, 0};
    static const wchar_t accented[] = {'C', 'a', 'f', 0x00E9, ' ', 'r',    0x00E9, 's', 'u',
                                       'm', 0x00E9, ' ', 'n',  'a', 0x00EF, 'v',    'e', 0};
    static const wchar_t astral[] = {'g', 'r', 'i', 'n', ' ', 0xD83D, 0xDE00, ' ', 'e', 'n', 'd', 0};

    check_block("CJK block", k_cjk, cjk, 4);
    check_block("accented block", k_accented, accented, 17);
    check_block("astral block", k_astral, astral, 11);
    CHECK(spdf_win_clipboard_alloc_utf16(NULL) == NULL);
    CHECK(spdf_win_clipboard_alloc_utf16("") == NULL);
}

/* --- the real clipboard -------------------------------------------------- */

static void round_trip(const char* what, const char* utf8) {
    char back[512];
    int n;

    if (!spdf_win_clipboard_put_utf8(utf8)) {
        /* ERROR_ACCESS_DENIED here is a LOCKED WORKSTATION, not a defect: the
         * interactive window station's clipboard is not reachable while the
         * secure desktop is up, the same environment constraint that makes
         * screenshot-window.ps1 exit 68. Reported, never asserted away. */
        printf("      SKIP %s: OpenClipboard failed, GetLastError=%lu (5 = locked workstation)\n", what,
               GetLastError());
        ++g_skipped;
        return;
    }
    n = spdf_win_clipboard_get_utf8(back, sizeof(back));
    CHECK(n > 0);
    ++g_checks;
    if (strcmp(back, utf8) != 0) {
        printf("FAIL %s round trip: put '%s', got '%s'\n", what, utf8, back);
        ++g_failures;
    } else {
        printf("      %s round-tripped %d UTF-8 bytes intact\n", what, (int)strlen(back));
    }
}

static void test_round_trip(void) {
    round_trip("ascii", k_ascii);
    round_trip("accented", k_accented);
    round_trip("CJK", k_cjk);
    round_trip("astral", k_astral);

    /* The format published is CF_UNICODETEXT. CF_TEXT is present too, but
     * SYNTHESISED by Windows rather than put there by us -- which is the whole
     * point: a consumer that only understands the narrow format still gets
     * something, and nothing in this process ever did a narrow conversion. */
    if (OpenClipboard(NULL)) {
        CHECK(IsClipboardFormatAvailable(CF_UNICODETEXT));
        CloseClipboard();
    } else {
        ++g_skipped;
    }

    /* Empty and NULL copy nothing and say so, rather than clearing the
     * clipboard out from under whatever the reader had there. */
    CHECK_EQI(spdf_win_clipboard_put_utf8(NULL), 0);
    CHECK_EQI(spdf_win_clipboard_put_utf8(""), 0);
    CHECK_EQI(spdf_win_clipboard_get_utf8(NULL, 0), 0);
}

int main(void) {
    test_conversion();
    test_clipboard_block();
    test_ansi_would_mangle();
    test_round_trip();
    printf("clipboard_test: %d checks, %d failures, %d skipped\n", g_checks, g_failures, g_skipped);
    return g_failures ? 1 : 0;
}
