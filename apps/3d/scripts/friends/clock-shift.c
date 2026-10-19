// Preloaded into the Tauri bundler by tauri-package-check.sh on a Linux guest whose clock has run past 2106, where an
// rpm, whose times are 32-bit, cannot be written. For this one process and what it starts, every time past 2100 that
// it reads, from the wall clock or a file's status, is moved back by $SZF_CLOCK_SHIFT seconds; earlier times are left
// as they are. Nothing else in the guest, nor its clock or its files, changes.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>

#define LATE 4102444800LL // 2100-01-01

static long long shift(void) {
    const char *value = getenv("SZF_CLOCK_SHIFT");
    return value ? atoll(value) : 0;
}

static void back(long long *seconds) {
    if (*seconds > LATE) *seconds -= shift();
}

#define BACK(field)                \
    do {                           \
        long long s = (field);     \
        back(&s);                  \
        (field) = s;               \
    } while (0)

// The function this one stands in for, looked up once.
#define REAL(name, ...)                                              \
    typedef int (*name##_f)(__VA_ARGS__);                            \
    static name##_f real_##name;                                     \
    if (!real_##name) real_##name = (name##_f)dlsym(RTLD_NEXT, #name)

int clock_gettime(clockid_t clock, struct timespec *now) {
    REAL(clock_gettime, clockid_t, struct timespec *);
    int status = real_clock_gettime(clock, now);
    if (status == 0 && (clock == CLOCK_REALTIME || clock == CLOCK_REALTIME_COARSE)) BACK(now->tv_sec);
    return status;
}

static void back_stat(struct stat *info) {
    BACK(info->st_atim.tv_sec);
    BACK(info->st_mtim.tv_sec);
    BACK(info->st_ctim.tv_sec);
}

int statx(int dir, const char *path, int flags, unsigned int mask, struct statx *info) {
    REAL(statx, int, const char *, int, unsigned int, struct statx *);
    int status = real_statx(dir, path, flags, mask, info);
    if (status == 0) {
        BACK(info->stx_atime.tv_sec);
        BACK(info->stx_mtime.tv_sec);
        BACK(info->stx_ctime.tv_sec);
        BACK(info->stx_btime.tv_sec);
    }
    return status;
}

int stat(const char *path, struct stat *info) {
    REAL(stat, const char *, struct stat *);
    int status = real_stat(path, info);
    if (status == 0) back_stat(info);
    return status;
}

int lstat(const char *path, struct stat *info) {
    REAL(lstat, const char *, struct stat *);
    int status = real_lstat(path, info);
    if (status == 0) back_stat(info);
    return status;
}

int fstat(int file, struct stat *info) {
    REAL(fstat, int, struct stat *);
    int status = real_fstat(file, info);
    if (status == 0) back_stat(info);
    return status;
}

int fstatat(int dir, const char *path, struct stat *info, int flags) {
    REAL(fstatat, int, const char *, struct stat *, int);
    int status = real_fstatat(dir, path, info, flags);
    if (status == 0) back_stat(info);
    return status;
}

// The same under their large-file names, which some programs link instead.
static void back_stat64(struct stat64 *info) {
    BACK(info->st_atim.tv_sec);
    BACK(info->st_mtim.tv_sec);
    BACK(info->st_ctim.tv_sec);
}

int stat64(const char *path, struct stat64 *info) {
    REAL(stat64, const char *, struct stat64 *);
    int status = real_stat64(path, info);
    if (status == 0) back_stat64(info);
    return status;
}

int lstat64(const char *path, struct stat64 *info) {
    REAL(lstat64, const char *, struct stat64 *);
    int status = real_lstat64(path, info);
    if (status == 0) back_stat64(info);
    return status;
}

int fstat64(int file, struct stat64 *info) {
    REAL(fstat64, int, struct stat64 *);
    int status = real_fstat64(file, info);
    if (status == 0) back_stat64(info);
    return status;
}

int fstatat64(int dir, const char *path, struct stat64 *info, int flags) {
    REAL(fstatat64, int, const char *, struct stat64 *, int);
    int status = real_fstatat64(dir, path, info, flags);
    if (status == 0) back_stat64(info);
    return status;
}
