/* Shared scaffolding for the two differential translation units.
 *
 * portable/win/tests/gtk_differential.c compares the layout/geometry port
 * against portable/linux/gtk4/spdf_docview_internal.h;
 * portable/win/tests/gtk_differential_cache.c compares the rendered-page
 * cache against the same header's spdf_lru_*. They are one program, split
 * only because the repo caps a source file at 500 lines
 * (tools/file-size-limits.md) and the combined matrix outgrew it.
 *
 * The comparison primitives and the running totals live here so that "one
 * program, one verdict" survives the split: `main` refuses to report success
 * unless the whole matrix ran.
 */
#ifndef SPDF_GTK_DIFFERENTIAL_H
#define SPDF_GTK_DIFFERENTIAL_H

extern int spdf_diff_mismatches;
extern int spdf_diff_comparisons;

/* Exact equality, deliberately. The port is a transcription of the GTK4
 * implementation, so a result that differs by one ulp is still a transcription
 * error and not a rounding question. */
void spdf_diff_same_d(const char* what, double win, double gtk);
void spdf_diff_same_i(const char* what, long long win, long long gtk);
void spdf_diff_report(const char* what, const char* detail);

void differential_layout(void);
void differential_fit_and_cap(void);
void differential_zoom_anchor(void);
void differential_cache_recency(void);
void differential_cache(void);

#endif /* SPDF_GTK_DIFFERENTIAL_H */
