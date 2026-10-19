/* spdf_win_toolchain_internal.h -- the two string helpers the toolchain's
 * pure translation units share (spdf_win_toolchain.cpp, _cmd.cpp, _plan.cpp).
 * Not part of the port's public surface; spdf_win_toolchain.h is. */
#ifndef SPDF_WIN_TOOLCHAIN_INTERNAL_H
#define SPDF_WIN_TOOLCHAIN_INTERNAL_H

#include <stddef.h>

/* Append s at `at` into out[cap], NUL-terminating and truncating to fit;
 * returns the position after s as if it all fit, so a caller can compare the
 * result against cap to detect truncation. */
size_t spdf_win_tc_put(char* out, size_t cap, size_t at, const char* s);
/* "<dir>\<leaf>" into out; 0 when dir is empty or it would not fit. */
int spdf_win_tc_join2(char* out, size_t cap, const char* dir, const char* leaf);

/* The short names the three units were written with. */
#define put spdf_win_tc_put
#define join2 spdf_win_tc_join2

#endif /* SPDF_WIN_TOOLCHAIN_INTERNAL_H */
