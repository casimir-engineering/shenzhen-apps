/* The harness's own canary: a guest program whose only job is to exit with the
 * code it is told to.
 *
 *   exit_code_probe.exe [n]      -> exits with n (default 0)
 *
 * portable/win/tests/run-tests.sh builds this in the VM and runs it with a
 * deliberately non-zero argument. If the runner reports that as a pass, the
 * whole Windows test harness is worthless: it would silently bless every broken
 * change made after it. So this is checked before any real test runs.
 *
 * It prints the code as well, so a transcript alone shows what happened without
 * anyone having to trust the exit status they are trying to verify.
 */
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char** argv) {
    int code = argc > 1 ? atoi(argv[1]) : 0;
    printf("exit_code_probe requested %d\n", code);
    fflush(stdout);
    return code;
}
