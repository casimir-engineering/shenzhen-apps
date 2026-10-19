#pragma once
#ifdef __cplusplus
extern "C" {
#endif
/* Source raster metadata only. No display-page units, inferred DPI, or decoded pixels. */
typedef struct spdf_image_properties {
    int width, height, components;
    char colorspace[128];
} spdf_image_properties;
int spdf_read_image_properties(const char* path, spdf_image_properties* properties);
#ifdef __cplusplus
}
#endif
