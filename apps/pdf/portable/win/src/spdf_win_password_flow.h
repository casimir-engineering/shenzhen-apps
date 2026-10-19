/* spdf_win_password_flow.h — the password prompt's LIFECYCLE, transcribed from
 * portable/linux/gtk4/spdf_password_lifecycle.c (the toolkit-free half that
 * tests/password_lifecycle_test.c pins).
 *
 * Three pure decisions, and only three:
 *
 *   1. THE PROMPT FLOW. Given an open attempt's status, do we finish, fail,
 *      ask, or wait for a parent window to appear first? The GTK flow waits
 *      for its parent to be MAPPED before asking, because a dialog presented
 *      on an unmapped window is lost; on Windows the equivalent is an owner
 *      HWND that is not yet visible. `incorrect` is remembered so the second
 *      prompt says so. (spdf_password_prompt_flow_*)
 *   2. THE RELOAD POLICY. When a watched, protected document changes on disk
 *      and the reader cancels or the reopen fails, the live document stays and
 *      the baseline is NOT advanced, so a later retry sees the change again.
 *      (spdf_password_reload_policy)
 *   3. THE STAGING PATH SHAPE. A reload of a read-only protected source goes
 *      through a private copy named "ro-<32 hex>.<ext>". The random half is
 *      the caller's (it needs a source of randomness); the shape is here.
 *      (spdf_password_reload_staging_path)
 *
 * Nothing here touches a password. Header-only, static, C, toolkit-free;
 * pinned by portable/win/tests/password_flow_test.c.
 */
#ifndef SPDF_WIN_PASSWORD_FLOW_H
#define SPDF_WIN_PASSWORD_FLOW_H

#include "shenzhen_pdf_core.h" /* spdf_open_status */

#include <stddef.h>
#include <string.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_PWF_INLINE static __inline
#else
#define SPDF_WIN_PWF_INLINE static inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* SpdfPasswordPromptAction */
typedef enum spdf_win_password_action {
    SPDF_WIN_PASSWORD_DONE = 0,       /* the document opened */
    SPDF_WIN_PASSWORD_FAILED,         /* a real error; report it */
    SPDF_WIN_PASSWORD_PRESENT_PARENT, /* show the owner window, then ask */
    SPDF_WIN_PASSWORD_ASK,            /* prompt now */
    SPDF_WIN_PASSWORD_CANCELLED
} spdf_win_password_action;

/* SpdfPasswordPromptFlow */
typedef struct SpdfWinPasswordFlow {
    int has_parent;
    int parent_mapped;
    int awaiting_parent;
    int incorrect; /* the last attempt carried a wrong password */
} SpdfWinPasswordFlow;

/* spdf_password_prompt_flow_init: a flow with no parent behaves as if the
 * parent were mapped -- a command-line open can prompt straight away. */
SPDF_WIN_PWF_INLINE void spdf_win_password_flow_init(SpdfWinPasswordFlow* flow, int has_parent, int parent_mapped) {
    if (!flow) return;
    memset(flow, 0, sizeof(*flow));
    flow->has_parent = has_parent != 0;
    flow->parent_mapped = !has_parent || parent_mapped;
}

/* spdf_password_prompt_flow_opened */
SPDF_WIN_PWF_INLINE spdf_win_password_action spdf_win_password_flow_opened(SpdfWinPasswordFlow* flow,
                                                                          spdf_open_status status) {
    if (!flow) return SPDF_WIN_PASSWORD_FAILED;
    if (status == SPDF_OPEN_OK) return SPDF_WIN_PASSWORD_DONE;
    if (status == SPDF_OPEN_ERROR) return SPDF_WIN_PASSWORD_FAILED;
    flow->incorrect = status == SPDF_OPEN_BAD_PASSWORD;
    if (!flow->parent_mapped) {
        flow->awaiting_parent = 1;
        return SPDF_WIN_PASSWORD_PRESENT_PARENT;
    }
    return SPDF_WIN_PASSWORD_ASK;
}

/* spdf_password_prompt_flow_parent_ready */
SPDF_WIN_PWF_INLINE spdf_win_password_action spdf_win_password_flow_parent_ready(SpdfWinPasswordFlow* flow) {
    if (!flow) return SPDF_WIN_PASSWORD_FAILED;
    if (!flow->awaiting_parent) return SPDF_WIN_PASSWORD_FAILED;
    flow->awaiting_parent = 0;
    flow->parent_mapped = 1;
    return SPDF_WIN_PASSWORD_ASK;
}

/* spdf_password_prompt_flow_cancel */
SPDF_WIN_PWF_INLINE spdf_win_password_action spdf_win_password_flow_cancel(SpdfWinPasswordFlow* flow) {
    if (!flow) return SPDF_WIN_PASSWORD_FAILED;
    flow->awaiting_parent = 0;
    return SPDF_WIN_PASSWORD_CANCELLED;
}

/* SpdfPasswordReloadPolicy / spdf_password_reload_policy */
typedef struct SpdfWinPasswordReloadPolicy {
    int replace_live_state;
    int advance_baseline;
    int retry_pending;
} SpdfWinPasswordReloadPolicy;

SPDF_WIN_PWF_INLINE SpdfWinPasswordReloadPolicy spdf_win_password_reload_policy(int opened, int cancelled) {
    SpdfWinPasswordReloadPolicy policy;
    memset(&policy, 0, sizeof(policy));
    (void)cancelled;
    if (opened) {
        policy.replace_live_state = 1;
        policy.advance_baseline = 1;
    } else {
        policy.retry_pending = 1;
    }
    return policy;
}

/* spdf_password_reload_staging_path, with the randomness supplied: `hex32` is
 * 32 hex digits (a UUID with its dashes removed, on GTK). The result is
 * "<directory>\ro-<hex32><.ext of source_path>", the extension being the
 * source's last '.' suffix when it lies in the last path component (either
 * separator). Returns 0 and writes "" when the directory is empty or the
 * result does not fit. */
SPDF_WIN_PWF_INLINE int spdf_win_password_reload_staging_path(const char* directory, const char* source_path,
                                                              const char* hex32, char* out, size_t out_cap) {
    const char* extension = NULL;
    const char* p;
    size_t dir_len, n;
    if (!out || !out_cap) return 0;
    out[0] = '\0';
    if (!directory || !*directory || !hex32 || strlen(hex32) != 32) return 0;
    for (p = source_path ? source_path : ""; *p; ++p) {
        if (*p == '.') extension = p;
        else if (*p == '\\' || *p == '/') extension = NULL;
    }
    if (!extension) extension = "";
    dir_len = strlen(directory);
    n = dir_len + 1 + 3 + 32 + strlen(extension);
    if (n >= out_cap) return 0;
    memcpy(out, directory, dir_len);
    out[dir_len] = (directory[dir_len - 1] == '\\' || directory[dir_len - 1] == '/') ? '\0' : '\\';
    if (out[dir_len]) dir_len++;
    memcpy(out + dir_len, "ro-", 3);
    memcpy(out + dir_len + 3, hex32, 32);
    strcpy(out + dir_len + 35, extension);
    return 1;
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_PASSWORD_FLOW_H */
