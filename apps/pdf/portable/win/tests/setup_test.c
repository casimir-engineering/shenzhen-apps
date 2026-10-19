/* setup_test.c — every decision --install and --uninstall make, driven without
 * touching the machine.
 *
 * NOTHING HERE CREATES A DIRECTORY, WRITES A KEY OR OPENS A SHORTCUT. That is
 * the point: an installer's arithmetic — which path, which shortcut, which
 * registry values, which argv means what — is exactly the part that must be
 * checkable on the workstation a person actually works on, and
 * spdf_win_setup.h is shaped so it can be. The registry writes are
 * setup_registry_test.c (under a throwaway root key) and the real install is
 * setup_e2e_test.c (under a redirected root); this file links nothing but the
 * header.
 *
 * Exit code is the whole signal.
 */
/* <windows.h> for IDOK / IDCANCEL / IDCONTINUE alone: the first-run dialog's
 * command-link ids have to be provably clear of every common button id, and
 * comparing against the real constants is the only way that check means
 * anything. Nothing here calls a Win32 function or links a library. */
#include <windows.h>

#include "spdf_win_setup.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                          \
    do {                                                                     \
        ++g_checks;                                                          \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__); \
            ++g_failures;                                                    \
        }                                                                    \
    } while (0)

#define CHECK_W(got, want)                                                                       \
    do {                                                                                         \
        ++g_checks;                                                                              \
        if (wcscmp((got), (want)) != 0) {                                                        \
            fprintf(stderr, "FAIL %s: got \"%ls\" want \"%ls\" (%s:%d)\n", #got, (got), (want),  \
                    __FILE__, __LINE__);                                                         \
            ++g_failures;                                                                        \
        }                                                                                        \
    } while (0)

#define BUF SPDF_WIN_SETUP_PATH_MAX

/* --- joining and splitting ------------------------------------------------- */

static void test_join(void) {
    wchar_t out[BUF];
    CHECK(spdf_win_setup_join(L"C:\\Apps", L"x.exe", out, BUF));
    CHECK_W(out, L"C:\\Apps\\x.exe");
    /* A trailing separator, in either spelling, must not double up. */
    CHECK(spdf_win_setup_join(L"C:\\Apps\\", L"x.exe", out, BUF));
    CHECK_W(out, L"C:\\Apps\\x.exe");
    CHECK(spdf_win_setup_join(L"C:/Apps/", L"x.exe", out, BUF));
    CHECK_W(out, L"C:/Apps\\x.exe");
    /* An empty dir yields the name alone rather than a leading separator, which
     * would be an absolute path on the current drive. */
    CHECK(spdf_win_setup_join(L"", L"x.exe", out, BUF));
    CHECK_W(out, L"x.exe");
    CHECK(spdf_win_setup_join(NULL, L"x.exe", out, BUF));
    CHECK_W(out, L"x.exe");
    /* Nothing truncates. */
    CHECK(!spdf_win_setup_join(L"C:\\Apps", L"x.exe", out, 8));
    CHECK(!spdf_win_setup_join(L"C:\\Apps", NULL, out, BUF));
    CHECK(!spdf_win_setup_join(L"C:\\Apps", L"x.exe", NULL, BUF));
}

static void test_dir_of(void) {
    wchar_t out[BUF];
    CHECK(spdf_win_setup_dir_of(L"C:\\Apps\\Shenzhen PDF\\ShenzhenPDF.exe", out, BUF));
    CHECK_W(out, L"C:\\Apps\\Shenzhen PDF");
    CHECK(spdf_win_setup_dir_of(L"C:/Apps/ShenzhenPDF.exe", out, BUF));
    CHECK_W(out, L"C:/Apps");
    /* The root keeps its separator: "C:" alone is drive-relative and means
     * something else entirely. */
    CHECK(spdf_win_setup_dir_of(L"C:\\ShenzhenPDF.exe", out, BUF));
    CHECK_W(out, L"C:\\");
    /* A bare file name has NO directory. Answering "." would put the portable
     * marker wherever the process happens to have been started from. */
    CHECK(!spdf_win_setup_dir_of(L"ShenzhenPDF.exe", out, BUF));
    CHECK(!spdf_win_setup_dir_of(NULL, out, BUF));
}

/* --- the install locations -------------------------------------------------- */

static void test_locations(void) {
    const wchar_t* programs = L"C:\\Users\\ada\\AppData\\Local\\Programs";
    const wchar_t* menu = L"C:\\Users\\ada\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs";
    wchar_t out[BUF];

    CHECK(spdf_win_setup_install_dir_in(programs, out, BUF));
    CHECK_W(out, L"C:\\Users\\ada\\AppData\\Local\\Programs\\ShenzhenPDF");
    CHECK(spdf_win_setup_install_exe_in(programs, out, BUF));
    CHECK_W(out, L"C:\\Users\\ada\\AppData\\Local\\Programs\\ShenzhenPDF\\ShenzhenPDF.exe");
    /* The exe name comes from the one version header, so the installed copy can
     * never be called something the association's open verb does not name. */
    CHECK_W(SPDF_WIN_SETUP_EXE_NAME, L"ShenzhenPDF.exe");

    CHECK(spdf_win_setup_shortcut_in(menu, out, BUF));
    CHECK_W(out, L"C:\\Users\\ada\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\ShenzhenPDF.lnk");

    CHECK(!spdf_win_setup_install_dir_in(L"", out, BUF));
    CHECK(!spdf_win_setup_install_dir_in(NULL, out, BUF));
    CHECK(!spdf_win_setup_shortcut_in(L"", out, BUF));
}

/* --- "am I already installed here?" ---------------------------------------- */

static void test_same_path(void) {
    /* The idempotent-repair comparison. Case-insensitive because NTFS is. */
    CHECK(spdf_win_setup_same_path(L"C:\\Apps\\ShenzhenPDF.exe", L"c:\\apps\\shenzhenpdf.EXE"));
    /* Separator-agnostic and trailing-separator tolerant, because the same
     * location arrives from a shell, a shortcut and an argv spelled three ways. */
    CHECK(spdf_win_setup_same_path(L"C:/Apps/ShenzhenPDF.exe", L"C:\\Apps\\ShenzhenPDF.exe"));
    CHECK(spdf_win_setup_same_path(L"C:\\Apps\\", L"C:\\Apps"));
    CHECK(spdf_win_setup_same_path(L"C:\\Apps//", L"C:\\Apps"));
    /* Different locations, including the near-misses that matter: a sibling
     * folder, and a longer path with the same prefix. */
    CHECK(!spdf_win_setup_same_path(L"C:\\Apps\\ShenzhenPDF.exe", L"D:\\Apps\\ShenzhenPDF.exe"));
    CHECK(!spdf_win_setup_same_path(L"C:\\Apps\\ShenzhenPDF.exe", L"C:\\Apps\\ShenzhenPDF.exe.old"));
    CHECK(!spdf_win_setup_same_path(L"C:\\Apps2\\ShenzhenPDF.exe", L"C:\\Apps\\ShenzhenPDF.exe"));
    CHECK(!spdf_win_setup_same_path(L"", L""));
    CHECK(!spdf_win_setup_same_path(NULL, L"C:\\x"));
    CHECK(!spdf_win_setup_same_path(L"C:\\x", NULL));
}

/* --- portable mode --------------------------------------------------------- */

static void test_portable(void) {
    wchar_t out[BUF];
    CHECK(spdf_win_setup_marker_in(L"E:\\ShenzhenPDF", out, BUF));
    CHECK_W(out, L"E:\\ShenzhenPDF\\ShenzhenPDF.portable");
    CHECK(spdf_win_setup_portable_data_in(L"E:\\ShenzhenPDF", out, BUF));
    CHECK_W(out, L"E:\\ShenzhenPDF\\ShenzhenPDF-data");

    /* marker, flag, state_dir */
    CHECK(spdf_win_setup_portable_wanted(1, 0, 0));  /* the USB-stick case */
    CHECK(spdf_win_setup_portable_wanted(0, 1, 0));  /* --portable with no marker */
    CHECK(spdf_win_setup_portable_wanted(1, 1, 0));
    CHECK(!spdf_win_setup_portable_wanted(0, 0, 0)); /* the default: %APPDATA% */
    /* --state-dir is the more specific statement and wins over both, which is
     * what keeps a test driving a real window from being hijacked by a marker
     * file someone left in the build directory. */
    CHECK(!spdf_win_setup_portable_wanted(1, 0, 1));
    CHECK(!spdf_win_setup_portable_wanted(1, 1, 1));
    CHECK(!spdf_win_setup_portable_wanted(0, 1, 1));
}

/* --- argv ------------------------------------------------------------------ */

static void parse(spdf_win_setup_args* out, const wchar_t* const* argv, int argc) {
    CHECK(spdf_win_setup_parse(argc, argv, out));
}

static void test_parse(void) {
    spdf_win_setup_args a;
    {
        const wchar_t* argv[] = {L"ShenzhenPDF.exe"};
        parse(&a, argv, 1);
        CHECK(!a.install && !a.uninstall && !a.quiet && !a.purge && !a.portable && !a.state_dir);
        CHECK(a.file == NULL);
    }
    {
        const wchar_t* argv[] = {L"ShenzhenPDF.exe", L"--install"};
        parse(&a, argv, 2);
        CHECK(a.install && !a.uninstall && !a.quiet);
        CHECK(a.file == NULL);
    }
    {
        const wchar_t* argv[] = {L"ShenzhenPDF.exe", L"--uninstall", L"--quiet", L"--purge"};
        parse(&a, argv, 4);
        CHECK(!a.install && a.uninstall && a.quiet && a.purge);
    }
    {
        /* The document is passed through the relaunch. */
        const wchar_t* argv[] = {L"ShenzhenPDF.exe", L"--install", L"C:\\docs\\a b.pdf"};
        parse(&a, argv, 3);
        CHECK(a.install);
        CHECK(a.file && wcscmp(a.file, L"C:\\docs\\a b.pdf") == 0);
    }
    {
        /* --state-dir's VALUE is not a document, and it disables the marker. */
        const wchar_t* argv[] = {L"ShenzhenPDF.exe", L"--state-dir", L"C:\\scratch\\state"};
        parse(&a, argv, 3);
        CHECK(a.state_dir);
        CHECK(a.file == NULL);
    }
    {
        const wchar_t* argv[] = {L"ShenzhenPDF.exe", L"--state-dir", L"C:\\s", L"C:\\docs\\a.pdf"};
        parse(&a, argv, 4);
        CHECK(a.state_dir);
        CHECK(a.file && wcscmp(a.file, L"C:\\docs\\a.pdf") == 0);
    }
    {
        /* --page's and --window's values likewise. */
        const wchar_t* argv[] = {L"ShenzhenPDF.exe", L"--page", L"7", L"--window", L"w-3"};
        parse(&a, argv, 5);
        CHECK(a.file == NULL);
    }
    {
        const wchar_t* argv[] = {L"ShenzhenPDF.exe", L"--portable", L"C:\\docs\\a.pdf"};
        parse(&a, argv, 3);
        CHECK(a.portable && !a.state_dir);
        CHECK(a.file && wcscmp(a.file, L"C:\\docs\\a.pdf") == 0);
    }
    {
        /* Flags this pass does not own are IGNORED, never rejected: the real
         * parser next door decides what is valid, and turning --render-png into
         * a usage error here would break the headless paths. */
        const wchar_t* argv[] = {L"ShenzhenPDF.exe", L"--render-png", L"--dark", L"a.pdf", L"0", L"1", L"o.png"};
        parse(&a, argv, 7);
        CHECK(!a.install && !a.uninstall && !a.portable);
    }
    CHECK(!spdf_win_setup_parse(1, NULL, NULL));
    CHECK(spdf_win_setup_flag_takes_value(L"--state-dir"));
    CHECK(spdf_win_setup_flag_takes_value(L"--page"));
    CHECK(!spdf_win_setup_flag_takes_value(L"--install"));
    CHECK(!spdf_win_setup_flag_takes_value(NULL));
}

/* --- the first-run question ------------------------------------------------
 *
 * THE ONE TABLE IN THIS FILE THAT CAN HANG A TEST RUN IF IT IS WRONG. The
 * dialog is modal and is shown before the window exists, so a gate that says
 * "ask" on a launch the harness drives does not fail -- it waits forever.
 * screenshot-window.ps1 -- and verify-phase1.ps1, which drives it -- starts a
 * real windowed app with a fresh temp --state-dir, and a fresh state directory
 * looks exactly like "never asked", so the --state-dir arm (explicit_flag) is
 * load bearing rather than tidy. measure-launch.ps1 and drive-window.ps1 cannot
 * pass --state-dir and set SPDF_WIN_SETUP_NO_PROMPT instead, which
 * spdf_win_setup_first_run() folds into that same argument. Hence: all 64
 * combinations, exhaustively. */

static void test_first_run_gate(void) {
    int installed, from_dir, marker, answered, explicit_flag, headless;
    for (installed = 0; installed < 2; ++installed)
        for (from_dir = 0; from_dir < 2; ++from_dir)
            for (marker = 0; marker < 2; ++marker)
                for (answered = 0; answered < 2; ++answered)
                    for (explicit_flag = 0; explicit_flag < 2; ++explicit_flag)
                        for (headless = 0; headless < 2; ++headless) {
                            /* Ask ONLY when every reason not to is absent. */
                            int want = (!installed && !from_dir && !marker && !answered && !explicit_flag &&
                                        !headless)
                                           ? SPDF_WIN_SETUP_FIRST_RUN_ASK
                                           : SPDF_WIN_SETUP_FIRST_RUN_NONE;
                            int got = spdf_win_setup_first_run_action(installed, from_dir, marker, answered,
                                                                     explicit_flag, headless);
                            ++g_checks;
                            if (got != want) {
                                fprintf(stderr,
                                        "FAIL first_run_action(installed=%d from_dir=%d marker=%d "
                                        "answered=%d explicit=%d headless=%d) = %d, want %d (%s:%d)\n",
                                        installed, from_dir, marker, answered, explicit_flag, headless, got,
                                        want, __FILE__, __LINE__);
                                ++g_failures;
                            }
                        }

    /* The one row that asks, spelled out so a reader can see it: a fresh
     * download, double-clicked, with nothing installed and nothing remembered. */
    CHECK(spdf_win_setup_first_run_action(0, 0, 0, 0, 0, 0) == SPDF_WIN_SETUP_FIRST_RUN_ASK);
    /* --render-window-png, and any usage or probe path: no desktop, nobody to
     * answer. */
    CHECK(spdf_win_setup_first_run_action(0, 0, 0, 0, 0, 1) == SPDF_WIN_SETUP_FIRST_RUN_NONE);
    /* --state-dir, --portable, --quiet, --purge: already told what to do. */
    CHECK(spdf_win_setup_first_run_action(0, 0, 0, 0, 1, 0) == SPDF_WIN_SETUP_FIRST_RUN_NONE);
    /* ShenzhenPDF.portable beside the exe: deliberately portable, forever. */
    CHECK(spdf_win_setup_first_run_action(0, 0, 1, 0, 0, 0) == SPDF_WIN_SETUP_FIRST_RUN_NONE);
    /* Launched from the install directory: the question answers itself. */
    CHECK(spdf_win_setup_first_run_action(0, 1, 0, 0, 0, 0) == SPDF_WIN_SETUP_FIRST_RUN_NONE);
    /* A second copy of an already-installed app (a build tree, or the download
     * still in Downloads). */
    CHECK(spdf_win_setup_first_run_action(1, 0, 0, 0, 0, 0) == SPDF_WIN_SETUP_FIRST_RUN_NONE);
    /* Answered once, never asked again. */
    CHECK(spdf_win_setup_first_run_action(0, 0, 0, 1, 0, 0) == SPDF_WIN_SETUP_FIRST_RUN_NONE);
}

static void test_first_run_buttons(void) {
    CHECK(spdf_win_setup_action_for_button(SPDF_WIN_SETUP_BUTTON_RUN) == SPDF_WIN_SETUP_ACTION_RUN_PORTABLE);
    CHECK(spdf_win_setup_action_for_button(SPDF_WIN_SETUP_BUTTON_INSTALL) == SPDF_WIN_SETUP_ACTION_INSTALL);
    CHECK(spdf_win_setup_action_for_button(SPDF_WIN_SETUP_BUTTON_INSTALL_RUN) ==
          SPDF_WIN_SETUP_ACTION_INSTALL_AND_RUN);
    /* Esc, the close box, a dialog that could not be shown, and anything else:
     * run this copy and REMEMBER NOTHING. "I did not answer" is not an answer,
     * so the question comes back next launch -- which is the difference between
     * the RUN_ONCE and RUN_PORTABLE actions and the only reason there are two. */
    CHECK(spdf_win_setup_action_for_button(IDCANCEL) == SPDF_WIN_SETUP_ACTION_RUN_ONCE);
    CHECK(spdf_win_setup_action_for_button(IDOK) == SPDF_WIN_SETUP_ACTION_RUN_ONCE);
    CHECK(spdf_win_setup_action_for_button(0) == SPDF_WIN_SETUP_ACTION_RUN_ONCE);
    CHECK(spdf_win_setup_action_for_button(-1) == SPDF_WIN_SETUP_ACTION_RUN_ONCE);
    /* No command-link id can collide with a common button id. */
    CHECK(SPDF_WIN_SETUP_BUTTON_RUN > IDCONTINUE);
    CHECK(SPDF_WIN_SETUP_BUTTON_INSTALL != SPDF_WIN_SETUP_BUTTON_RUN);
    CHECK(SPDF_WIN_SETUP_BUTTON_INSTALL_RUN != SPDF_WIN_SETUP_BUTTON_INSTALL);

    /* Which answers end the process rather than opening a window. */
    CHECK(!spdf_win_setup_action_exits(SPDF_WIN_SETUP_ACTION_RUN_PORTABLE));
    CHECK(!spdf_win_setup_action_exits(SPDF_WIN_SETUP_ACTION_RUN_ONCE));
    CHECK(spdf_win_setup_action_exits(SPDF_WIN_SETUP_ACTION_INSTALL));
    CHECK(spdf_win_setup_action_exits(SPDF_WIN_SETUP_ACTION_INSTALL_AND_RUN));
}

/* --- the Apps-list entry ---------------------------------------------------- */

static const spdf_win_setup_value* find(const spdf_win_setup_entry* e, const wchar_t* name) {
    int i;
    for (i = 0; i < e->count; ++i)
        if (wcscmp(e->values[i].name, name) == 0) return &e->values[i];
    return NULL;
}

static void test_uninstall_entry(void) {
    const wchar_t* exe = L"C:\\Users\\ada\\AppData\\Local\\Programs\\ShenzhenPDF\\ShenzhenPDF.exe";
    const wchar_t* dir = L"C:\\Users\\ada\\AppData\\Local\\Programs\\ShenzhenPDF";
    spdf_win_setup_entry e;
    const spdf_win_setup_value* v;

    CHECK(spdf_win_setup_uninstall_entry(exe, dir, 40640, &e));
    CHECK(e.count == 10);

    /* The three identity values come from spdf_win_about_version.h, the ONE
     * version source the About box, the updater's compare and VERSIONINFO
     * already share -- so an Apps & features row cannot claim a version the
     * running binary does not have. */
    v = find(&e, L"DisplayName");
    CHECK(v && !v->is_dword);
    if (v) CHECK_W(v->text, L"Shenzhen PDF");
    v = find(&e, L"DisplayVersion");
    CHECK(v && !v->is_dword);
    if (v) CHECK_W(v->text, SPDF_WIN_SETUP_WIDE(SPDF_WIN_VERSION_STR));
    v = find(&e, L"Publisher");
    CHECK(v && !v->is_dword);
    if (v) CHECK_W(v->text, L"Casimir Engineering");

    v = find(&e, L"DisplayIcon");
    CHECK(v && !v->is_dword);
    if (v) CHECK_W(v->text, exe);
    v = find(&e, L"InstallLocation");
    CHECK(v && !v->is_dword);
    if (v) CHECK_W(v->text, dir);

    /* KB, as that value is defined, and a DWORD, as the Apps list reads it. */
    v = find(&e, L"EstimatedSize");
    CHECK(v && v->is_dword && v->number == 40640);

    /* THE POINT OF THE WHOLE DESIGN: Windows' own Uninstall button runs the
     * app. Both strings quote the path, because %LOCALAPPDATA% sits under a
     * user name that may contain spaces. */
    v = find(&e, L"UninstallString");
    CHECK(v && !v->is_dword);
    if (v)
        CHECK_W(v->text,
                L"\"C:\\Users\\ada\\AppData\\Local\\Programs\\ShenzhenPDF\\ShenzhenPDF.exe\" --uninstall");
    v = find(&e, L"QuietUninstallString");
    CHECK(v && !v->is_dword);
    if (v)
        CHECK_W(v->text,
                L"\"C:\\Users\\ada\\AppData\\Local\\Programs\\ShenzhenPDF\\ShenzhenPDF.exe\" --uninstall --quiet");

    /* There is nothing to modify -- the install is one file -- and a Repair
     * button that did nothing would be worse than no button. */
    v = find(&e, L"NoModify");
    CHECK(v && v->is_dword && v->number == 1);
    v = find(&e, L"NoRepair");
    CHECK(v && v->is_dword && v->number == 1);

    /* Refused rather than half-built: a partial Uninstall key is a row the user
     * cannot remove. */
    CHECK(!spdf_win_setup_uninstall_entry(NULL, dir, 1, &e));
    CHECK(!spdf_win_setup_uninstall_entry(exe, NULL, 1, &e));
    CHECK(!spdf_win_setup_uninstall_entry(exe, dir, 1, NULL));
}

/* The widening macro the entry leans on: if L##x ever stopped working, every
 * identity value above would silently become something else. */
static void test_wide_macro(void) {
    const wchar_t* wide = SPDF_WIN_SETUP_WIDE(SPDF_WIN_VERSION_STR);
    const char* narrow = SPDF_WIN_VERSION_STR;
    size_t i;
    CHECK(wcslen(wide) == strlen(narrow));
    for (i = 0; i < strlen(narrow); ++i) CHECK(wide[i] == (wchar_t)narrow[i]);
    CHECK_W(SPDF_WIN_SETUP_WIDE(SPDF_WIN_PRODUCT_NAME), L"Shenzhen PDF");
}

int main(void) {
    test_join();
    test_dir_of();
    test_locations();
    test_same_path();
    test_portable();
    test_parse();
    test_first_run_gate();
    test_first_run_buttons();
    test_uninstall_entry();
    test_wide_macro();
    printf("setup_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
