/* Camera RAW photos shown as pictures: see spdf_camera_raw.h. */
#include "spdf_camera_raw.h"
#include "spdf_core_document.h"

#include <stdint.h>
#include <string.h>

static const char* const raw_extensions[] = {"cr2", "cr3", "crw", "nef", "nrw", "arw", "sr2", "srf", "orf",
                                             "raf", "rw2", "rwl", "pef", "dng", "srw", "3fr", "fff", "iiq",
                                             "x3f"};

static spdf_camera_raw_decoder full_decoder;

int spdf_camera_raw_path(const char* path) {
    const char* dot = NULL;
    const char* p;
    size_t i;
    if (!path) return 0;
    for (p = path; *p; ++p) {
        if (*p == '/' || *p == '\\')
            dot = NULL;
        else if (*p == '.')
            dot = p;
    }
    if (!dot) return 0;
    for (i = 0; i < sizeof(raw_extensions) / sizeof(raw_extensions[0]); ++i) {
        const char* want = raw_extensions[i];
        const char* have = dot + 1;
        while (*want && *have) {
            char a = *have >= 'A' && *have <= 'Z' ? (char)(*have + 32) : *have;
            if (a != *want) break;
            ++want;
            ++have;
        }
        if (!*want && !*have) return 1;
    }
    return 0;
}

static unsigned be16(const unsigned char* p) { return (unsigned)p[0] << 8 | p[1]; }

static unsigned get16(const unsigned char* p, int big) { return big ? be16(p) : (unsigned)p[1] << 8 | p[0]; }

static uint32_t get32(const unsigned char* p, int big) {
    return big ? (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]
               : (uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0];
}

/* The EXIF orientation (1-8) in the first IFD of a TIFF-shaped header at base, or 0. Covers plain TIFF (CR2, NEF,
 * ARW, PEF, DNG, SRW, 3FR, IIQ), Panasonic's "IIU" and Olympus's "IIRO"/"IIRS"/"MMOR" variants. */
static int tiff_orientation(const unsigned char* d, size_t n, size_t base) {
    int big;
    unsigned magic, count, i;
    uint32_t ifd;
    if (base + 8 > n) return 0;
    if (d[base] == 'I' && d[base + 1] == 'I')
        big = 0;
    else if (d[base] == 'M' && d[base + 1] == 'M')
        big = 1;
    else
        return 0;
    magic = get16(d + base + 2, big);
    if (magic != 42 && magic != 0x55 && magic != 0x4f52 && magic != 0x5352) return 0;
    ifd = get32(d + base + 4, big);
    if (ifd < 8 || ifd > n - base - 2) return 0;
    count = get16(d + base + ifd, big);
    for (i = 0; i < count && i < 512; ++i) {
        size_t entry = base + ifd + 2 + (size_t)i * 12;
        if (entry + 12 > n) return 0;
        if (get16(d + entry, big) == 0x112 && get16(d + entry + 2, big) == 3) {
            unsigned value = get16(d + entry + 8, big);
            return value >= 1 && value <= 8 ? (int)value : 0;
        }
    }
    return 0;
}

static size_t find_bytes(const unsigned char* d, size_t n, size_t from, size_t limit, const char* what, size_t len) {
    size_t i;
    if (limit > n) limit = n;
    for (i = from; i + len <= limit; ++i)
        if (d[i] == (unsigned char)what[0] && !memcmp(d + i, what, len)) return i;
    return (size_t)-1;
}

/* The photo's orientation as the camera recorded it, or 0 when the container keeps none we read (Fujifilm and
 * Sigma keep it in the preview's own EXIF, which the picture reader honours). */
static int raw_orientation(const unsigned char* d, size_t n) {
    int o = tiff_orientation(d, n, 0);
    if (o) return o;
    if (n > 12 && !memcmp(d + 4, "ftypcrx ", 8)) { /* Canon CR3: the TIFF of IFD0 sits in the CMT1 box */
        size_t at = find_bytes(d, n, 0, 1 << 20, "CMT1", 4);
        if (at != (size_t)-1) return tiff_orientation(d, n, at + 4);
    }
    return 0;
}

/* A complete baseline or progressive JPEG starting at d[start] (FF D8): its end and size, or 0. Lossless JPEG
 * (the RAW data itself in CR2 and DNG files) and JPEGs cut short are not previews. */
static int jpeg_at(const unsigned char* d, size_t n, size_t start, size_t* end, int* width, int* height) {
    size_t pos = start + 2;
    int have_frame = 0, have_scan = 0;
    while (pos + 2 <= n) { /* a preview often ends the file: its EOI is the last two bytes */
        unsigned marker, len;
        if (d[pos] != 0xff) return 0;
        while (pos + 2 < n && d[pos + 1] == 0xff) ++pos;
        marker = d[pos + 1];
        pos += 2;
        if (marker == 0xd9) {
            if (!have_frame || !have_scan) return 0;
            *end = pos;
            return 1;
        }
        if (marker == 0xd8 || marker == 0x00) return 0;
        if ((marker >= 0xd0 && marker <= 0xd7) || marker == 0x01) continue;
        if (pos + 2 > n) return 0;
        len = be16(d + pos);
        if (len < 2 || pos + len > n) return 0;
        if (marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc) {
            int components;
            if (marker > 0xc2 || len < 8 || have_frame) return 0;
            components = d[pos + 7];
            if (d[pos + 2] != 8 || (components != 1 && components != 3)) return 0;
            *height = (int)be16(d + pos + 3);
            *width = (int)be16(d + pos + 5);
            if (*width < 1 || *height < 1) return 0;
            have_frame = 1;
        }
        pos += len;
        if (marker == 0xda) {
            if (!have_frame) return 0;
            have_scan = 1;
            /* Entropy-coded data runs to the next marker: FF followed by neither a stuffed 00 nor a restart. */
            while (pos + 1 < n &&
                   !(d[pos] == 0xff && d[pos + 1] != 0x00 && d[pos + 1] != 0xff && (d[pos + 1] < 0xd0 || d[pos + 1] > 0xd7)))
                ++pos;
            if (pos + 1 >= n) return 0;
        }
    }
    return 0;
}

/* The largest preview in the file: its offset and length, or 0. */
static int largest_jpeg(const unsigned char* d, size_t n, size_t* best_start, size_t* best_len) {
    size_t pos = 0, end;
    int64_t best_area = 0;
    int width, height, attempts = 0;
    while (pos + 3 < n && attempts < 4096) {
        const unsigned char* hit = (const unsigned char*)memchr(d + pos, 0xff, n - pos - 3);
        if (!hit) break;
        pos = (size_t)(hit - d);
        if (d[pos + 1] == 0xd8 && d[pos + 2] == 0xff) {
            ++attempts;
            if (jpeg_at(d, n, pos, &end, &width, &height)) {
                if ((int64_t)width * height > best_area) {
                    best_area = (int64_t)width * height;
                    *best_start = pos;
                    *best_len = end - pos;
                }
                pos = end; /* the thumbnail inside a preview's EXIF is smaller: skip it */
                continue;
            }
        }
        ++pos;
    }
    return best_area > 0;
}

/* The preview with an EXIF orientation segment of its own in front, which the picture reader reads (it honours the
 * first EXIF segment). The camera's previews are stored as the sensor saw them. */
static fz_buffer* upright_jpeg(fz_context* ctx, const unsigned char* jpeg, size_t len, int orientation) {
    static const unsigned char exif_head[] = {0xff, 0xe1, 0x00, 0x22, 'E', 'x', 'i', 'f', 0, 0, 'M', 'M', 0, 42,
                                              0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1};
    fz_buffer* out = fz_new_buffer(ctx, len + 64);
    fz_try(ctx) {
        fz_append_data(ctx, out, jpeg, 2); /* SOI */
        if (orientation) {
            unsigned char tail[8] = {0, (unsigned char)orientation, 0, 0, 0, 0, 0, 0};
            fz_append_data(ctx, out, exif_head, sizeof(exif_head));
            fz_append_data(ctx, out, tail, sizeof(tail));
        }
        fz_append_data(ctx, out, jpeg + 2, len - 2);
    }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, out);
        fz_rethrow(ctx);
    }
    return out;
}

/* What the reader is told when nothing can be shown. Without a full decoder (Linux, Windows) the preview is all
 * ShenzhenPDF shows; with one (the Mac) the preview was the fallback after macOS could not read the file. */
static const char* const no_preview_message =
    "This RAW photo can't be shown. ShenzhenPDF shows the preview picture cameras save inside RAW files, and this "
    "file has none it can read; it may be damaged or incomplete.";
static const char* const unreadable_message =
    "This RAW photo can't be shown. The file may be damaged or incomplete, or macOS can't read RAW photos from this "
    "camera yet.";

static fz_document* open_preview(fz_context* ctx, const char* path, const char* failure) {
    fz_stream* stm = NULL;
    fz_buffer* data = NULL;
    fz_buffer* picture = NULL;
    fz_document* doc = NULL;
    int64_t size;
    size_t start = 0, len = 0;
    int read = 0;

    fz_var(stm);
    fz_var(data);
    fz_var(picture);
    fz_var(doc);
    fz_var(read);
    fz_try(ctx) {
        stm = fz_open_file(ctx, path);
        fz_seek(ctx, stm, 0, SEEK_END);
        size = fz_tell(ctx, stm);
        fz_seek(ctx, stm, 0, SEEK_SET);
        data = fz_read_all(ctx, stm, size > 0 ? (size_t)size : 0);
        read = 1;
        if (!largest_jpeg(data->data, data->len, &start, &len)) fz_throw(ctx, FZ_ERROR_FORMAT, "%s", failure);
        picture = upright_jpeg(ctx, data->data + start, len, raw_orientation(data->data, data->len));
        fz_drop_buffer(ctx, data);
        data = NULL;
        doc = fz_open_document_with_buffer(ctx, "image/jpeg", picture);
        if (fz_count_pages(ctx, doc) < 1) fz_throw(ctx, FZ_ERROR_FORMAT, "%s", failure);
    }
    fz_always(ctx) {
        fz_drop_stream(ctx, stm);
        fz_drop_buffer(ctx, data);
        fz_drop_buffer(ctx, picture);
    }
    fz_catch(ctx) {
        fz_drop_document(ctx, doc);
        /* A file that could not be read keeps the system's reason; anything after that is the file's contents. */
        if (!read || fz_caught(ctx) == FZ_ERROR_SYSTEM) fz_rethrow(ctx);
        if (strcmp(fz_caught_message(ctx), failure) != 0) fz_report_error(ctx); /* MuPDF's own, for the log */
        else fz_ignore_error(ctx);
        fz_throw(ctx, FZ_ERROR_FORMAT, "%s", failure);
    }
    return doc;
}

static fz_document* open_hook(fz_context* ctx, const char* path) {
    fz_document* doc = NULL;
    if (!spdf_camera_raw_path(path)) return NULL;
    if (!full_decoder) return open_preview(ctx, path, no_preview_message);
    fz_var(doc);
    fz_try(ctx) {
        doc = full_decoder(ctx, path);
    }
    fz_catch(ctx) {
        fz_report_error(ctx);
        doc = NULL;
    }
    return doc ? doc : open_preview(ctx, path, unreadable_message);
}

void spdf_camera_raw_install(spdf_camera_raw_decoder decoder) {
    full_decoder = decoder;
    spdf_core_add_open_hook(open_hook);
}
