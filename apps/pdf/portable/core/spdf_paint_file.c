/* Annotate's files (docs/plans/annotate.md § 5, § 8 Core spdf_paint_file.c): .szpaint projects (a ZIP written with
 * MuPDF's fz_zip_writer: manifest.json plus one PNG per raster layer and Picture object; shapes and text stored as
 * parameters and drawn again on load), the flattened picture the frontend encodes into the file, PNGs for doc.render,
 * and the doc.render handler.
 *
 * WAVE 0 STUB (Core A implements): every function answers SPDF_PAINT_ERR_NOT_IMPLEMENTED or does nothing. */
#include "spdf_paint_handlers.h"

spdf_paint_status spdf_paint_flatten(spdf_paint_doc* doc, spdf_paint_color matte, spdf_bitmap* out, char* err,
                                     size_t err_len) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(matte); SPDF_PAINT_UNUSED(out);
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

spdf_paint_status spdf_paint_write_project(spdf_paint_doc* doc, const char* path, char* err, size_t err_len) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(path);
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

spdf_paint_doc* spdf_paint_read_project(const char* path, char* err, size_t err_len) {
    SPDF_PAINT_UNUSED(path);
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return NULL;
}

spdf_paint_status spdf_paint_project_bytes(spdf_paint_doc* doc, unsigned char** out, size_t* out_len, char* err,
                                           size_t err_len) {
    SPDF_PAINT_UNUSED(doc);
    if (out) *out = NULL;
    if (out_len) *out_len = 0;
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

spdf_paint_status spdf_paint_render_png(spdf_paint_doc* doc, const spdf_paint_render_options* options,
                                        const char* path, char* err, size_t err_len) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(options); SPDF_PAINT_UNUSED(path);
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

SPDF_PAINT_STUB_HANDLER(spdf_paint_op_doc_render)
