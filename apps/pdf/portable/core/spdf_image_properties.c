#include "spdf_image_properties.h"
#include "mupdf/fitz.h"
#include <stdio.h>
#include <string.h>

int spdf_read_image_properties(const char* path, spdf_image_properties* properties) {
    if (!path || !properties) return 0;
    memset(properties, 0, sizeof(*properties));
    fz_context* context = fz_new_context(NULL, NULL, 0);
    if (!context) return 0;
    fz_image* image = NULL;
    int success = 0;
    fz_var(image);
    fz_var(success);
    fz_try(context) {
        /* May read file payloads; never request a rendered pixmap for metadata. */
        image = fz_new_image_from_file(context, path);
        properties->width = image->w;
        properties->height = image->h;
        if (image->colorspace) {
            properties->components = fz_colorspace_n(context, image->colorspace);
            snprintf(properties->colorspace, sizeof(properties->colorspace), "%s",
                     fz_colorspace_name(context, image->colorspace));
        }
        success = image->w > 0 && image->h > 0;
    }
    fz_always(context) { fz_drop_image(context, image); }
    fz_catch(context) { success = 0; }
    fz_drop_context(context);
    return success;
}
