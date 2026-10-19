/* Measurement probe, not part of the suite (build-native.cmd builds it by name):
 * how long does a minimal /MT console exe take from kernel process creation
 * to main() on this machine? Prints the number in ms. The floor every launch
 * number in portable/docs/windows-launch-performance.md sits on. */
#include <windows.h>
#include <stdio.h>

int main(void) {
    FILETIME c, e, k, u, now;
    GetSystemTimePreciseAsFileTime(&now);
    GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u);
    unsigned long long cc = ((unsigned long long)c.dwHighDateTime << 32) | c.dwLowDateTime;
    unsigned long long nn = ((unsigned long long)now.dwHighDateTime << 32) | now.dwLowDateTime;
    printf("premain_ms=%.1f\n", (double)(nn - cc) / 10000.0);
    return 0;
}
