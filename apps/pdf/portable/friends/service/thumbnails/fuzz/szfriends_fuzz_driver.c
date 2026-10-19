/* A libFuzzer stand-in for compilers without the libFuzzer runtime (Apple clang has none), and the corpus replayer
 * friends-thumbnails-check runs. Links with one fuzz target (LLVMFuzzerTestOneInput) and AddressSanitizer plus
 * UndefinedBehaviorSanitizer, which turn any memory or arithmetic error into a crash.
 *
 * Usage: szfriends-fuzz-<target> [-seconds N] [-seed S] [-crashes DIR] CORPUS...
 *   Every file in each CORPUS directory (or each file named) runs once. With -seconds N, the driver then mutates
 *   corpus entries at random (bit flips, byte values, inserted, deleted and repeated ranges, splices of two entries,
 *   truncation, length-field nudges) for N seconds, and prints how many inputs ran. Without coverage feedback it finds
 *   less than libFuzzer, which thumbnails.mk prefers wherever it exists. A crashing input is written to
 *   DIR/crash-<pid> before the sanitizer ends the process. */

#include <dirent.h>
#include <sanitizer/common_interface_defs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

enum { SZF_MAX_INPUT = 70000, SZF_MAX_CORPUS = 4096 };

typedef struct {
    uint8_t *data;
    size_t size;
} szf_input;

static szf_input szf_corpus[SZF_MAX_CORPUS];
static size_t szf_corpus_count;
static const uint8_t *szf_current;
static size_t szf_current_size;
static const char *szf_crash_directory;
static uint64_t szf_state = 0x9e3779b97f4a7c15ull;

static uint64_t szf_random(void) {
    /* xorshift64*: reproducible from -seed, which a found crash needs more than cryptographic quality. */
    szf_state ^= szf_state >> 12;
    szf_state ^= szf_state << 25;
    szf_state ^= szf_state >> 27;
    return szf_state * 0x2545f4914f6cdd1dull;
}

static size_t szf_below(size_t bound) {
    return bound ? (size_t)(szf_random() % bound) : 0;
}

static void szf_dump_current(void) {
    if (szf_crash_directory == NULL || szf_current == NULL) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/crash-%d", szf_crash_directory, (int)getpid());
    FILE *file = fopen(path, "wb");
    if (file == NULL) return;
    fwrite(szf_current, 1, szf_current_size, file);
    fclose(file);
    fprintf(stderr, "szfriends fuzz: crashing input written to %s\n", path);
}

static void szf_run(const uint8_t *data, size_t size) {
    szf_current = data;
    szf_current_size = size;
    LLVMFuzzerTestOneInput(data, size);
    szf_current = NULL;
}

static void szf_add_file(const char *path) {
    struct stat info;
    if (stat(path, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size > SZF_MAX_INPUT) return;
    if (szf_corpus_count == SZF_MAX_CORPUS) return;
    FILE *file = fopen(path, "rb");
    if (file == NULL) return;
    size_t size = (size_t)info.st_size;
    uint8_t *data = malloc(size ? size : 1);
    if (data != NULL && fread(data, 1, size, file) == size) {
        szf_corpus[szf_corpus_count].data = data;
        szf_corpus[szf_corpus_count].size = size;
        szf_corpus_count++;
    } else {
        free(data);
    }
    fclose(file);
}

static void szf_add(const char *path) {
    DIR *directory = opendir(path);
    if (directory == NULL) {
        szf_add_file(path);
        return;
    }
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        char child[2048];
        snprintf(child, sizeof child, "%s/%s", path, entry->d_name);
        szf_add_file(child);
    }
    closedir(directory);
}

/* One mutation of `buffer` (`*size` bytes in use, room for SZF_MAX_INPUT). */
static void szf_mutate(uint8_t *buffer, size_t *size) {
    static const uint8_t interesting[] = {0x00, 0x01, 0x02, 0x10, 0x16, 0x17, 0x40, 0x7f, 0x80, 0xc0, 0xfe, 0xff};
    size_t n = *size;
    switch (szf_below(8)) {
    case 0: /* flip a bit */
        if (n) buffer[szf_below(n)] ^= (uint8_t)(1u << szf_below(8));
        break;
    case 1: /* an interesting byte */
        if (n) buffer[szf_below(n)] = interesting[szf_below(sizeof interesting)];
        break;
    case 2: { /* insert random bytes */
        size_t count = 1 + szf_below(16), at = szf_below(n + 1);
        if (n + count > SZF_MAX_INPUT) break;
        memmove(buffer + at + count, buffer + at, n - at);
        for (size_t i = 0; i < count; i++) buffer[at + i] = (uint8_t)szf_random();
        *size = n + count;
        break;
    }
    case 3: { /* delete a range */
        if (n == 0) break;
        size_t at = szf_below(n), count = 1 + szf_below(n - at < 32 ? n - at : 32);
        memmove(buffer + at, buffer + at + count, n - at - count);
        *size = n - count;
        break;
    }
    case 4: { /* repeat a range */
        if (n == 0) break;
        size_t at = szf_below(n), count = 1 + szf_below(n - at < 64 ? n - at : 64);
        if (n + count > SZF_MAX_INPUT) break;
        memmove(buffer + at + count, buffer + at, n - at);
        *size = n + count;
        break;
    }
    case 5: { /* splice the tail of another corpus entry */
        szf_input *other = &szf_corpus[szf_below(szf_corpus_count)];
        size_t at = szf_below(n + 1), from = szf_below(other->size + 1), count = other->size - from;
        if (at + count > SZF_MAX_INPUT) count = SZF_MAX_INPUT - at;
        memcpy(buffer + at, other->data + from, count);
        *size = at + count;
        break;
    }
    case 6: /* truncate */
        *size = szf_below(n + 1);
        break;
    default: { /* nudge a 16-bit big-endian value, the shape of every field length */
        if (n < 2) break;
        size_t at = szf_below(n - 1);
        unsigned value = ((unsigned)buffer[at] << 8 | buffer[at + 1]) + (unsigned)szf_below(5) - 2u;
        buffer[at] = (uint8_t)(value >> 8);
        buffer[at + 1] = (uint8_t)value;
        break;
    }
    }
}

int main(int argc, char **argv) {
    double seconds = 0;
    int first = 1;
    for (; first + 1 < argc && argv[first][0] == '-'; first += 2) {
        if (strcmp(argv[first], "-seconds") == 0) seconds = atof(argv[first + 1]);
        else if (strcmp(argv[first], "-seed") == 0) szf_state = strtoull(argv[first + 1], NULL, 0) | 1;
        else if (strcmp(argv[first], "-crashes") == 0) szf_crash_directory = argv[first + 1];
        else break;
    }
    for (int i = first; i < argc; i++) szf_add(argv[i]);
    if (szf_corpus_count == 0) {
        fprintf(stderr, "szfriends fuzz: no corpus files\n");
        return 2;
    }
    __sanitizer_set_death_callback(szf_dump_current);
    unsigned long long executions = 0;
    for (size_t i = 0; i < szf_corpus_count; i++, executions++) szf_run(szf_corpus[i].data, szf_corpus[i].size);
    printf("szfriends fuzz: replayed %zu corpus files\n", szf_corpus_count);
    if (seconds <= 0) return 0;
    uint8_t *buffer = malloc(SZF_MAX_INPUT);
    uint8_t *exact = NULL;
    if (buffer == NULL) return 1;
    time_t end = time(NULL) + (time_t)seconds;
    while (time(NULL) < end) {
        for (int batch = 0; batch < 256; batch++, executions++) {
            szf_input *seed = &szf_corpus[szf_below(szf_corpus_count)];
            size_t size = seed->size;
            memcpy(buffer, seed->data, size);
            for (size_t m = 1 + szf_below(6); m > 0; m--) szf_mutate(buffer, &size);
            /* An exact-size copy, so reading one byte past the input is an AddressSanitizer error, as in libFuzzer. */
            exact = malloc(size ? size : 1);
            if (exact == NULL) return 1;
            memcpy(exact, buffer, size);
            szf_run(exact, size);
            free(exact);
        }
    }
    free(buffer);
    printf("szfriends fuzz: %llu executions, 0 crashes\n", executions);
    return 0;
}
