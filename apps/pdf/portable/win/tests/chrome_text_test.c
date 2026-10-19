/* chrome_text_test.c — pins portable/win/src/spdf_win_chrome_text.h.
 *
 * WHAT IT IS FOR. Three fields in this app are now typeable, and the code behind
 * them is the oldest kind of code there is: an array, an index, and a memmove.
 * Every classic way to get it wrong is reachable from a keyboard in a few
 * seconds -- backspace at position 0, delete at the end, a caret left past the
 * terminator by something that replaced the text, a field filled to capacity --
 * and the consequence of the worst of them is a write past the end of a fixed
 * buffer that lives inside `struct app`.
 *
 * So the whole file is asserted rather than sampled, including the two things
 * only a UTF-16 field has to worry about: a surrogate pair must move and delete
 * as ONE character (half a pair cannot be converted to UTF-8 at all, and the
 * find query is converted on every keystroke), and a caret must never come to
 * rest between the halves.
 *
 * Header-only under test, so no `spdf-test-sources` line.
 */
#include "spdf_win_chrome_text.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);                                           \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_EQI(a, b)                                                                                                \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if ((int)(a) != (int)(b)) {                                                                                    \
            fprintf(stderr, "FAIL %s == %s (%d vs %d) (%s:%d)\n", #a, #b, (int)(a), (int)(b), __FILE__, __LINE__);      \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_STR(got, want)                                                                                           \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (wcscmp((got), (want)) != 0) {                                                                              \
            fprintf(stderr, "FAIL text is not as expected (%s:%d)\n", __FILE__, __LINE__);                             \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* A buffer with a CANARY past the end. Every test writes through the same
 * helper, and the canary is checked after every edit: the failure this file
 * exists to catch is an insert that runs one past the terminator, and a plain
 * string comparison would never see it. */
typedef struct Field {
    wchar_t text[16];
    wchar_t canary[4];
    int caret;
} Field;

static void field_init(Field* f, const wchar_t* initial) {
    memset(f, 0, sizeof(*f));
    f->canary[0] = f->canary[1] = f->canary[2] = f->canary[3] = 0x5A5A;
    if (initial) wcscpy_s(f->text, sizeof(f->text) / sizeof(f->text[0]), initial);
    f->caret = spdf_win_text_len(f->text);
}

static void check_canary(const Field* f) {
    int i;
    for (i = 0; i < 4; ++i) CHECK(f->canary[i] == 0x5A5A);
}

#define CAP ((int)(sizeof(((Field*)0)->text) / sizeof(wchar_t)))

/* --- typing -------------------------------------------------------------- */

static void test_insert(void) {
    Field f;
    field_init(&f, NULL);

    CHECK(spdf_win_text_insert(f.text, CAP, &f.caret, L'a'));
    CHECK(spdf_win_text_insert(f.text, CAP, &f.caret, L'c'));
    CHECK_STR(f.text, L"ac");
    CHECK_EQI(f.caret, 2);
    /* Insert in the MIDDLE, which is the case a naive append gets wrong and
     * which a reader reaches with one press of Left. */
    CHECK(spdf_win_text_move(f.text, &f.caret, -1));
    CHECK(spdf_win_text_insert(f.text, CAP, &f.caret, L'b'));
    CHECK_STR(f.text, L"abc");
    CHECK_EQI(f.caret, 2);
    /* And at the very front. */
    spdf_win_text_home(f.text, &f.caret);
    CHECK(spdf_win_text_insert(f.text, CAP, &f.caret, L'X'));
    CHECK_STR(f.text, L"Xabc");
    CHECK_EQI(f.caret, 1);
    check_canary(&f);
}

/* A FULL FIELD REFUSES. It must not truncate from the front, must not write the
 * terminator past the end, and must leave the caret alone. */
static void test_insert_at_capacity(void) {
    Field f;
    int i;
    field_init(&f, NULL);
    for (i = 0; i < CAP - 1; ++i) CHECK(spdf_win_text_insert(f.text, CAP, &f.caret, (unsigned)(L'a' + (i % 26))));
    CHECK_EQI(spdf_win_text_len(f.text), CAP - 1);
    /* Twenty more, from every caret position, and none of them may land. */
    for (i = 0; i < 20; ++i) {
        f.caret = i % CAP;
        CHECK(!spdf_win_text_insert(f.text, CAP, &f.caret, L'Z'));
        CHECK_EQI(spdf_win_text_len(f.text), CAP - 1);
    }
    check_canary(&f);

    /* A capacity of 1 (room for the terminator only) and 0 must both refuse
     * rather than write. */
    field_init(&f, NULL);
    f.caret = 0;
    CHECK(!spdf_win_text_insert(f.text, 1, &f.caret, L'a'));
    CHECK(!spdf_win_text_insert(f.text, 0, &f.caret, L'a'));
    CHECK_EQI(spdf_win_text_len(f.text), 0);
    check_canary(&f);
}

/* --- deleting ------------------------------------------------------------ */

static void test_backspace_and_delete(void) {
    Field f;
    field_init(&f, L"abcd");

    CHECK(spdf_win_text_backspace(f.text, &f.caret));
    CHECK_STR(f.text, L"abc");
    CHECK_EQI(f.caret, 3);
    /* At position 0 there is nothing behind the caret: a no-op, reported as
     * one, so it does not cost a repaint on every press. */
    spdf_win_text_home(f.text, &f.caret);
    CHECK(!spdf_win_text_backspace(f.text, &f.caret));
    CHECK_STR(f.text, L"abc");
    CHECK_EQI(f.caret, 0);
    /* Delete removes FORWARD and leaves the caret put. */
    CHECK(spdf_win_text_delete(f.text, &f.caret));
    CHECK_STR(f.text, L"bc");
    CHECK_EQI(f.caret, 0);
    /* At the end there is nothing in front of it. */
    spdf_win_text_end(f.text, &f.caret);
    CHECK(!spdf_win_text_delete(f.text, &f.caret));
    CHECK_STR(f.text, L"bc");
    /* Empty out completely, one press at a time, and keep going. */
    spdf_win_text_end(f.text, &f.caret);
    while (spdf_win_text_backspace(f.text, &f.caret)) { /* until empty */ }
    CHECK_EQI(spdf_win_text_len(f.text), 0);
    CHECK_EQI(f.caret, 0);
    CHECK(!spdf_win_text_delete(f.text, &f.caret));
    check_canary(&f);
}

/* --- a caret that arrived from somewhere else ---------------------------- */

/* Every edit clamps first, because the caret can be left stale by anything that
 * replaces the text -- taking focus reseeds the page field, and a restored
 * session could set either. An unclamped insert at a caret past the terminator
 * writes into whatever follows it in `struct app`. */
static void test_out_of_range_caret_is_clamped(void) {
    Field f;
    int c;
    for (c = -5; c < 20; ++c) {
        field_init(&f, L"abc");
        f.caret = c;
        spdf_win_text_insert(f.text, CAP, &f.caret, L'!');
        CHECK(f.caret >= 0 && f.caret <= spdf_win_text_len(f.text));
        CHECK_EQI(spdf_win_text_len(f.text), 4);
        check_canary(&f);

        field_init(&f, L"abc");
        f.caret = c;
        spdf_win_text_backspace(f.text, &f.caret);
        CHECK(f.caret >= 0 && f.caret <= spdf_win_text_len(f.text));
        check_canary(&f);

        field_init(&f, L"abc");
        f.caret = c;
        spdf_win_text_delete(f.text, &f.caret);
        CHECK(f.caret >= 0 && f.caret <= spdf_win_text_len(f.text));
        check_canary(&f);

        field_init(&f, L"abc");
        f.caret = c;
        spdf_win_text_move(f.text, &f.caret, 1);
        CHECK(f.caret >= 0 && f.caret <= 3);
        f.caret = c;
        spdf_win_text_move(f.text, &f.caret, -1);
        CHECK(f.caret >= 0 && f.caret <= 3);
    }
}

/* --- caret motion -------------------------------------------------------- */

static void test_move_home_end(void) {
    Field f;
    field_init(&f, L"abc");
    CHECK_EQI(f.caret, 3);
    /* Past the end and before the start are refused and REPORTED as no change,
     * so holding an arrow key at either end does not repaint continuously. */
    CHECK(!spdf_win_text_move(f.text, &f.caret, 1));
    CHECK_EQI(f.caret, 3);
    CHECK(spdf_win_text_move(f.text, &f.caret, -1));
    CHECK(spdf_win_text_move(f.text, &f.caret, -1));
    CHECK(spdf_win_text_move(f.text, &f.caret, -1));
    CHECK_EQI(f.caret, 0);
    CHECK(!spdf_win_text_move(f.text, &f.caret, -1));
    CHECK(!spdf_win_text_home(f.text, &f.caret));
    CHECK(spdf_win_text_end(f.text, &f.caret));
    CHECK_EQI(f.caret, 3);
    CHECK(!spdf_win_text_end(f.text, &f.caret));
    CHECK(spdf_win_text_clear(f.text, &f.caret));
    CHECK_EQI(spdf_win_text_len(f.text), 0);
    CHECK_EQI(f.caret, 0);
    CHECK(!spdf_win_text_clear(f.text, &f.caret)); /* already empty: no change */
}

/* --- surrogate pairs ----------------------------------------------------- */

/* U+1F600 is D83D DE00. Two WM_CHARs go in; ONE character has to come out of
 * every operation that counts characters, or the UTF-8 conversion the find
 * bridge does on every keystroke is handed an unpaired surrogate. */
static void test_surrogate_pair_is_one_character(void) {
    Field f;
    field_init(&f, NULL);
    CHECK(spdf_win_text_insert(f.text, CAP, &f.caret, 0xD83D));
    CHECK(spdf_win_text_insert(f.text, CAP, &f.caret, 0xDE00));
    CHECK(spdf_win_text_insert(f.text, CAP, &f.caret, L'x'));
    CHECK_EQI(spdf_win_text_len(f.text), 3);

    /* Backspace over the 'x', then over the pair: two presses, not three. */
    CHECK(spdf_win_text_backspace(f.text, &f.caret));
    CHECK_EQI(spdf_win_text_len(f.text), 2);
    CHECK(spdf_win_text_backspace(f.text, &f.caret));
    CHECK_EQI(spdf_win_text_len(f.text), 0);
    CHECK_EQI(f.caret, 0);
    check_canary(&f);

    /* Forward delete takes the pair whole too. */
    field_init(&f, NULL);
    f.caret = 0;
    spdf_win_text_insert(f.text, CAP, &f.caret, 0xD83D);
    spdf_win_text_insert(f.text, CAP, &f.caret, 0xDE00);
    spdf_win_text_home(f.text, &f.caret);
    CHECK(spdf_win_text_delete(f.text, &f.caret));
    CHECK_EQI(spdf_win_text_len(f.text), 0);

    /* And the caret steps over it rather than into it, in both directions. */
    field_init(&f, NULL);
    f.caret = 0;
    spdf_win_text_insert(f.text, CAP, &f.caret, L'a');
    spdf_win_text_insert(f.text, CAP, &f.caret, 0xD83D);
    spdf_win_text_insert(f.text, CAP, &f.caret, 0xDE00);
    spdf_win_text_insert(f.text, CAP, &f.caret, L'b');
    spdf_win_text_home(f.text, &f.caret);
    CHECK(spdf_win_text_move(f.text, &f.caret, 1));
    CHECK_EQI(f.caret, 1); /* after 'a', before the pair */
    CHECK(spdf_win_text_move(f.text, &f.caret, 1));
    CHECK_EQI(f.caret, 3); /* jumped the pair, not into it */
    CHECK(spdf_win_text_move(f.text, &f.caret, -1));
    CHECK_EQI(f.caret, 1);
    check_canary(&f);
}

/* --- what a field accepts ------------------------------------------------ */

static void test_printable_and_digit(void) {
    unsigned u;
    /* Windows sends WM_CHAR for Backspace, Tab, Return and Escape; all four are
     * handled as KEYS and must never be inserted as text. */
    CHECK(!spdf_win_text_is_printable(0x08));
    CHECK(!spdf_win_text_is_printable(0x09));
    CHECK(!spdf_win_text_is_printable(0x0D));
    CHECK(!spdf_win_text_is_printable(0x1B));
    CHECK(!spdf_win_text_is_printable(0x7F));
    for (u = 0; u < 0x20; ++u) CHECK(!spdf_win_text_is_printable(u));
    CHECK(spdf_win_text_is_printable(L' '));
    CHECK(spdf_win_text_is_printable(L'a'));
    CHECK(spdf_win_text_is_printable(0x00FC)); /* u-umlaut */
    CHECK(spdf_win_text_is_printable(0x4E2D)); /* CJK */
    CHECK(spdf_win_text_is_printable(0xD83D)); /* a surrogate half is stored */

    for (u = L'0'; u <= L'9'; ++u) CHECK(spdf_win_text_is_digit(u));
    CHECK(!spdf_win_text_is_digit(L'-'));
    CHECK(!spdf_win_text_is_digit(L'a'));
    CHECK(!spdf_win_text_is_digit(0xFF10)); /* a FULLWIDTH digit is not one */
}

/* --- the page field's value ---------------------------------------------- */

static void test_page_value(void) {
    CHECK_EQI(spdf_win_text_page_value(L"1"), 1);
    CHECK_EQI(spdf_win_text_page_value(L"117"), 117);
    CHECK_EQI(spdf_win_text_page_value(L"007"), 7);
    /* Empty is not page 0, and neither is "0": the field is 1-BASED, and a 0
     * that became page index -1 is the kind of thing that reaches the canvas. */
    CHECK_EQI(spdf_win_text_page_value(L""), -1);
    CHECK_EQI(spdf_win_text_page_value(L"0"), -1);
    CHECK_EQI(spdf_win_text_page_value(NULL), -1);
    /* Anything non-numeric is refused outright rather than parsed as far as it
     * goes -- "12x" is a typo, not page 12. */
    CHECK_EQI(spdf_win_text_page_value(L"12x"), -1);
    CHECK_EQI(spdf_win_text_page_value(L"-3"), -1);
    CHECK_EQI(spdf_win_text_page_value(L" 4"), -1);
    /* A held-down digit key must saturate, not overflow into a negative page. */
    CHECK(spdf_win_text_page_value(L"999999999999999999999") > 0);
}

int main(void) {
    test_insert();
    test_insert_at_capacity();
    test_backspace_and_delete();
    test_out_of_range_caret_is_clamped();
    test_move_home_end();
    test_surrogate_pair_is_one_character();
    test_printable_and_digit();
    test_page_value();

    printf("chrome_text_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
