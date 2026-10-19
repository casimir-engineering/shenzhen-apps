/* spdf_win_setup_first_run.h — whether the first launch asks anything, and what
 * the answer means.
 *
 * Pure, and included by spdf_win_setup.h (after SPDF_WIN_SETUP_INLINE), which is
 * where the Win32 half, spdf_win_setup_first_run(), is declared. Its own file
 * because spdf_win_setup.h reached the 500-line cap tools/file-size-limits.md
 * asks not to raise — and because this really is a separate concern from the
 * install: the install is "what happens", this is "may we even ask". Getting the
 * second one wrong does not produce a wrong install. It produces a test run that
 * hangs on a modal dialog.
 *
 * A downloaded exe that just opens a window leaves the person who downloaded it
 * with no idea that installing is even possible, and an exe that installs itself
 * without asking is spyware manners. So the FIRST launch asks, once, with three
 * choices, and then never asks again.
 *
 * THE GATE IS THE DANGEROUS PART AND IS WHY IT IS PURE. A modal dialog shown on
 * a launch the test harness drives does not fail — it HANGS, and takes the whole
 * run with it. portable/win/screenshot-window.ps1 — and so verify-phase1.ps1,
 * which drives it — starts a real windowed app with a fresh temp --state-dir,
 * and a fresh state directory is indistinguishable from "never asked": without
 * the --state-dir arm it would sit at this dialog forever. measure-launch.ps1
 * and drive-window.ps1 cannot use --state-dir and set SPDF_WIN_SETUP_NO_PROMPT
 * instead, which spdf_win_setup.h explains and spdf_win_setup_first_run() folds
 * into explicit_flag. So every condition is an argument, the truth table is
 * portable/win/tests/setup_test.c's — all 64 combinations — and nothing about it
 * depends on a machine.
 */
#ifndef SPDF_WIN_SETUP_FIRST_RUN_H
#define SPDF_WIN_SETUP_FIRST_RUN_H

typedef enum spdf_win_setup_ask {
    SPDF_WIN_SETUP_FIRST_RUN_NONE = 0, /* do not ask; launch exactly as before */
    SPDF_WIN_SETUP_FIRST_RUN_ASK = 1
} spdf_win_setup_ask;

typedef enum spdf_win_setup_action {
    /* Run this copy AND remember the answer: the portable choice, made once. */
    SPDF_WIN_SETUP_ACTION_RUN_PORTABLE = 0,
    /* Install, report, and exit without opening a window. */
    SPDF_WIN_SETUP_ACTION_INSTALL = 1,
    /* Install, then launch the INSTALLED copy with the file argument, and exit. */
    SPDF_WIN_SETUP_ACTION_INSTALL_AND_RUN = 2,
    /* Run this copy for THIS launch only and do not remember: what Esc, the
     * close box and every skipped-prompt condition mean. "I did not answer" is
     * not an answer, so the question comes back next time. */
    SPDF_WIN_SETUP_ACTION_RUN_ONCE = 3
} spdf_win_setup_action;

/* The dialog's three command-link ids. Well above IDCONTINUE (11), the highest
 * common button id, so no common button can ever collide with one. */
#define SPDF_WIN_SETUP_BUTTON_RUN 101
#define SPDF_WIN_SETUP_BUTTON_INSTALL 102
#define SPDF_WIN_SETUP_BUTTON_INSTALL_RUN 103

/* Ask, or not. Every argument is a reason NOT to ask, and each is a real
 * situation:
 *
 *   headless          --render-png / --render-window-png, and any usage or
 *                     probe path. No desktop, no user, nobody to answer.
 *   explicit_flag     --install, --uninstall, --quiet, --purge, --portable or
 *                     --state-dir was passed. The person (or the script) has
 *                     already said what they want; asking would override it.
 *   portable_marker   ShenzhenPDF.portable sits next to the exe: this copy is
 *                     deliberately portable, permanently.
 *   running_from_
 *   install_dir       we ARE the installed copy. The question is answered by
 *                     the fact of being asked from there.
 *   already_installed the Uninstall key is present or the installed exe exists,
 *                     so this is a second copy of an installed app -- a build
 *                     tree, or the download kept in Downloads.
 *   answered          settings.yaml's setupPromptAnswered.
 */
static SPDF_WIN_SETUP_INLINE int spdf_win_setup_first_run_action(int already_installed,
                                                                int running_from_install_dir, int portable_marker,
                                                                int answered, int explicit_flag, int headless) {
    if (headless || explicit_flag) return SPDF_WIN_SETUP_FIRST_RUN_NONE;
    if (portable_marker || running_from_install_dir || already_installed) return SPDF_WIN_SETUP_FIRST_RUN_NONE;
    if (answered) return SPDF_WIN_SETUP_FIRST_RUN_NONE;
    return SPDF_WIN_SETUP_FIRST_RUN_ASK;
}

/* A dialog result to an action. Anything that is not one of the three command
 * links — IDCANCEL from Esc or the close box, IDOK, a failed dialog, 0 — is
 * RUN_ONCE, deliberately: the only way to remember an answer is to give one. */
static SPDF_WIN_SETUP_INLINE int spdf_win_setup_action_for_button(int button) {
    if (button == SPDF_WIN_SETUP_BUTTON_RUN) return SPDF_WIN_SETUP_ACTION_RUN_PORTABLE;
    if (button == SPDF_WIN_SETUP_BUTTON_INSTALL) return SPDF_WIN_SETUP_ACTION_INSTALL;
    if (button == SPDF_WIN_SETUP_BUTTON_INSTALL_RUN) return SPDF_WIN_SETUP_ACTION_INSTALL_AND_RUN;
    return SPDF_WIN_SETUP_ACTION_RUN_ONCE;
}

/* Does an action mean main() must stop rather than open a window? */
static SPDF_WIN_SETUP_INLINE int spdf_win_setup_action_exits(int action) {
    return action == SPDF_WIN_SETUP_ACTION_INSTALL || action == SPDF_WIN_SETUP_ACTION_INSTALL_AND_RUN;
}

#endif /* SPDF_WIN_SETUP_FIRST_RUN_H */
