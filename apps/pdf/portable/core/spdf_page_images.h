#pragma once
/* Exact pixels for the assistant's Python (mac/SPDFMacAIPythonDocuments.h): the images a PDF page embeds, written at
 * their native resolution without resampling, and pages rendered to PNG at a chosen resolution. Each call opens the
 * document in a context of its own, so it may run on any thread. */
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spdf_page_image {
    int page;               /* zero-based page the image is drawn on */
    int index;              /* one-based order among that page's images */
    int width, height;      /* native pixels */
    int components;         /* colour components of the written file, without alpha */
    int alpha;              /* 1 when the written file has an alpha channel */
    int bits_per_component; /* of the source image; the written file has 8 */
    int has_mask;           /* the PDF also gives it a soft or stencil mask, which is not applied */
    int lossless;           /* the file holds exactly the source's samples (or its original JPEG bytes) */
    char colorspace[64];    /* the source's colour space name */
    char encoding[16];      /* the source's compression: "flate", "jpeg", "jpx", ... */
    char file[128];         /* the file's name inside out_dir: page-4-image-1.png, page-2-image-1.jpg */
} spdf_page_image;

typedef struct spdf_page_images {
    spdf_page_image* items;
    int count;
    int skipped; /* images beyond max_images or the pixel budget, not written */
} spdf_page_images;

/* Writes every image drawn on the listed zero-based pages into out_dir (which must exist): a JPEG as its original
 * bytes, anything else decoded at full resolution as PNG, gray or RGB with the source's values (CMYK, Lab and spot
 * colours are converted to RGB, and lossless is then 0). An image used on several of the pages is written once and
 * listed for each. Stops before an image that would pass max_images or max_pixels in all; *cancel nonzero stops it
 * between images. Returns 0, or -1 with err. */
int spdf_extract_page_images(const char* path, const int* pages, int page_count, const char* out_dir, int max_images,
                             long long max_pixels, volatile int* cancel, spdf_page_images* out, char* err,
                             size_t err_len);
void spdf_free_page_images(spdf_page_images* images);

typedef struct spdf_page_render {
    int page;          /* zero-based */
    int width, height; /* pixels */
    char file[128];    /* page-4-150dpi.png */
} spdf_page_render;

/* Renders each listed zero-based page to out_dir/page-<n>-<dpi>dpi.png, RGB without alpha on white, with annotations.
 * A page whose render would pass max_pixels fails the call. Returns 0, or -1 with err. */
int spdf_render_pages_png(const char* path, const int* pages, int page_count, int dpi, const char* out_dir,
                          long long max_pixels, volatile int* cancel, spdf_page_render* out, char* err,
                          size_t err_len);

/* The document's page count, or -1 with err (also for a document that needs a password). */
int spdf_document_page_count(const char* path, char* err, size_t err_len);

#ifdef __cplusplus
}
#endif
