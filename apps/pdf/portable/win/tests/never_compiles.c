/* Deliberately un-compilable. portable/win/tests/run-tests.sh feeds this to the
 * guest compiler to prove that a Windows build failure actually reaches the Mac
 * shell as a non-zero exit status. If this file ever starts compiling, the
 * "does a broken build fail the run?" check silently stops testing anything.
 *
 * Named so it is NOT picked up by the runner's *_test.c auto-discovery.
 */
this is not C and must never become C;
