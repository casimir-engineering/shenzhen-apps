// Big-endian integers in the fast transfers' encodings (SZFriendsTransferBlocks.m, SZFriendsBlockSidecars.m).

#import <stdint.h>

static inline uint32_t SZFriendsU32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
}

static inline void SZFriendsPutU32(uint8_t out[4], uint32_t value) {
    out[0] = (uint8_t)(value >> 24);
    out[1] = (uint8_t)(value >> 16);
    out[2] = (uint8_t)(value >> 8);
    out[3] = (uint8_t)value;
}

static inline void SZFriendsPutU64(uint8_t out[8], uint64_t value) {
    for (int i = 7; i >= 0; i--, value >>= 8) out[i] = (uint8_t)value;
}
