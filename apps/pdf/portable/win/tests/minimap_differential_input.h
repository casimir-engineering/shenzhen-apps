/* The input-policy section of minimap_differential.c, included by it at the
 * bottom -- after the fixtures, the comparators and the counters it uses -- so
 * the program stays one binary and one verdict while each file stays under the
 * repo's 500-line cap (tools/file-size-limits.md). Not a translation unit of its
 * own: it reads the .c file's statics. See minimap_differential.c's header for
 * what a differential is and how to judge it.
 */

/* --------------------------------------------------------------------------
 * The input policy, spdf_win_search_map_input.h: strip-scroll, the
 * discrete-wheel page cap and the long-document drag. Driven over the same
 * documents and layouts as the mapping section, at many scroll positions,
 * gesture distances and viewport heights, so the clamps at both ends of the
 * document and the fits-in-panel fallback are all reached. */
static void differential_input_policy(void) {
    SpdfMinimapStrip gtk;
    SpdfWinMinimapStrip win;
    double doc_y[MAX_PAGES], doc_h[MAX_PAGES];
    static const double kStripDy[] = {-500.0, -32.0, -7.5, -0.5, 0.0, 0.5, 7.5, 32.0, 64.0, 500.0, 1e-5};
    static const double kVisH[] = {700.0, 300.0, 5000.0, 1.0};
    static const double kAvail[] = {784.0, 24.0, 2000.0, 1.0};
    int d, i, s, v, a, step, page;
    char label[224];

    memset(&gtk, 0, sizeof(gtk));
    memset(&win, 0, sizeof(win));
    for (d = 0; d < kDocCount; ++d) {
        double y = 13.0, doc_total;
        set_sizes(kDocs[d].wh, kDocs[d].count);
        spdf_minimap_strip_compute(&gtk, g_gtk_sizes, kDocs[d].count, 126.5);
        spdf_win_minimap_strip_compute(&win, g_win_sizes, kDocs[d].count, 126.5, SPDF_WIN_MINIMAP_SIDE_INSET,
                                       SPDF_WIN_MINIMAP_GAP);
        for (i = 0; i < kDocs[d].count; ++i) {
            doc_h[i] = g_gtk_sizes[i].height * 1.2;
            doc_y[i] = y;
            y += doc_h[i] + 26.0;
        }
        doc_total = y;
        for (s = 0; s < (int)(sizeof(kStripDy) / sizeof(kStripDy[0])); ++s) {
            for (v = 0; v < (int)(sizeof(kVisH) / sizeof(kVisH[0])); ++v) {
                for (a = 0; a < (int)(sizeof(kAvail) / sizeof(kAvail[0])); ++a) {
                    sprintf(label, "strip_delta[%s][dy=%g][vis=%g][avail=%g]", kDocs[d].name, kStripDy[s], kVisH[v],
                            kAvail[a]);
                    same_d(label,
                           spdf_win_minimap_document_delta_for_strip_scroll(kStripDy[s], win.content_h, kAvail[a],
                                                                            doc_total, kVisH[v]),
                           spdf_minimap_document_delta_for_strip_scroll(kStripDy[s], gtk.content_h, kAvail[a],
                                                                        doc_total, kVisH[v]));
                    for (step = -1; step < 6; ++step) {
                        double top = (double)step * (doc_total / 4.0);
                        double wt, gt;
                        sprintf(label, "strip_top[%s][dy=%g][vis=%g][avail=%g][top=%g]", kDocs[d].name, kStripDy[s],
                                kVisH[v], kAvail[a], top);
                        wt = spdf_win_minimap_document_top_for_strip_scroll(top, kStripDy[s], win.content_h,
                                                                            kAvail[a], doc_total, kVisH[v]);
                        gt = spdf_minimap_document_top_for_strip_scroll(top, kStripDy[s], gtk.content_h, kAvail[a],
                                                                        doc_total, kVisH[v]);
                        same_d(label, wt, gt);
                        for (page = -1; page <= kDocs[d].count; ++page) {
                            sprintf(label, "wheel_cap[%s][dy=%g][vis=%g][top=%g][page=%d]", kDocs[d].name,
                                    kStripDy[s], kVisH[v], top, page);
                            same_d(label,
                                   spdf_win_minimap_document_top_capped_for_discrete_wheel(
                                       top, wt, page, doc_y, doc_h, kDocs[d].count, doc_total, kVisH[v]),
                                   spdf_minimap_document_top_capped_for_discrete_wheel(
                                       top, gt, page, doc_y, doc_h, kDocs[d].count, doc_total, kVisH[v]));
                        }
                    }
                }
            }
        }
        for (page = -2; page <= kDocs[d].count + 1; ++page) {
            static const double kDeltas[] = {-3000.0, -1.0, -0.00005, 0.0, 0.00005, 1.0, 3000.0};
            int k;
            for (k = 0; k < 7; ++k) {
                sprintf(label, "stride[%s][page=%d][delta=%g]", kDocs[d].name, page, kDeltas[k]);
                same_d(label,
                       spdf_win_minimap_directional_page_stride(page, kDeltas[k], doc_y, doc_h, kDocs[d].count),
                       spdf_minimap_directional_page_stride(page, kDeltas[k], doc_y, doc_h, kDocs[d].count));
            }
        }
        sprintf(label, "total_height[%s]", kDocs[d].name);
        same_d(label, spdf_win_minimap_total_height_pt(g_win_sizes, kDocs[d].count),
               spdf_minimap_total_height_pt(g_gtk_sizes, kDocs[d].count));
        sprintf(label, "long_drag[%s]", kDocs[d].name);
        same_i(label, spdf_win_minimap_use_long_document_drag(g_win_sizes, kDocs[d].count),
               spdf_minimap_use_long_document_drag(g_gtk_sizes, kDocs[d].count));
    }
    /* NULL arrays and the degenerate stride inputs. */
    same_d("stride[null]", spdf_win_minimap_directional_page_stride(0, 5.0, NULL, NULL, 3),
           spdf_minimap_directional_page_stride(0, 5.0, NULL, NULL, 3));
    same_d("total_height[null]", spdf_win_minimap_total_height_pt(NULL, 3), spdf_minimap_total_height_pt(NULL, 3));

    /* The long-document drag scale over speeds either side of both thresholds,
     * frame times inside and outside the clamp, and page counts across the
     * 20/page_count clamp -- plus the thumb height against several tracks. */
    {
        static const double kDy[] = {-40.0, -3.0, 0.0, 0.5, 1.0, 3.0, 6.0, 40.0, 400.0};
        static const double kDt[] = {-1.0, 0.0, 1.0 / 1000.0, 1.0 / 240.0, 1.0 / 120.0, 1.0 / 60.0, 1.0 / 15.0,
                                     0.5, 1e300 * 1e300};
        static const int kPages[] = {-5, 0, 1, 19, 20, 27, 28, 66, 67, 500};
        int a2, b, c;
        for (a2 = 0; a2 < 9; ++a2)
            for (b = 0; b < 9; ++b)
                for (c = 0; c < 10; ++c) {
                    sprintf(label, "long_drag_scale[dy=%g][dt=%g][pages=%d]", kDy[a2], kDt[b], kPages[c]);
                    same_d(label, spdf_win_minimap_long_drag_scale(kDy[a2], kDt[b], kPages[c]),
                           spdf_minimap_long_drag_scale(kDy[a2], kDt[b], kPages[c]));
                }
        for (a2 = 0; a2 < 9; ++a2) {
            sprintf(label, "smoothstep[%g]", kDy[a2] / 10.0);
            same_d(label, spdf_win_minimap_smoothstep(kDy[a2] / 10.0), spdf_minimap_smoothstep(kDy[a2] / 10.0));
        }
        for (a2 = 0; a2 < 4; ++a2)
            for (b = 0; b < 4; ++b)
                for (c = 0; c < 4; ++c) {
                    sprintf(label, "thumb_h[vis=%g][doc=%g][track=%g]", kVisH[a2], kVisH[b] * 7.0, kAvail[c]);
                    same_d(label, spdf_win_minimap_drag_thumb_height(kVisH[a2], kVisH[b] * 7.0, kAvail[c]),
                           spdf_minimap_drag_thumb_height(kVisH[a2], kVisH[b] * 7.0, kAvail[c]));
                }
    }
    same_d("const.LONG_DOC_HEIGHT_PT", SPDF_WIN_MINIMAP_LONG_DOC_HEIGHT_PT, SPDF_MINIMAP_LONG_DOC_HEIGHT_PT);
    same_d("const.DRAG_FINE_SPEED", SPDF_WIN_MINIMAP_DRAG_FINE_SPEED, SPDF_MINIMAP_DRAG_FINE_SPEED);
    same_d("const.DRAG_FULL_SPEED", SPDF_WIN_MINIMAP_DRAG_FULL_SPEED, SPDF_MINIMAP_DRAG_FULL_SPEED);
    same_d("const.WHEEL_POINTS_PER_LINE", SPDF_WIN_MINIMAP_WHEEL_POINTS_PER_LINE, SPDF_MINIMAP_WHEEL_POINTS_PER_LINE);
    spdf_minimap_strip_clear(&gtk);
    spdf_win_minimap_strip_clear(&win);
}

