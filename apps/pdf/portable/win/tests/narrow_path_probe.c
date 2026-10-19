/* What does a non-ASCII path look like to a narrow main(int, char**) in the
 * guest, and can the CRT open it?
 *
 *   narrow_path_probe.exe <path>     0 = opened, 1 = could not open, 2 = usage
 *
 * This exists because the guest's ANSI code page is 1252, not UTF-8. Windows
 * hands `char** argv` to a program by converting the real UTF-16 command line
 * down to that code page, and `fopen` converts it back the same way -- so a
 * path like C:\Users\Raphael\... survives while anything outside CP1252 does
 * not, and a harness that assumed UTF-8 would mis-handle the fixture and then
 * blame the code under test. That is not hypothetical: it is how a real failure
 * in this port was first mis-diagnosed.
 *
 * The byte dump matters as much as the exit code. If this ever starts failing,
 * the bytes say immediately whether the path was mangled on the way IN (wrong
 * command-line conversion) or on the way OUT (fopen's own conversion), which
 * are different bugs with different fixes.
 */
#include <stdio.h>

int main(int argc, char** argv) {
    const unsigned char* p;
    FILE* f;

    if (argc < 2) {
        fprintf(stderr, "usage: narrow_path_probe <path>\n");
        return 2;
    }
    printf("argv1-bytes");
    for (p = (const unsigned char*)argv[1]; *p; ++p) printf(" %02X", *p);
    printf("\n");

    f = fopen(argv[1], "rb");
    if (!f) {
        printf("fopen FAILED\n");
        return 1;
    }
    fclose(f);
    printf("fopen ok\n");
    return 0;
}
