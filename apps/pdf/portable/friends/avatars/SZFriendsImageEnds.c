/* End-of-file checks for PNG, HEIC/HEIF and WebP. See SZFriendsImageBytes.h for why they exist. */

#include "avatars/SZFriendsImageBytes.h"

#include <string.h>

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

int szfriends_png_is_complete(const uint8_t *bytes, size_t length) {
    /* The IEND chunk is always these 12 bytes: zero length, the type, and the CRC of the type. */
    static const uint8_t iend[12] = {0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xAE, 0x42, 0x60, 0x82};
    static const uint8_t signature[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    if (!bytes || length < sizeof signature + sizeof iend || memcmp(bytes, signature, sizeof signature) != 0) {
        return 0;
    }
    for (size_t i = sizeof signature; i + sizeof iend <= length; i++) {
        if (bytes[i + 4] == 'I' && memcmp(bytes + i, iend, sizeof iend) == 0) return 1;
    }
    return 0;
}

int szfriends_bmff_is_complete(const uint8_t *bytes, size_t length) {
    if (!bytes || length < 8) return 0;
    size_t offset = 0;
    while (offset < length) {
        if (length - offset < 8) return 0;
        uint64_t size = read_be32(bytes + offset);
        size_t header = 8;
        if (size == 1) {
            /* A 64-bit size follows the type. */
            if (length - offset < 16) return 0;
            size = ((uint64_t)read_be32(bytes + offset + 8) << 32) | read_be32(bytes + offset + 12);
            header = 16;
        } else if (size == 0) {
            return 1; /* The last box runs to the end of the file. */
        }
        if (size < header || size > length - offset) return 0;
        offset += (size_t)size;
    }
    return 1;
}

int szfriends_webp_is_complete(const uint8_t *bytes, size_t length) {
    if (!bytes || length < 12 || memcmp(bytes, "RIFF", 4) != 0 || memcmp(bytes + 8, "WEBP", 4) != 0) return 0;
    uint32_t declared = (uint32_t)bytes[4] | ((uint32_t)bytes[5] << 8) | ((uint32_t)bytes[6] << 16) |
                        ((uint32_t)bytes[7] << 24);
    return (uint64_t)declared + 8 <= length;
}
