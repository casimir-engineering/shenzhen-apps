/* spdf_win_setup_prompt.h — the first-run dialog: "Run this copy", "Install",
 * "Install and run the installed app".
 *
 * Included by spdf_win_setup.cpp and by nothing else, like
 * spdf_win_setup_shell.h beside it and for the same reason (the 500-line cap
 * tools/file-size-limits.md asks not to raise). WHETHER to show it is
 * spdf_win_setup_first_run_action() in spdf_win_setup.h, pure and covered by
 * portable/win/tests/setup_test.c — this file only draws it.
 *
 * TASKDIALOGINDIRECT, THROUGH GetProcAddress. Three command links with a line
 * of explanation each is a shape MessageBoxW cannot draw at all, and
 * TaskDialogIndirect needs the Common Controls 6.0.0.0 assembly, which
 * portable/win/spdf_win.manifest already declares. But it is resolved at run
 * time rather than imported from comctl32.lib, exactly as
 * spdf_win_window_frame.h resolves DwmSetWindowAttribute and uxtheme's ordinal
 * 135: ONE BINARY THAT STARTS EVERYWHERE, and simply looks plainer on a Windows
 * that lacks the entry point. The fallback is a three-button MessageBoxW that
 * spells out which button means what, because a fallback nobody can read is not
 * a fallback.
 *
 * COM IS INITIALISED HERE AND NOWHERE ELSE ON THE LAUNCH PATH. TaskDialog needs
 * an apartment; the launch that does NOT show a dialog must not pay for one
 * (windows-launch-performance.md §8: first page at 142 ms, and nothing new goes
 * in front of it). So CoInitializeEx is scoped to this call, as it is around
 * the shortcut write in spdf_win_setup_shell.h.
 */
#ifndef SPDF_WIN_SETUP_PROMPT_H
#define SPDF_WIN_SETUP_PROMPT_H

typedef HRESULT(WINAPI* task_dialog_indirect_fn)(const TASKDIALOGCONFIG*, int*, int*, BOOL*);

/* The wording. Kept together so the three choices can be read as a set, which
 * is how the person in front of them reads them. Each command link is
 * "title\nexplanation", the form TDF_USE_COMMAND_LINKS takes. */
#define SPDF_WIN_SETUP_PROMPT_TITLE L"ShenzhenPDF"
#define SPDF_WIN_SETUP_PROMPT_HEADING L"Install Shenzhen PDF, or just run it?"
#define SPDF_WIN_SETUP_PROMPT_BODY                                                                  \
    L"This is one self-contained program file - no DLLs and nothing to set up - so running it as "   \
    L"it is works perfectly well. Installing only adds a Start Menu entry, an Apps & features "     \
    L"entry and the .pdf file association. It needs no administrator rights, writes nothing "       \
    L"outside your user account, and can be undone at any time."
#define SPDF_WIN_SETUP_PROMPT_RUN                                                                   \
    L"Run this copy\nLeave the program file where it is. Nothing is installed and nothing is "       \
    L"registered. You will not be asked again."
#define SPDF_WIN_SETUP_PROMPT_INSTALL                                                               \
    L"Install\nCopy it to your user account's program folder, add the Start Menu shortcut and the "  \
    L".pdf association, then close."
#define SPDF_WIN_SETUP_PROMPT_INSTALL_RUN                                                           \
    L"Install and run the installed app\nThe same, and then open the installed copy straight away."

/* The three-button MessageBoxW fallback, for a Windows with no
 * TaskDialogIndirect. Yes/No/Cancel are the only three buttons a message box
 * can be given, so the text says which is which -- and Cancel is the DISMISSAL,
 * not a third answer, so the question comes back next time. */
static int setup_prompt_message_box(void) {
    int rc = MessageBoxW(NULL,
                         L"Install Shenzhen PDF for your user account?\n\n"
                         L"This is one self-contained program file, so running it as it is works "
                         L"perfectly well. Installing adds a Start Menu entry, an Apps & features entry "
                         L"and the .pdf association, needs no administrator rights, and can be undone.\n\n"
                         L"Yes\t- install, and run the installed copy\n"
                         L"No\t- install only, then close\n"
                         L"Cancel\t- run this copy now, and ask again next time",
                         SPDF_WIN_SETUP_PROMPT_TITLE, MB_YESNOCANCEL | MB_ICONQUESTION);
    if (rc == IDYES) return SPDF_WIN_SETUP_BUTTON_INSTALL_RUN;
    if (rc == IDNO) return SPDF_WIN_SETUP_BUTTON_INSTALL;
    return IDCANCEL;
}

/* Show it. Returns the id of the command link pressed, or IDCANCEL for Esc, the
 * close box, or a dialog that could not be shown at all --
 * spdf_win_setup_action_for_button() turns every one of those into RUN_ONCE. */
static int setup_prompt_show(void) {
    HMODULE comctl;
    task_dialog_indirect_fn task_dialog;
    TASKDIALOGCONFIG config;
    TASKDIALOG_BUTTON buttons[3];
    HRESULT hr;
    int pressed = IDCANCEL;

    comctl = LoadLibraryW(L"comctl32.dll");
    task_dialog = comctl ? (task_dialog_indirect_fn)GetProcAddress(comctl, "TaskDialogIndirect") : NULL;
    if (!task_dialog) {
        if (comctl) FreeLibrary(comctl);
        return setup_prompt_message_box();
    }

    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
        FreeLibrary(comctl);
        return setup_prompt_message_box();
    }

    buttons[0].nButtonID = SPDF_WIN_SETUP_BUTTON_RUN;
    buttons[0].pszButtonText = SPDF_WIN_SETUP_PROMPT_RUN;
    buttons[1].nButtonID = SPDF_WIN_SETUP_BUTTON_INSTALL;
    buttons[1].pszButtonText = SPDF_WIN_SETUP_PROMPT_INSTALL;
    buttons[2].nButtonID = SPDF_WIN_SETUP_BUTTON_INSTALL_RUN;
    buttons[2].pszButtonText = SPDF_WIN_SETUP_PROMPT_INSTALL_RUN;

    memset(&config, 0, sizeof(config));
    config.cbSize = sizeof(config);
    config.hInstance = GetModuleHandleW(NULL);
    /* TDF_ALLOW_DIALOG_CANCELLATION is what gives the dialog its close box and
     * makes Esc return IDCANCEL. Without it there is no way out but an answer,
     * and a first-run dialog you cannot decline is a first-run dialog people
     * resent. */
    config.dwFlags = TDF_USE_COMMAND_LINKS | TDF_ALLOW_DIALOG_CANCELLATION;
    config.dwCommonButtons = 0;
    config.pszWindowTitle = SPDF_WIN_SETUP_PROMPT_TITLE;
    /* The app's own icon, resource id 1 (spdf_win_about_version.h names it
     * SPDF_WIN_RES_ICON_APP and spdf_win.rc numbers it 1 so Explorer takes it),
     * so the dialog is recognisably this program and not a system warning. */
    config.pszMainIcon = MAKEINTRESOURCEW(SPDF_WIN_RES_ICON_APP);
    config.pszMainInstruction = SPDF_WIN_SETUP_PROMPT_HEADING;
    config.pszContent = SPDF_WIN_SETUP_PROMPT_BODY;
    config.cButtons = 3;
    config.pButtons = buttons;
    /* "Run this copy" is the default: portable use is the recommended path, and
     * a dialog whose default action installs software is a dialog that installs
     * software by accident. */
    config.nDefaultButton = SPDF_WIN_SETUP_BUTTON_RUN;

    if (FAILED(task_dialog(&config, &pressed, NULL, NULL))) pressed = IDCANCEL;
    if (hr != RPC_E_CHANGED_MODE) CoUninitialize();
    FreeLibrary(comctl);
    return pressed;
}

#endif /* SPDF_WIN_SETUP_PROMPT_H */
