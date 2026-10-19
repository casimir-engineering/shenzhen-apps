/* An iOS executable linking the embedded core's static library, as an app would (tools/embedded-size.sh). With
   SZF_BASELINE it links nothing of the core, for the size of the executable around it. */
#include <stdint.h>

#ifndef SZF_BASELINE
uint64_t szfriends_embedded_probe(uint64_t seed);
#endif

int main(int argc, char **argv) {
    (void)argv;
#ifdef SZF_BASELINE
    return argc;
#else
    return (int)szfriends_embedded_probe((uint64_t)argc);
#endif
}
