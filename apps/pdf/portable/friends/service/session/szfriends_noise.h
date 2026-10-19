// Noise Protocol Framework, revision 34, for exactly one suite and three patterns:
// Noise_{XX,IK,NN}_25519_ChaChaPoly_BLAKE2b (ADR 0001). Internal to service/session/; Objective-C callers use
// SZFriendsSession.h. CipherState, SymmetricState and HandshakeState follow the spec's sections 5.1 to 5.3 name
// for name, so a reviewer can read them side by side with it; there are no PSK modifiers, no fallback and no
// run-time protocol-name parsing, because every extra path is review surface we do not need.
//
// C99 over libsodium. Every function returns SZFRIENDS_NOISE_OK or a negative error. A HandshakeState that has
// returned an error is dead (spec § 5.3: its SymmetricState may be half-mixed) and refuses further calls, so a
// caller cannot keep going after a failed message by accident.

#ifndef SZFRIENDS_NOISE_H
#define SZFRIENDS_NOISE_H

#include <stddef.h>
#include <stdint.h>

enum {
    SZFRIENDS_NOISE_DHLEN = 32,
    SZFRIENDS_NOISE_HASHLEN = 64,
    SZFRIENDS_NOISE_BLOCKLEN = 128,
    SZFRIENDS_NOISE_KEYLEN = 32,
    SZFRIENDS_NOISE_TAGLEN = 16,
    SZFRIENDS_NOISE_MAX_MESSAGE = 65535, // spec § 3: every Noise message, handshake or transport
};

enum {
    SZFRIENDS_NOISE_OK = 0,
    SZFRIENDS_NOISE_ERR_ARGUMENT = -1, // a missing key the pattern needs, a buffer too small, a bad pattern
    SZFRIENDS_NOISE_ERR_STATE = -2,    // out of turn, already finished, or dead after an earlier error
    SZFRIENDS_NOISE_ERR_SIZE = -3,     // a message over 65,535 bytes, or too short for its tokens
    SZFRIENDS_NOISE_ERR_DECRYPT = -4,  // authentication failed
    SZFRIENDS_NOISE_ERR_DH = -5,       // X25519 produced all zeros (a low-order public key)
    SZFRIENDS_NOISE_ERR_NONCE = -6,    // the counter reached 2^64-1, which the spec reserves
};

// Values match SZFriendsHandshakePattern, which is also the preamble's pattern byte.
typedef enum {
    SZFRIENDS_NOISE_XX = 0,
    SZFRIENDS_NOISE_IK = 1,
    SZFRIENDS_NOISE_NN = 2,
} szfriends_noise_pattern;

#pragma mark - Primitives exposed for known-answer tests

// HASH() = BLAKE2b-512; HMAC-HASH per RFC 2104 with BLOCKLEN 128; HKDF exactly as spec § 4.3 writes it (not RFC
// 5869's general form: no salt, no info, outputs chained with a counter byte). `out3` may be NULL.
void szfriends_noise_hash(const uint8_t *data, size_t length, uint8_t out[SZFRIENDS_NOISE_HASHLEN]);
void szfriends_noise_hmac(const uint8_t *key, size_t key_length, const uint8_t *data, size_t data_length,
                          uint8_t out[SZFRIENDS_NOISE_HASHLEN]);
void szfriends_noise_hkdf(const uint8_t chaining_key[SZFRIENDS_NOISE_HASHLEN], const uint8_t *ikm, size_t ikm_length,
                          uint8_t out1[SZFRIENDS_NOISE_HASHLEN], uint8_t out2[SZFRIENDS_NOISE_HASHLEN],
                          uint8_t *out3);

#pragma mark - CipherState (spec § 5.1)

typedef struct {
    uint8_t k[SZFRIENDS_NOISE_KEYLEN];
    int has_key;
    uint64_t n;
} szfriends_cipher_state;

// `key` NULL means empty: EncryptWithAd then returns the plaintext unchanged, as the spec requires before the
// first DH token.
void szfriends_cipher_init(szfriends_cipher_state *cs, const uint8_t *key);
// Output is input + 16 bytes when a key is set. `out` may equal `in`. Fails without touching n when n is
// 2^64-1, so a counter can never wrap and reuse a nonce.
int szfriends_cipher_encrypt(szfriends_cipher_state *cs, const uint8_t *ad, size_t ad_length, const uint8_t *in,
                             size_t in_length, uint8_t *out, size_t out_capacity, size_t *out_length);
// On failure n is unchanged (spec § 5.1); callers close the session anyway (ADR 0001: no resynchronisation).
int szfriends_cipher_decrypt(szfriends_cipher_state *cs, const uint8_t *ad, size_t ad_length, const uint8_t *in,
                             size_t in_length, uint8_t *out, size_t out_capacity, size_t *out_length);
// k = first 32 bytes of ENCRYPT(k, 2^64-1, empty, 32 zero bytes) (spec § 4.2 default REKEY, § 11.3). n is kept.
int szfriends_cipher_rekey(szfriends_cipher_state *cs);
void szfriends_cipher_clear(szfriends_cipher_state *cs);

#pragma mark - SymmetricState (spec § 5.2)

typedef struct {
    szfriends_cipher_state cs;
    uint8_t ck[SZFRIENDS_NOISE_HASHLEN];
    uint8_t h[SZFRIENDS_NOISE_HASHLEN];
} szfriends_symmetric_state;

void szfriends_symmetric_init(szfriends_symmetric_state *ss, const char *protocol_name);
int szfriends_symmetric_mix_key(szfriends_symmetric_state *ss, const uint8_t *ikm, size_t ikm_length);
void szfriends_symmetric_mix_hash(szfriends_symmetric_state *ss, const uint8_t *data, size_t length);
int szfriends_symmetric_encrypt_and_hash(szfriends_symmetric_state *ss, const uint8_t *in, size_t in_length,
                                         uint8_t *out, size_t out_capacity, size_t *out_length);
int szfriends_symmetric_decrypt_and_hash(szfriends_symmetric_state *ss, const uint8_t *in, size_t in_length,
                                         uint8_t *out, size_t out_capacity, size_t *out_length);
void szfriends_symmetric_split(szfriends_symmetric_state *ss, szfriends_cipher_state *c1,
                               szfriends_cipher_state *c2);
void szfriends_symmetric_clear(szfriends_symmetric_state *ss);

#pragma mark - HandshakeState (spec § 5.3)

typedef struct {
    szfriends_symmetric_state ss;
    szfriends_noise_pattern pattern;
    int initiator;
    int step;   // index of the next message in the pattern
    int failed; // set by any error; every later call fails
    uint8_t s_priv[SZFRIENDS_NOISE_DHLEN], s_pub[SZFRIENDS_NOISE_DHLEN];
    uint8_t e_priv[SZFRIENDS_NOISE_DHLEN], e_pub[SZFRIENDS_NOISE_DHLEN];
    uint8_t rs[SZFRIENDS_NOISE_DHLEN], re[SZFRIENDS_NOISE_DHLEN];
    uint8_t fixed_e[SZFRIENDS_NOISE_DHLEN];
    int has_s, has_e, has_rs, has_re, has_fixed_e;
    int dh_count; // X25519 operations run for DH tokens so far, failed ones included (refusal work equalisation)
} szfriends_handshake_state;

// Initialize(): the protocol name for `pattern`, MixHash(prologue), then the pre-message (IK's "<- s"). XX needs
// `s_priv`; IK needs `s_priv` on both sides and `rs` on the initiator; NN takes neither, and refuses a static so
// an NN session can never reveal one by mistake.
int szfriends_handshake_init(szfriends_handshake_state *hs, szfriends_noise_pattern pattern, int initiator,
                             const uint8_t *prologue, size_t prologue_length, const uint8_t *s_priv,
                             const uint8_t *rs);
// Test vectors fix the ephemeral key; production draws it with randombytes_buf when the "e" token is written.
// Only valid before the first message.
int szfriends_handshake_set_fixed_ephemeral(szfriends_handshake_state *hs,
                                           const uint8_t e_priv[SZFRIENDS_NOISE_DHLEN]);

int szfriends_handshake_message_count(szfriends_noise_pattern pattern);
int szfriends_handshake_is_finished(const szfriends_handshake_state *hs);
// Whether this side writes the next handshake message.
int szfriends_handshake_is_write_turn(const szfriends_handshake_state *hs);
// The bytes a message adds around its payload at the current step (keys and tags), so callers can bound a
// payload before writing; -1 when the handshake is finished or dead.
int szfriends_handshake_overhead(const szfriends_handshake_state *hs);

int szfriends_handshake_write(szfriends_handshake_state *hs, const uint8_t *payload, size_t payload_length,
                              uint8_t *out, size_t out_capacity, size_t *out_length);
int szfriends_handshake_read(szfriends_handshake_state *hs, const uint8_t *message, size_t message_length,
                             uint8_t *payload, size_t payload_capacity, size_t *payload_length);

// After the last message: Split(), oriented so `send` encrypts this side's messages (c1 for the initiator).
int szfriends_handshake_split(szfriends_handshake_state *hs, szfriends_cipher_state *send,
                              szfriends_cipher_state *receive);
void szfriends_handshake_hash(const szfriends_handshake_state *hs, uint8_t out[SZFRIENDS_NOISE_HASHLEN]);
// The remote static key once a message carried it (or IK's pre-message gave it); NULL before.
const uint8_t *szfriends_handshake_remote_static(const szfriends_handshake_state *hs);
// Zeroes every key, including the chaining key and the handshake hash.
void szfriends_handshake_clear(szfriends_handshake_state *hs);

// One X25519 operation whose result is thrown away: the cost of a DH token, for a responder that refuses message 1
// early and must spend what the full path spends, so the time it holds the helper's queue reveals nothing.
void szfriends_noise_dummy_dh(void);

#endif
