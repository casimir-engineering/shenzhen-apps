// STUN Binding messages (RFC 8489, the Binding method only) for the NAT techniques: the two-port classifier, the
// hard-NAT prober and STUN over TCP for the TCP path. libjuice keeps its own STUN inside the peer connection; this is
// the small codec for the sockets that live outside it (ADR 0011).
//
// Parsing is strict because these bytes arrive before anyone is authenticated and from anyone who can reach a
// socket: a message is accepted only whole (header length equal to the datagram, attributes inside it, padding to
// four bytes, a FINGERPRINT that checks if present and is last), never longer than SZFriendsStunMessageMax, and the
// parser allocates nothing. The first instance of an attribute counts and later ones are ignored (RFC 8489 § 14);
// attributes after MESSAGE-INTEGRITY other than FINGERPRINT are ignored too. A malformed address or error code
// rejects the whole message. Fuzzed by fuzz/SZFriendsNATFuzzStun.m.

#import <Foundation/Foundation.h>

#include <stddef.h>
#include <stdint.h>
#include <sys/socket.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    SZFriendsStunHeaderLength = 20,
    // The largest message read or written: the host's responder takes no larger request (HOST-PROTOCOL-ONLINE.md),
    // and a Binding answer with every attribute coturn adds is under 200 bytes.
    SZFriendsStunMessageMax = 548,
    SZFriendsStunTransactionLength = 12,
    // Short-term credentials (ADR 0011 § Probing budget): "<their ufrag>:<our ufrag>" with ufrags of at most 16
    // characters, so a probe with USERNAME, MESSAGE-INTEGRITY and FINGERPRINT is at most 92 bytes (96 with
    // USE-CANDIDATE), under 100.
    SZFriendsStunUsernameMax = 33,
};

typedef NS_ENUM(uint16_t, SZFriendsStunType) {
    SZFriendsStunTypeBindingRequest = 0x0001,
    SZFriendsStunTypeBindingSuccess = 0x0101,
    SZFriendsStunTypeBindingError = 0x0111,
};

// A parsed message. Pointers point into the parsed buffer and live as long as it does.
typedef struct {
    uint16_t type;
    uint8_t transaction[SZFriendsStunTransactionLength];
    BOOL hasMappedAddress; // XOR-MAPPED-ADDRESS, or MAPPED-ADDRESS when no XOR form came
    struct sockaddr_storage mappedAddress;
    socklen_t mappedAddressLength;
    const uint8_t *_Nullable username;
    size_t usernameLength;
    BOOL hasIntegrity;
    size_t integrityOffset; // of the MESSAGE-INTEGRITY attribute's header
    BOOL hasFingerprint;    // and it checked: a message whose FINGERPRINT fails is not parsed at all
    BOOL useCandidate;      // USE-CANDIDATE (RFC 8445 § 7.1.2): the controlling side nominates this pair
    uint16_t errorCode;     // 300 to 699 for a Binding error response, else 0
} SZFriendsStunMessage;

// NO for anything but one whole, well-formed STUN message of at most SZFriendsStunMessageMax bytes.
BOOL SZFriendsStunParse(const uint8_t *bytes, size_t length, SZFriendsStunMessage *message);

// MESSAGE-INTEGRITY (HMAC-SHA1 under the short-term key) of a parsed message, compared in constant time. NO when the
// message carries none.
BOOL SZFriendsStunCheckIntegrity(const uint8_t *bytes, size_t length, const SZFriendsStunMessage *message,
                                 const uint8_t *key, size_t keyLength);

// A Binding request with FINGERPRINT; with `username` and `key`, USERNAME and MESSAGE-INTEGRITY too. Returns the
// length written, or 0 when it does not fit or the username is longer than SZFriendsStunUsernameMax.
size_t SZFriendsStunWriteBindingRequest(uint8_t *out, size_t capacity, const uint8_t transaction[_Nonnull 12],
                                        const char *_Nullable username, const uint8_t *_Nullable key,
                                        size_t keyLength);

// The same, nominating: USE-CANDIDATE before USERNAME, as the controlling side of a pair sends it. At most 96 bytes
// with the longest username.
size_t SZFriendsStunWriteNominatingRequest(uint8_t *out, size_t capacity, const uint8_t transaction[_Nonnull 12],
                                           const char *username, const uint8_t *key, size_t keyLength);

// A Binding success response with XOR-MAPPED-ADDRESS for `mapped` (AF_INET or AF_INET6), MESSAGE-INTEGRITY when a
// key is given, and FINGERPRINT. 0 when it does not fit or the address family is neither.
size_t SZFriendsStunWriteBindingSuccess(uint8_t *out, size_t capacity, const uint8_t transaction[_Nonnull 12],
                                        const struct sockaddr *mapped, const uint8_t *_Nullable key,
                                        size_t keyLength);

// STUN over TCP (RFC 8489 § 6.2.2) has no framing of its own: the header's length field gives the message's end.
// Returns the length of the first message in `bytes` once all of it has arrived, 0 while more is needed, and
// SIZE_MAX when the bytes cannot start a STUN message or announce one longer than SZFriendsStunMessageMax.
size_t SZFriendsStunFramedLength(const uint8_t *bytes, size_t length);

void SZFriendsStunRandomTransaction(uint8_t transaction[_Nonnull 12]);

// CRC-32 (ISO-HDLC, as zlib), for FINGERPRINT.
uint32_t SZFriendsStunCRC32(const uint8_t *bytes, size_t length);

NS_ASSUME_NONNULL_END
