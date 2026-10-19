/* QC canary: does a guest binary that CRASHES (rather than returning a status)
 * reach the Mac as a non-zero exit code?
 *
 * The whole Windows port's test story rests on prlctl exec propagating the
 * guest's exit status. `exit /b N` is already proven to propagate. A hard crash
 * is a different path entirely: the process is terminated by the OS with an
 * NTSTATUS such as 0xC0000005 (ACCESS_VIOLATION), which is a 32-bit value that
 * has to survive cmd.exe's ERRORLEVEL, prlctl, and POSIX's 8-bit wait status.
 * 0xC0000005 & 0xFF == 0x05, so a naive truncation is still non-zero -- but
 * 0xC0000100 & 0xFF == 0x00 would not be, and neither would a wrapper that
 * reports "the process did not return a value" as success.
 *
 * Run with an argument selecting the failure mode:
 *   crash_probe deref   -- null dereference       (0xC0000005)
 *   crash_probe abort   -- abort()                (0xC0000409 / 3 depending on CRT)
 *   crash_probe status  -- ExitProcess(0xC0000100)  <- low byte is ZERO
 *   crash_probe ok      -- returns 0
 *
 * Owned by the QC track. Not auto-discovered: run-tests.sh globs
 * portable/win/tests/*_test.c, not this subdirectory, so adding this file does
 * not change any other track's run.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "ok";

    if (strcmp(mode, "deref") == 0) {
        volatile int *p = (volatile int *)0;
        printf("crash_probe: dereferencing NULL\n");
        fflush(stdout);
        *p = 1;
        return 0; /* not reached */
    }
    if (strcmp(mode, "abort") == 0) {
        printf("crash_probe: calling abort()\n");
        fflush(stdout);
        abort();
    }
    if (strcmp(mode, "status") == 0) {
        /* Low byte is 0x00: this is the value that distinguishes a faithful
         * 32-bit propagation from an 8-bit truncation. */
        printf("crash_probe: ExitProcess(0xC0000100)\n");
        fflush(stdout);
        ExitProcess(0xC0000100u);
    }
    printf("crash_probe: ok\n");
    return 0;
}
