// STUN Binding codec (SZFriendsNATStun.h). Plain C functions in an Objective-C file, so the fuzz target and the
// tests link it like any other service source.

#import "service/online/nat/SZFriendsNATStun.h"

#include <CommonCrypto/CommonHMAC.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>

enum {
    kMagicCookie = 0x2112a442,
    kFingerprintXor = 0x5354554e,
    kAttrMappedAddress = 0x0001,
    kAttrUsername = 0x0006,
    kAttrMessageIntegrity = 0x0008,
    kAttrErrorCode = 0x0009,
    kAttrUseCandidate = 0x0025,
    kAttrXorMappedAddress = 0x0020,
    kAttrFingerprint = 0x8028,
    kIntegrityLength = 20,
    kUsernameReadMax = 513, // RFC 8489 § 14.3
};

static uint16_t Read16(const uint8_t *p) {
    return (uint16_t)((p[0] << 8) | p[1]);
}

static uint32_t Read32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static void Write16(uint8_t *p, uint16_t value) {
    p[0] = (uint8_t)(value >> 8);
    p[1] = (uint8_t)value;
}

static void Write32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)(value >> 24);
    p[1] = (uint8_t)(value >> 16);
    p[2] = (uint8_t)(value >> 8);
    p[3] = (uint8_t)value;
}

uint32_t SZFriendsStunCRC32(const uint8_t *bytes, size_t length) {
    uint32_t crc = 0xffffffffu;
    for (size_t i = 0; i < length; i++) {
        crc ^= bytes[i];
        for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

void SZFriendsStunRandomTransaction(uint8_t transaction[12]) {
    arc4random_buf(transaction, SZFriendsStunTransactionLength);
}

// The address attributes: family 1 with 4 bytes or family 2 with 16, exactly. XOR applies the cookie and, for IPv6,
// the transaction id. NO rejects the message.
static BOOL ParseAddress(const uint8_t *value, size_t length, BOOL xored, const uint8_t *header,
                         SZFriendsStunMessage *message) {
    if (length < 4 || value[0] != 0) return NO;
    uint16_t port = Read16(value + 2);
    if (xored) port ^= (uint16_t)(kMagicCookie >> 16);
    memset(&message->mappedAddress, 0, sizeof message->mappedAddress);
    if (value[1] == 0x01 && length == 8) {
        struct sockaddr_in *in = (struct sockaddr_in *)&message->mappedAddress;
        in->sin_len = sizeof *in;
        in->sin_family = AF_INET;
        in->sin_port = htons(port);
        uint8_t raw[4];
        for (int i = 0; i < 4; i++) raw[i] = value[4 + i] ^ (xored ? header[4 + i] : 0);
        memcpy(&in->sin_addr, raw, 4);
        message->mappedAddressLength = sizeof *in;
    } else if (value[1] == 0x02 && length == 20) {
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)&message->mappedAddress;
        in6->sin6_len = sizeof *in6;
        in6->sin6_family = AF_INET6;
        in6->sin6_port = htons(port);
        uint8_t raw[16];
        for (int i = 0; i < 16; i++) raw[i] = value[4 + i] ^ (xored ? header[4 + i] : 0); // cookie || transaction
        memcpy(&in6->sin6_addr, raw, 16);
        message->mappedAddressLength = sizeof *in6;
    } else {
        return NO;
    }
    message->hasMappedAddress = YES;
    return YES;
}

BOOL SZFriendsStunParse(const uint8_t *bytes, size_t length, SZFriendsStunMessage *message) {
    if (bytes == NULL || message == NULL) return NO;
    memset(message, 0, sizeof *message);
    if (length < SZFriendsStunHeaderLength || length > SZFriendsStunMessageMax) return NO;
    if ((bytes[0] & 0xc0) != 0 || Read32(bytes + 4) != kMagicCookie) return NO;
    size_t bodyLength = Read16(bytes + 2);
    if (bodyLength % 4 != 0 || bodyLength + SZFriendsStunHeaderLength != length) return NO;
    message->type = Read16(bytes);
    memcpy(message->transaction, bytes + 8, SZFriendsStunTransactionLength);

    BOOL sawXorMapped = NO, sawMapped = NO, sawUsername = NO, sawError = NO;
    size_t at = SZFriendsStunHeaderLength;
    while (at < length) {
        if (length - at < 4) return NO;
        uint16_t type = Read16(bytes + at);
        size_t valueLength = Read16(bytes + at + 2);
        size_t padded = (valueLength + 3) & ~(size_t)3;
        if (padded > length - at - 4) return NO;
        const uint8_t *value = bytes + at + 4;
        if (message->hasFingerprint) return NO; // FINGERPRINT must be the last attribute
        if (type == kAttrFingerprint) {
            if (valueLength != 4) return NO;
            uint32_t expected = SZFriendsStunCRC32(bytes, at) ^ kFingerprintXor;
            // The CRC covers the header with its length field as sent, which already counts FINGERPRINT.
            if (Read32(value) != expected) return NO;
            message->hasFingerprint = YES;
        } else if (message->hasIntegrity) {
            // RFC 8489 § 14.5: everything between MESSAGE-INTEGRITY and FINGERPRINT is ignored.
        } else if (type == kAttrMessageIntegrity) {
            if (valueLength != kIntegrityLength) return NO;
            message->hasIntegrity = YES;
            message->integrityOffset = at;
        } else if (type == kAttrXorMappedAddress && !sawXorMapped) {
            sawXorMapped = YES;
            if (!ParseAddress(value, valueLength, YES, bytes, message)) return NO;
        } else if (type == kAttrMappedAddress && !sawMapped) {
            sawMapped = YES;
            if (!sawXorMapped) {
                if (!ParseAddress(value, valueLength, NO, bytes, message)) return NO;
            }
        } else if (type == kAttrUsername && !sawUsername) {
            sawUsername = YES;
            if (valueLength == 0 || valueLength > kUsernameReadMax) return NO;
            message->username = value;
            message->usernameLength = valueLength;
        } else if (type == kAttrUseCandidate) {
            if (valueLength != 0) return NO;
            message->useCandidate = YES;
        } else if (type == kAttrErrorCode && !sawError) {
            sawError = YES;
            if (valueLength < 4) return NO;
            unsigned errorClass = value[2] & 0x07, number = value[3];
            if (errorClass < 3 || errorClass > 6 || number > 99) return NO;
            message->errorCode = (uint16_t)(errorClass * 100 + number);
        }
        at += 4 + padded;
    }
    return YES;
}

static BOOL ConstantTimeEqual(const uint8_t *a, const uint8_t *b, size_t length) {
    uint8_t difference = 0;
    for (size_t i = 0; i < length; i++) difference |= a[i] ^ b[i];
    return difference == 0;
}

// HMAC-SHA1 over the message up to the MESSAGE-INTEGRITY attribute at `offset`, with the header's length field set as
// if that attribute ended the message (RFC 8489 § 14.5).
static void ComputeIntegrity(const uint8_t *bytes, size_t offset, const uint8_t *key, size_t keyLength,
                             uint8_t out[CC_SHA1_DIGEST_LENGTH]) {
    uint8_t header[SZFriendsStunHeaderLength];
    memcpy(header, bytes, sizeof header);
    Write16(header + 2, (uint16_t)(offset - SZFriendsStunHeaderLength + 4 + kIntegrityLength));
    CCHmacContext context;
    CCHmacInit(&context, kCCHmacAlgSHA1, key, keyLength);
    CCHmacUpdate(&context, header, sizeof header);
    CCHmacUpdate(&context, bytes + SZFriendsStunHeaderLength, offset - SZFriendsStunHeaderLength);
    CCHmacFinal(&context, out);
}

BOOL SZFriendsStunCheckIntegrity(const uint8_t *bytes, size_t length, const SZFriendsStunMessage *message,
                                 const uint8_t *key, size_t keyLength) {
    if (bytes == NULL || message == NULL || key == NULL || keyLength == 0 || !message->hasIntegrity) return NO;
    if (message->integrityOffset + 4 + kIntegrityLength > length) return NO;
    uint8_t expected[CC_SHA1_DIGEST_LENGTH];
    ComputeIntegrity(bytes, message->integrityOffset, key, keyLength, expected);
    return ConstantTimeEqual(expected, bytes + message->integrityOffset + 4, kIntegrityLength);
}

// Appends one attribute with zero padding; NO when it does not fit.
static BOOL AppendAttribute(uint8_t *out, size_t capacity, size_t *at, uint16_t type, const void *value,
                            size_t valueLength) {
    size_t padded = (valueLength + 3) & ~(size_t)3;
    if (*at + 4 + padded > capacity) return NO;
    Write16(out + *at, type);
    Write16(out + *at + 2, (uint16_t)valueLength);
    if (valueLength > 0) memcpy(out + *at + 4, value, valueLength);
    memset(out + *at + 4 + valueLength, 0, padded - valueLength);
    *at += 4 + padded;
    return YES;
}

// Finishes a message: MESSAGE-INTEGRITY when keyed, then FINGERPRINT, each over the header as it will be sent.
static size_t Finish(uint8_t *out, size_t capacity, size_t at, const uint8_t *key, size_t keyLength) {
    if (key != NULL && keyLength > 0) {
        if (at + 4 + kIntegrityLength > capacity) return 0;
        uint8_t mac[CC_SHA1_DIGEST_LENGTH];
        ComputeIntegrity(out, at, key, keyLength, mac);
        if (!AppendAttribute(out, capacity, &at, kAttrMessageIntegrity, mac, kIntegrityLength)) return 0;
    }
    if (at + 8 > capacity) return 0;
    Write16(out + 2, (uint16_t)(at + 8 - SZFriendsStunHeaderLength));
    uint8_t crc[4];
    Write32(crc, SZFriendsStunCRC32(out, at) ^ kFingerprintXor);
    if (!AppendAttribute(out, capacity, &at, kAttrFingerprint, crc, sizeof crc)) return 0;
    return at;
}

static size_t WriteHeader(uint8_t *out, size_t capacity, uint16_t type, const uint8_t transaction[12]) {
    if (out == NULL || capacity < SZFriendsStunHeaderLength) return 0;
    Write16(out, type);
    Write16(out + 2, 0);
    Write32(out + 4, kMagicCookie);
    memcpy(out + 8, transaction, SZFriendsStunTransactionLength);
    return SZFriendsStunHeaderLength;
}

static size_t WriteRequest(uint8_t *out, size_t capacity, const uint8_t transaction[12], BOOL nominate,
                           const char *username, const uint8_t *key, size_t keyLength) {
    size_t at = WriteHeader(out, capacity, SZFriendsStunTypeBindingRequest, transaction);
    if (at == 0) return 0;
    if (nominate && !AppendAttribute(out, capacity, &at, kAttrUseCandidate, NULL, 0)) return 0;
    if (username != NULL) {
        size_t usernameLength = strlen(username);
        if (usernameLength == 0 || usernameLength > SZFriendsStunUsernameMax) return 0;
        if (!AppendAttribute(out, capacity, &at, kAttrUsername, username, usernameLength)) return 0;
    }
    return Finish(out, capacity, at, key, keyLength);
}

size_t SZFriendsStunWriteBindingRequest(uint8_t *out, size_t capacity, const uint8_t transaction[12],
                                        const char *username, const uint8_t *key, size_t keyLength) {
    return WriteRequest(out, capacity, transaction, NO, username, key, keyLength);
}

size_t SZFriendsStunWriteNominatingRequest(uint8_t *out, size_t capacity, const uint8_t transaction[12],
                                           const char *username, const uint8_t *key, size_t keyLength) {
    if (username == NULL || key == NULL || keyLength == 0) return 0;
    return WriteRequest(out, capacity, transaction, YES, username, key, keyLength);
}

size_t SZFriendsStunWriteBindingSuccess(uint8_t *out, size_t capacity, const uint8_t transaction[12],
                                        const struct sockaddr *mapped, const uint8_t *key, size_t keyLength) {
    if (mapped == NULL) return 0;
    size_t at = WriteHeader(out, capacity, SZFriendsStunTypeBindingSuccess, transaction);
    if (at == 0) return 0;
    uint8_t value[20] = {0};
    size_t valueLength;
    uint16_t port;
    if (mapped->sa_family == AF_INET) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)mapped;
        value[1] = 0x01;
        port = ntohs(in->sin_port);
        memcpy(value + 4, &in->sin_addr, 4);
        valueLength = 8;
    } else if (mapped->sa_family == AF_INET6) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)mapped;
        value[1] = 0x02;
        port = ntohs(in6->sin6_port);
        memcpy(value + 4, &in6->sin6_addr, 16);
        valueLength = 20;
    } else {
        return 0;
    }
    Write16(value + 2, port ^ (uint16_t)(kMagicCookie >> 16));
    for (size_t i = 4; i < valueLength; i++) value[i] ^= out[i]; // header bytes 4..: cookie || transaction
    if (!AppendAttribute(out, capacity, &at, kAttrXorMappedAddress, value, valueLength)) return 0;
    return Finish(out, capacity, at, key, keyLength);
}

size_t SZFriendsStunFramedLength(const uint8_t *bytes, size_t length) {
    if (bytes == NULL) return SIZE_MAX;
    if (length >= 1 && (bytes[0] & 0xc0) != 0) return SIZE_MAX;
    if (length >= 8 && Read32(bytes + 4) != kMagicCookie) return SIZE_MAX;
    if (length < SZFriendsStunHeaderLength) return 0;
    size_t total = SZFriendsStunHeaderLength + Read16(bytes + 2);
    if (total > SZFriendsStunMessageMax || (total % 4) != 0) return SIZE_MAX;
    return length >= total ? total : 0;
}
