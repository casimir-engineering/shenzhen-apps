/* Fuzz target: the QOI decoder a friend's thumbnail reaches (szfriends_qoi.h), then what the helper does with the
 * pixels it accepts. Built with libFuzzer where the compiler has it, otherwise driven by szfriends_fuzz_driver.c;
 * always with AddressSanitizer and UndefinedBehaviorSanitizer (thumbnails.mk).
 *
 * Invariants beyond "no crash": a stream the decoder accepts re-encodes to a stream that decodes to the same pixels,
 * and its pixels make a PNG of exactly the promised size. A violation aborts, so the fuzzer records it as a crash. */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "service/thumbnails/szfriends_image.h"
#include "service/thumbnails/szfriends_qoi.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    szfriends_qoi_desc desc;
    /* The caps the helper uses (SZFriendsThumbnailMaxSide), so the fuzzer explores what a peer can reach. */
    if (!szfriends_qoi_read_header(data, size, 192, 192, &desc)) return 0;
    size_t rgba_size = (size_t)desc.width * desc.height * 4;
    uint8_t *rgba = malloc(rgba_size);
    if (rgba == NULL) abort();
    if (!szfriends_qoi_decode(data, size, &desc, rgba, rgba_size)) {
        free(rgba);
        return 0;
    }
    size_t worst = (size_t)desc.width * desc.height * 5 + SZFRIENDS_QOI_MIN_SIZE;
    uint8_t *again = malloc(worst);
    uint8_t *decoded = malloc(rgba_size);
    if (again == NULL || decoded == NULL) abort();
    size_t length = szfriends_qoi_encode(rgba, desc.width, desc.height, 4, again, worst);
    szfriends_qoi_desc second;
    if (length == 0 || !szfriends_qoi_read_header(again, length, 192, 192, &second) ||
        !szfriends_qoi_decode(again, length, &second, decoded, rgba_size) || memcmp(rgba, decoded, rgba_size) != 0) {
        abort();
    }
    size_t png_size = szfriends_png_size(desc.width, desc.height);
    uint8_t *png = malloc(png_size);
    if (png == NULL || szfriends_png_encode(rgba, desc.width, desc.height, png, png_size) != png_size) abort();
    free(png);
    free(decoded);
    free(again);
    free(rgba);
    return 0;
}
