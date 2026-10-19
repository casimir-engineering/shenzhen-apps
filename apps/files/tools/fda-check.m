/*
 * fda-check.m — standalone CLI Full Disk Access probe. Prints a few lines
 * and exits; opens no window, launches no app. Exit 0 = granted, 1 = not.
 *
 * Mirrors the in-app probe nautilus_macos_fda_is_granted() in
 * nautilus/src/nautilus-macos-fda.m: attempt to read TCC-protected paths
 * that only Full Disk Access unlocks. EPERM/EACCES means TCC denied us;
 * a successful read means FDA is in effect; anything else (e.g. ENOENT)
 * is inconclusive and we fall through to the next probe.
 *
 * Also reports Nautilus's on-disk FDA prompt state
 * ($XDG_CONFIG_HOME/nautilus/macos-fda.ini, default ~/.config/…): the
 * one-time-ever "first-launch-prompt-shown" flag and the legacy
 * "prompt-dismissed" opt-out, so the once-only prompt behavior can be
 * verified from the CLI without opening the app.
 *
 * TCC CAVEAT: macOS attributes the access to the RESPONSIBLE PROCESS.
 * Run from a terminal or an IDE (e.g. Cursor), this reports whether THAT
 * host app has Full Disk Access — not any particular .app bundle. It is
 * only truthful for the shipped bundle when run as that bundle's process.
 */
#import <Foundation/Foundation.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef enum { DENIED, GRANTED, INCONCLUSIVE } ProbeResult;

static int denial_errno; /* set by a probe when it returns DENIED */

/* Primary probe: O_RDONLY open of a TCC-gated file (the user TCC.db). */
static ProbeResult probe_open_file(const char *path) {
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) { close(fd); return GRANTED; }
    if (errno == EPERM || errno == EACCES) { denial_errno = errno; return DENIED; }
    return INCONCLUSIVE;
}

/* Secondary probe: list a TCC-gated directory. opendir() alone can succeed
 * on protected dirs; the denial may only surface on the first readdir(). */
static ProbeResult probe_list_dir(const char *path) {
    DIR *dir = opendir(path);
    if (dir == NULL) {
        if (errno == EPERM || errno == EACCES) { denial_errno = errno; return DENIED; }
        return INCONCLUSIVE;
    }
    errno = 0;
    struct dirent *entry = readdir(dir);
    int saved_errno = errno;
    closedir(dir);
    if (entry != NULL || saved_errno == 0) return GRANTED;
    if (saved_errno == EPERM || saved_errno == EACCES) {
        denial_errno = saved_errno;
        return DENIED;
    }
    return INCONCLUSIVE;
}

/* Report the [fda] keys in Nautilus's state keyfile, mirroring the lookup in
 * nautilus-macos-fda.m (g_get_user_config_dir(): $XDG_CONFIG_HOME falling
 * back to ~/.config). Flat "key=true" scan is enough — the file is a tiny
 * GKeyFile that Nautilus itself writes. */
static void report_prompt_state(void) {
    NSString *config_dir = nil;
    const char *xdg = getenv("XDG_CONFIG_HOME");
    if (xdg != NULL && xdg[0] != '\0') {
        config_dir = @(xdg);
    } else {
        config_dir = [NSHomeDirectory() stringByAppendingPathComponent:@".config"];
    }
    NSString *state_path =
        [config_dir stringByAppendingPathComponent:@"nautilus/macos-fda.ini"];
    NSString *contents = [NSString stringWithContentsOfFile:state_path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];

    if (contents == nil) {
        printf("prompt state: %s missing — next bundled-app launch without FDA "
               "will show the one-time prompt\n",
               [state_path fileSystemRepresentation]);
        return;
    }

    BOOL shown = [contents containsString:@"first-launch-prompt-shown=true"];
    BOOL dismissed = [contents containsString:@"prompt-dismissed=true"];
    printf("prompt state (%s):\n", [state_path fileSystemRepresentation]);
    printf("  first-launch-prompt-shown = %s%s\n", shown ? "true" : "false",
           shown ? " (one-time prompt already used; it will never auto-show again)"
                 : " (one-time prompt not yet shown)");
    printf("  prompt-dismissed          = %s\n", dismissed ? "true" : "false");
}

int main(void) {
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        const char *tcc_db = [[home stringByAppendingPathComponent:
                               @"Library/Application Support/com.apple.TCC/TCC.db"]
                              fileSystemRepresentation];
        const char *safari = [[home stringByAppendingPathComponent:@"Library/Safari"]
                              fileSystemRepresentation];
        struct { const char *path; ProbeResult (*probe)(const char *); } probes[] = {
            { tcc_db, probe_open_file },   /* always exists: the decisive probe */
            { safari, probe_list_dir },    /* fallback if the first is inconclusive */
        };
        int status = 1;
        BOOL decided = NO;

        for (size_t i = 0; i < sizeof probes / sizeof probes[0] && !decided; i++) {
            ProbeResult r = probes[i].probe(probes[i].path);
            if (r == GRANTED) { printf("FDA: granted\n"); status = 0; decided = YES; }
            if (r == DENIED) {
                printf("FDA: NOT granted (%s on %s)\n",
                       denial_errno == EPERM ? "EPERM" : "EACCES", probes[i].path);
                decided = YES;
            }
        }
        if (!decided) printf("FDA: NOT granted (all probes inconclusive)\n");

        report_prompt_state();
        return status;
    }
}
