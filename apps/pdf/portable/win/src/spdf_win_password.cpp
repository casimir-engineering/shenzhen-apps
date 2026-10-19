/* spdf_win_password.cpp — see spdf_win_password.h. */
#include "spdf_win_password.h"

#include "spdf_win_open.h" /* the process opener, for the Markdown branch */
#include "spdf_win_password_flow.h"
#include "spdf_win_paths.h"
#include "spdf_win_shell_dialog.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "user32.lib")

namespace {

int g_last_prompts = 0;

/* The last path component, for the prompt's message. Either separator. */
const char* leaf(const char* path) {
    const char* last = path;
    for (const char* p = path; *p; ++p)
        if (*p == '\\' || *p == '/') last = p + 1;
    return last;
}

void set_err(char* err, size_t err_len, const char* text) {
    if (!err || !err_len) return;
    strncpy_s(err, err_len, text ? text : "", _TRUNCATE);
}

/* One attempt with the given password (NULL for none). The core fills status
 * and, on failure, err. */
spdf_document* attempt(const char* utf8_path, const char* password, spdf_open_status* status, char* err,
                       size_t err_len) {
    spdf_authentication auth;
    if (err && err_len) err[0] = 0;
    return spdf_open_with_password(utf8_path, password, status, &auth, err, err_len);
}

/* Ask once. Returns 1 with the UTF-16 secret in `secret` (caller zeroes), 0 on
 * cancel, -1 when the dialog could not be shown. */
int ask(HWND owner, const char* utf8_path, int incorrect, wchar_t* secret, int secret_cap) {
    SpdfWinShellPrompt prompt;
    wchar_t message[640];
    wchar_t* name = spdf_win_utf16_dup_from_utf8(leaf(utf8_path));
    int rc;
    _snwprintf_s(message, _TRUNCATE, L"Enter the password to open %s.", name && name[0] ? name : L"this PDF");
    free(name);
    memset(&prompt, 0, sizeof(prompt));
    prompt.message = message;
    /* GTK's heading swaps to "Incorrect password. Try again." on a retry; here
     * the message stays and the note says it, so the file name stays visible. */
    prompt.note = incorrect ? L"Incorrect password. Try again." : NULL;
    prompt.ok_label = L"Unlock";
    prompt.out = secret;
    prompt.out_cap = secret_cap;
    prompt.password = 1;
    g_last_prompts++;
    rc = spdf_win_shell_prompt_run(owner, L"Password Required", &prompt);
    return rc;
}

} /* namespace */

int spdf_win_password_last_prompt_count(void) { return g_last_prompts; }

int spdf_win_open_document_interactive(void* hwnd_owner, const char* utf8_path, spdf_document** out, char* err,
                                       size_t err_len) {
    HWND owner = (HWND)hwnd_owner;
    SpdfWinPasswordFlow flow;
    spdf_open_status status = SPDF_OPEN_ERROR;
    spdf_document* doc;
    wchar_t secret[512];
    char narrow[2048];
    int result = -1;

    g_last_prompts = 0;
    if (!out) return -1;
    *out = NULL;
    if (!utf8_path || !*utf8_path) {
        set_err(err, err_len, "No path was given.");
        return -1;
    }
    /* A Markdown document carries no password state (shenzhen_pdf_core.h at
     * spdf_open_markdown), so it goes straight through the process opener --
     * spdf_win_md_open_any once spdf_win_main.cpp has installed it -- and never
     * through the prompt loop. This is what makes the tab model's one open
     * hook right for every document kind. */
    if (spdf_path_is_markdown(utf8_path)) {
        *out = spdf_win_open_document(utf8_path, err, err_len);
        if (!*out && err && err_len && !err[0]) set_err(err, err_len, "Could not open document.");
        return *out ? 1 : -1;
    }
    /* The GTK flow waits for an unmapped parent; a hidden owner here is shown
     * before the first prompt, so the dialog has something to be modal to. */
    spdf_win_password_flow_init(&flow, owner != NULL, owner && IsWindowVisible(owner));

    doc = attempt(utf8_path, NULL, &status, err, err_len);
    for (;;) {
        spdf_win_password_action action = spdf_win_password_flow_opened(&flow, status);
        int rc;
        if (doc) {
            *out = doc;
            result = 1;
            break;
        }
        if (action == SPDF_WIN_PASSWORD_FAILED) {
            if (err && err_len && !err[0]) set_err(err, err_len, "Could not open document.");
            break;
        }
        if (action == SPDF_WIN_PASSWORD_PRESENT_PARENT) {
            ShowWindow(owner, SW_SHOW);
            spdf_win_password_flow_parent_ready(&flow);
        }
        /* ASK: the prompt, then another attempt with what was typed. */
        secret[0] = 0;
        rc = ask(owner, utf8_path, flow.incorrect, secret, (int)(sizeof(secret) / sizeof(secret[0])));
        if (rc <= 0) {
            SecureZeroMemory(secret, sizeof(secret));
            if (rc == 0) {
                spdf_win_password_flow_cancel(&flow);
                if (err && err_len) err[0] = 0;
                result = 0;
            } else {
                set_err(err, err_len, "The password prompt could not be shown.");
            }
            break;
        }
        if (spdf_win_utf8_from_utf16((const spdf_wchar*)secret, narrow, sizeof(narrow)) == SPDF_WIN_CONV_ERROR)
            narrow[0] = 0; /* an unpaired surrogate: try the empty password, which will be wrong */
        SecureZeroMemory(secret, sizeof(secret));
        doc = attempt(utf8_path, narrow, &status, err, err_len);
        SecureZeroMemory(narrow, sizeof(narrow));
    }
    SecureZeroMemory(secret, sizeof(secret));
    SecureZeroMemory(narrow, sizeof(narrow));
    return result;
}
