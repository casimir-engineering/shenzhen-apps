// PCP and NAT-PMP messages (SZFriendsNATPCP.h).

#import "service/online/nat/SZFriendsNATPCP.h"

#include <string.h>

enum {
    kPCPVersion = 2,
    kPCPOpcodeMap = 1,
    kPCPResponseBit = 0x80,
    kPCPHeaderLength = 24,
    kPCPMapLength = 36,
    kNATPMPOpcodeExternal = 0,
    kNATPMPOpcodeMapUDP = 1,
    kNATPMPResponseBit = 128,
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

static BOOL IsIPv4Mapped(const uint8_t address[16]) {
    static const uint8_t prefix[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};
    return memcmp(address, prefix, sizeof prefix) == 0;
}

size_t SZFriendsPCPWriteMapRequest(uint8_t out[60], const uint8_t nonce[12], const uint8_t client[16],
                                   uint16_t internalPort, uint16_t suggestedExternalPort, uint32_t lifetime) {
    memset(out, 0, SZFriendsPCPMapRequestLength);
    out[0] = kPCPVersion;
    out[1] = kPCPOpcodeMap;
    Write32(out + 4, lifetime);
    memcpy(out + 8, client, 16);
    uint8_t *map = out + kPCPHeaderLength;
    memcpy(map, nonce, SZFriendsPCPNonceLength);
    map[12] = SZFriendsPCPProtocolUDP;
    Write16(map + 16, internalPort);
    Write16(map + 18, suggestedExternalPort);
    // The suggested external address: "any" in the client's family (RFC 6887 § 11.1), ::ffff:0.0.0.0 for IPv4.
    if (IsIPv4Mapped(client)) {
        map[30] = 0xff;
        map[31] = 0xff;
    }
    return SZFriendsPCPMapRequestLength;
}

// Options after the MAP payload: code, reserved, 16-bit length, data padded to four bytes, all inside the message.
static BOOL OptionsAreWellFormed(const uint8_t *bytes, size_t at, size_t length) {
    while (at < length) {
        if (length - at < 4) return NO;
        size_t optionLength = Read16(bytes + at + 2);
        size_t padded = (optionLength + 3) & ~(size_t)3;
        if (padded > length - at - 4) return NO;
        at += 4 + padded;
    }
    return YES;
}

SZFriendsPCPAnswer SZFriendsPCPParseAnswer(const uint8_t *bytes, size_t length, const uint8_t nonce[12],
                                           uint16_t internalPort, SZFriendsPCPMapResponse *response) {
    if (bytes == NULL || response == NULL || nonce == NULL) return SZFriendsPCPAnswerInvalid;
    memset(response, 0, sizeof *response);
    // A NAT-PMP-only server answers any other version with its own header: version 0, a response opcode,
    // result 1 "unsupported version" (RFC 6887 § 9). Only that exact refusal means "fall back".
    if (length >= 4 && length <= 16 && bytes[0] == 0) {
        if ((bytes[1] & kNATPMPResponseBit) && Read16(bytes + 2) == SZFriendsPCPResultUnsupportedVersion) {
            return SZFriendsPCPAnswerUnsupportedVersion;
        }
        return SZFriendsPCPAnswerInvalid;
    }
    if (length < kPCPHeaderLength + kPCPMapLength || length > SZFriendsPCPMessageMax || length % 4 != 0) {
        return SZFriendsPCPAnswerInvalid;
    }
    if (bytes[0] != kPCPVersion || bytes[1] != (kPCPResponseBit | kPCPOpcodeMap)) return SZFriendsPCPAnswerInvalid;
    const uint8_t *map = bytes + kPCPHeaderLength;
    if (memcmp(map, nonce, SZFriendsPCPNonceLength) != 0) return SZFriendsPCPAnswerInvalid;
    if (map[12] != SZFriendsPCPProtocolUDP || Read16(map + 16) != internalPort) return SZFriendsPCPAnswerInvalid;
    if (!OptionsAreWellFormed(bytes, kPCPHeaderLength + kPCPMapLength, length)) return SZFriendsPCPAnswerInvalid;
    response->result = bytes[3];
    response->lifetime = Read32(bytes + 4);
    response->epoch = Read32(bytes + 8);
    response->externalPort = Read16(map + 18);
    memcpy(response->externalAddress, map + 20, 16);
    // A success that maps nothing is not a mapping (a delete's answer has lifetime 0 and is checked by the caller).
    if (response->result == SZFriendsPCPResultSuccess && response->lifetime > 0 && response->externalPort == 0) {
        return SZFriendsPCPAnswerInvalid;
    }
    return SZFriendsPCPAnswerMap;
}

size_t SZFriendsNATPMPWriteExternalAddressRequest(uint8_t out[2]) {
    out[0] = 0;
    out[1] = kNATPMPOpcodeExternal;
    return SZFriendsNATPMPExternalRequestLength;
}

size_t SZFriendsNATPMPWriteMapRequest(uint8_t out[12], uint16_t internalPort, uint16_t suggestedExternalPort,
                                      uint32_t lifetime) {
    memset(out, 0, SZFriendsNATPMPMapRequestLength);
    out[1] = kNATPMPOpcodeMapUDP;
    Write16(out + 4, internalPort);
    Write16(out + 6, suggestedExternalPort);
    Write32(out + 8, lifetime);
    return SZFriendsNATPMPMapRequestLength;
}

// The common 8-byte header of a NAT-PMP answer: version 0, the response opcode, result, epoch.
static BOOL ParseNATPMPHeader(const uint8_t *bytes, size_t length, uint8_t opcode, size_t successLength,
                              SZFriendsNATPMPResponse *response) {
    if (bytes == NULL || response == NULL) return NO;
    memset(response, 0, sizeof *response);
    if (length < 8 || length > successLength) return NO;
    if (bytes[0] != 0 || bytes[1] != (kNATPMPResponseBit | opcode)) return NO;
    response->result = Read16(bytes + 2);
    response->epoch = Read32(bytes + 4);
    return response->result != 0 || length == successLength;
}

BOOL SZFriendsNATPMPParseExternalAddress(const uint8_t *bytes, size_t length, SZFriendsNATPMPResponse *response) {
    if (!ParseNATPMPHeader(bytes, length, kNATPMPOpcodeExternal, 12, response)) return NO;
    if (response->result == 0) memcpy(response->externalAddress, bytes + 8, 4);
    return YES;
}

BOOL SZFriendsNATPMPParseMap(const uint8_t *bytes, size_t length, uint16_t internalPort,
                             SZFriendsNATPMPResponse *response) {
    if (!ParseNATPMPHeader(bytes, length, kNATPMPOpcodeMapUDP, 16, response)) return NO;
    if (response->result != 0) return YES;
    if (Read16(bytes + 8) != internalPort) return NO;
    response->externalPort = Read16(bytes + 10);
    response->lifetime = Read32(bytes + 12);
    return response->lifetime == 0 || response->externalPort != 0;
}

BOOL SZFriendsNATEpochContinues(SZFriendsNATEpoch *state, uint32_t epoch, double nowSeconds) {
    BOOL continues = YES;
    if (state->known) {
        if ((uint64_t)epoch + 1 < state->epoch) {
            continues = NO;
        } else {
            double clientDelta = nowSeconds - state->clientSeconds;
            double serverDelta = (double)epoch - (double)state->epoch;
            if (clientDelta + 2 < serverDelta - serverDelta / 16 || serverDelta + 2 < clientDelta - clientDelta / 16) {
                continues = NO;
            }
        }
    }
    state->known = YES;
    state->epoch = epoch;
    state->clientSeconds = nowSeconds;
    return continues;
}
