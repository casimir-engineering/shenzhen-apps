// PCP (RFC 6887) and NAT-PMP (RFC 6886) messages for router port mapping (ADR 0011 § Port mapping): MAP for UDP
// only, NAT-PMP's external address and UDP mapping, and the epoch check both protocols share. No PEER, no
// THIRD_PARTY or other options are sent; options in an answer are walked and ignored.
//
// Parsing is strict: answers come from the LAN before anyone is authenticated (the client also accepts them only
// from the gateway's address and port 5351). A PCP answer must be a MAP response of version 2, a multiple of four
// bytes and at most 1,100, with well-formed options, our nonce, protocol and internal port. A NAT-PMP success has
// exactly its RFC length. Fuzzed by fuzz/SZFriendsNATFuzzPCP.m.

#import <Foundation/Foundation.h>

#include <stddef.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    SZFriendsPCPPort = 5351,              // PCP and NAT-PMP servers both listen here
    SZFriendsPCPMapRequestLength = 60,    // 24-byte header + 36-byte MAP
    SZFriendsPCPMessageMax = 1100,        // RFC 6887 § 7
    SZFriendsPCPNonceLength = 12,
    SZFriendsPCPProtocolUDP = 17,
    SZFriendsNATPMPExternalRequestLength = 2,
    SZFriendsNATPMPMapRequestLength = 12,
};

// Result codes worth naming; every other non-zero code is a refusal too.
enum {
    SZFriendsPCPResultSuccess = 0,
    SZFriendsPCPResultUnsupportedVersion = 1,
    SZFriendsPCPResultNotAuthorized = 2,
    SZFriendsPCPResultAddressMismatch = 12,
};

// A MAP request. `client` is this side's address as the server will see it: 16 bytes, IPv4-mapped for IPv4
// (::ffff:a.b.c.d). The suggested external address is the all-zero address of the client's family (any). Lifetime 0
// deletes the mapping. Returns SZFriendsPCPMapRequestLength.
size_t SZFriendsPCPWriteMapRequest(uint8_t out[_Nonnull 60], const uint8_t nonce[_Nonnull 12],
                                   const uint8_t client[_Nonnull 16], uint16_t internalPort,
                                   uint16_t suggestedExternalPort, uint32_t lifetime);

typedef struct {
    uint8_t result;
    uint32_t lifetime;
    uint32_t epoch;
    uint16_t externalPort;
    uint8_t externalAddress[16]; // IPv4-mapped for IPv4
} SZFriendsPCPMapResponse;

typedef NS_ENUM(NSInteger, SZFriendsPCPAnswer) {
    SZFriendsPCPAnswerInvalid = 0,            // not an answer to this request: ignore it and keep waiting
    SZFriendsPCPAnswerMap = 1,                // a MAP response to this request; see its result
    SZFriendsPCPAnswerUnsupportedVersion = 2, // a NAT-PMP server's version-0 refusal: fall back to NAT-PMP
};

SZFriendsPCPAnswer SZFriendsPCPParseAnswer(const uint8_t *bytes, size_t length, const uint8_t nonce[_Nonnull 12],
                                           uint16_t internalPort, SZFriendsPCPMapResponse *response);

// NAT-PMP: the external address request (opcode 0) and the UDP mapping request (opcode 1). Lifetime 0 deletes.
size_t SZFriendsNATPMPWriteExternalAddressRequest(uint8_t out[_Nonnull 2]);
size_t SZFriendsNATPMPWriteMapRequest(uint8_t out[_Nonnull 12], uint16_t internalPort,
                                      uint16_t suggestedExternalPort, uint32_t lifetime);

typedef struct {
    uint16_t result;
    uint32_t epoch;
    uint8_t externalAddress[4]; // external address answers
    uint16_t externalPort;      // mapping answers
    uint32_t lifetime;          // mapping answers
} SZFriendsNATPMPResponse;

// NO for anything but the answer to that request (opcode 128 or 129). A refusal (result not 0) may be as short as
// its 8-byte header; a success must be exactly 12 (address) or 16 (mapping) bytes, for our internal port.
BOOL SZFriendsNATPMPParseExternalAddress(const uint8_t *bytes, size_t length, SZFriendsNATPMPResponse *response);
BOOL SZFriendsNATPMPParseMap(const uint8_t *bytes, size_t length, uint16_t internalPort,
                             SZFriendsNATPMPResponse *response);

// The epoch check (RFC 6887 § 8.5, RFC 6886 § 3.6): the server's seconds since it last lost its mappings, against
// our own clock. A server that went backwards, or whose time moved differently from ours by more than the RFC's
// slack, has lost every mapping, and the client maps again.
typedef struct {
    BOOL known;
    uint32_t epoch;
    double clientSeconds;
} SZFriendsNATEpoch;

// YES when `epoch` at `nowSeconds` continues what `state` saw (or is the first answer); NO when the server lost
// its state. Either way `state` then holds this answer.
BOOL SZFriendsNATEpochContinues(SZFriendsNATEpoch *state, uint32_t epoch, double nowSeconds);

NS_ASSUME_NONNULL_END
