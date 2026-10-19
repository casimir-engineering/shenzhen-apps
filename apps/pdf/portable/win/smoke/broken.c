/* Deliberately un-compilable. Not part of any product build.
 *
 * This exists so the exit-code contract of portable/win/vm-build.sh can be
 * tested rather than assumed. A cross-machine build script that always exits 0
 * is worse than no script at all: it reports success for a Windows tree that
 * does not compile, and every verification layered on top of it is worthless.
 * portable/win/verify.sh compiles this file and REQUIRES a non-zero exit.
 */
int main(void) {
    this is not C
}
