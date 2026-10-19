// Noise rev 34 HandshakeState for XX, IK and NN with 25519_ChaChaPoly_BLAKE2b (szfriends_noise.h).

#include "szfriends_noise.h"

#include <string.h>

#include <sodium.h>

enum { TOKEN_END = 0, TOKEN_E, TOKEN_S, TOKEN_EE, TOKEN_ES, TOKEN_SE, TOKEN_SS };

// Message patterns from spec § 7.4 and § 7.5. Messages alternate initiator, responder, initiator.
static const uint8_t kPatternXX[3][5] = {
    {TOKEN_E, TOKEN_END},
    {TOKEN_E, TOKEN_EE, TOKEN_S, TOKEN_ES, TOKEN_END},
    {TOKEN_S, TOKEN_SE, TOKEN_END},
};
static const uint8_t kPatternIK[2][5] = {
    {TOKEN_E, TOKEN_ES, TOKEN_S, TOKEN_SS, TOKEN_END},
    {TOKEN_E, TOKEN_EE, TOKEN_SE, TOKEN_END},
};
static const uint8_t kPatternNN[2][5] = {
    {TOKEN_E, TOKEN_END},
    {TOKEN_E, TOKEN_EE, TOKEN_END},
};

static const char *protocol_name(szfriends_noise_pattern pattern) {
    switch (pattern) {
    case SZFRIENDS_NOISE_XX:
        return "Noise_XX_25519_ChaChaPoly_BLAKE2b";
    case SZFRIENDS_NOISE_IK:
        return "Noise_IK_25519_ChaChaPoly_BLAKE2b";
    case SZFRIENDS_NOISE_NN:
        return "Noise_NN_25519_ChaChaPoly_BLAKE2b";
    }
    return NULL;
}

int szfriends_handshake_message_count(szfriends_noise_pattern pattern) {
    switch (pattern) {
    case SZFRIENDS_NOISE_XX:
        return 3;
    case SZFRIENDS_NOISE_IK:
    case SZFRIENDS_NOISE_NN:
        return 2;
    }
    return 0;
}

static const uint8_t *message_tokens(const szfriends_handshake_state *hs) {
    switch (hs->pattern) {
    case SZFRIENDS_NOISE_XX:
        return kPatternXX[hs->step];
    case SZFRIENDS_NOISE_IK:
        return kPatternIK[hs->step];
    case SZFRIENDS_NOISE_NN:
        return kPatternNN[hs->step];
    }
    return NULL;
}

static int fail(szfriends_handshake_state *hs, int error) {
    hs->failed = 1;
    return error;
}

int szfriends_handshake_init(szfriends_handshake_state *hs, szfriends_noise_pattern pattern, int initiator,
                             const uint8_t *prologue, size_t prologue_length, const uint8_t *s_priv,
                             const uint8_t *rs) {
    const char *name = protocol_name(pattern);
    sodium_memzero(hs, sizeof *hs);
    hs->failed = 1;
    if (name == NULL) {
        return SZFRIENDS_NOISE_ERR_ARGUMENT;
    }
    if (pattern == SZFRIENDS_NOISE_NN && (s_priv != NULL || rs != NULL)) {
        return SZFRIENDS_NOISE_ERR_ARGUMENT;
    }
    if (pattern != SZFRIENDS_NOISE_NN && s_priv == NULL) {
        return SZFRIENDS_NOISE_ERR_ARGUMENT;
    }
    // IK's initiator must know the responder's static; nobody else may be handed one in advance.
    if ((pattern == SZFRIENDS_NOISE_IK && initiator) != (rs != NULL)) {
        return SZFRIENDS_NOISE_ERR_ARGUMENT;
    }

    hs->pattern = pattern;
    hs->initiator = initiator ? 1 : 0;
    szfriends_symmetric_init(&hs->ss, name);
    szfriends_symmetric_mix_hash(&hs->ss, prologue, prologue_length);
    if (s_priv != NULL) {
        memcpy(hs->s_priv, s_priv, SZFRIENDS_NOISE_DHLEN);
        crypto_scalarmult_base(hs->s_pub, hs->s_priv);
        hs->has_s = 1;
    }
    if (rs != NULL) {
        memcpy(hs->rs, rs, SZFRIENDS_NOISE_DHLEN);
        hs->has_rs = 1;
    }
    // IK pre-message "<- s": both sides hash the responder's static public key.
    if (pattern == SZFRIENDS_NOISE_IK) {
        szfriends_symmetric_mix_hash(&hs->ss, initiator ? hs->rs : hs->s_pub, SZFRIENDS_NOISE_DHLEN);
    }
    hs->failed = 0;
    return SZFRIENDS_NOISE_OK;
}

int szfriends_handshake_set_fixed_ephemeral(szfriends_handshake_state *hs,
                                           const uint8_t e_priv[SZFRIENDS_NOISE_DHLEN]) {
    if (hs->failed || hs->step != 0 || hs->has_e) {
        return SZFRIENDS_NOISE_ERR_STATE;
    }
    memcpy(hs->fixed_e, e_priv, SZFRIENDS_NOISE_DHLEN);
    hs->has_fixed_e = 1;
    return SZFRIENDS_NOISE_OK;
}

int szfriends_handshake_is_finished(const szfriends_handshake_state *hs) {
    return !hs->failed && hs->step >= szfriends_handshake_message_count(hs->pattern);
}

int szfriends_handshake_is_write_turn(const szfriends_handshake_state *hs) {
    if (hs->failed || szfriends_handshake_is_finished(hs)) {
        return 0;
    }
    return (hs->step % 2 == 0) == (hs->initiator == 1);
}

int szfriends_handshake_overhead(const szfriends_handshake_state *hs) {
    const uint8_t *token;
    int has_key = hs->ss.cs.has_key;
    int overhead = 0;
    if (hs->failed || szfriends_handshake_is_finished(hs)) {
        return -1;
    }
    for (token = message_tokens(hs); *token != TOKEN_END; token++) {
        if (*token == TOKEN_E) {
            overhead += SZFRIENDS_NOISE_DHLEN;
        } else if (*token == TOKEN_S) {
            overhead += SZFRIENDS_NOISE_DHLEN + (has_key ? SZFRIENDS_NOISE_TAGLEN : 0);
        } else {
            has_key = 1; // every DH token ends in MixKey
        }
    }
    return overhead + (has_key ? SZFRIENDS_NOISE_TAGLEN : 0);
}

// DH(): X25519. libsodium returns -1 when the shared secret is all zeros (a low-order point), which ADR 0001
// treats as a failed handshake rather than a weak key.
static int mix_dh(szfriends_handshake_state *hs, const uint8_t *private_key, const uint8_t *public_key) {
    uint8_t shared[SZFRIENDS_NOISE_DHLEN];
    int result;
    hs->dh_count++;
    if (crypto_scalarmult(shared, private_key, public_key) != 0) {
        sodium_memzero(shared, sizeof shared);
        return SZFRIENDS_NOISE_ERR_DH;
    }
    result = szfriends_symmetric_mix_key(&hs->ss, shared, sizeof shared);
    sodium_memzero(shared, sizeof shared);
    return result;
}

// ee, es, se, ss: the initiator's and responder's roles swap for es and se (spec § 5.3).
static int process_dh(szfriends_handshake_state *hs, uint8_t token) {
    int i = hs->initiator;
    switch (token) {
    case TOKEN_EE:
        return (hs->has_e && hs->has_re) ? mix_dh(hs, hs->e_priv, hs->re) : SZFRIENDS_NOISE_ERR_STATE;
    case TOKEN_ES:
        if (i) {
            return (hs->has_e && hs->has_rs) ? mix_dh(hs, hs->e_priv, hs->rs) : SZFRIENDS_NOISE_ERR_STATE;
        }
        return (hs->has_s && hs->has_re) ? mix_dh(hs, hs->s_priv, hs->re) : SZFRIENDS_NOISE_ERR_STATE;
    case TOKEN_SE:
        if (i) {
            return (hs->has_s && hs->has_re) ? mix_dh(hs, hs->s_priv, hs->re) : SZFRIENDS_NOISE_ERR_STATE;
        }
        return (hs->has_e && hs->has_rs) ? mix_dh(hs, hs->e_priv, hs->rs) : SZFRIENDS_NOISE_ERR_STATE;
    case TOKEN_SS:
        return (hs->has_s && hs->has_rs) ? mix_dh(hs, hs->s_priv, hs->rs) : SZFRIENDS_NOISE_ERR_STATE;
    }
    return SZFRIENDS_NOISE_ERR_STATE;
}

int szfriends_handshake_write(szfriends_handshake_state *hs, const uint8_t *payload, size_t payload_length,
                              uint8_t *out, size_t out_capacity, size_t *out_length) {
    const uint8_t *token;
    size_t used = 0, written = 0;
    int overhead, result;

    if (!szfriends_handshake_is_write_turn(hs)) {
        return hs->failed ? SZFRIENDS_NOISE_ERR_STATE : fail(hs, SZFRIENDS_NOISE_ERR_STATE);
    }
    overhead = szfriends_handshake_overhead(hs);
    if (payload_length > (size_t)(SZFRIENDS_NOISE_MAX_MESSAGE - overhead)) {
        return fail(hs, SZFRIENDS_NOISE_ERR_SIZE);
    }
    if (out_capacity < (size_t)overhead + payload_length) {
        return fail(hs, SZFRIENDS_NOISE_ERR_ARGUMENT);
    }

    for (token = message_tokens(hs); *token != TOKEN_END; token++) {
        if (*token == TOKEN_E) {
            if (hs->has_e) {
                return fail(hs, SZFRIENDS_NOISE_ERR_STATE);
            }
            if (hs->has_fixed_e) {
                memcpy(hs->e_priv, hs->fixed_e, SZFRIENDS_NOISE_DHLEN);
            } else {
                randombytes_buf(hs->e_priv, SZFRIENDS_NOISE_DHLEN);
            }
            if (crypto_scalarmult_base(hs->e_pub, hs->e_priv) != 0) {
                return fail(hs, SZFRIENDS_NOISE_ERR_DH);
            }
            hs->has_e = 1;
            memcpy(out + used, hs->e_pub, SZFRIENDS_NOISE_DHLEN);
            used += SZFRIENDS_NOISE_DHLEN;
            szfriends_symmetric_mix_hash(&hs->ss, hs->e_pub, SZFRIENDS_NOISE_DHLEN);
        } else if (*token == TOKEN_S) {
            result = szfriends_symmetric_encrypt_and_hash(&hs->ss, hs->s_pub, SZFRIENDS_NOISE_DHLEN, out + used,
                                                          out_capacity - used, &written);
            if (result != SZFRIENDS_NOISE_OK) {
                return fail(hs, result);
            }
            used += written;
        } else {
            result = process_dh(hs, *token);
            if (result != SZFRIENDS_NOISE_OK) {
                return fail(hs, result);
            }
        }
    }
    result = szfriends_symmetric_encrypt_and_hash(&hs->ss, payload, payload_length, out + used,
                                                  out_capacity - used, &written);
    if (result != SZFRIENDS_NOISE_OK) {
        return fail(hs, result);
    }
    *out_length = used + written;
    hs->step++;
    return SZFRIENDS_NOISE_OK;
}

int szfriends_handshake_read(szfriends_handshake_state *hs, const uint8_t *message, size_t message_length,
                             uint8_t *payload, size_t payload_capacity, size_t *payload_length) {
    const uint8_t *token;
    size_t used = 0, written = 0, chunk;
    int result;

    if (hs->failed || szfriends_handshake_is_finished(hs) || szfriends_handshake_is_write_turn(hs)) {
        return hs->failed ? SZFRIENDS_NOISE_ERR_STATE : fail(hs, SZFRIENDS_NOISE_ERR_STATE);
    }
    if (message_length > SZFRIENDS_NOISE_MAX_MESSAGE) {
        return fail(hs, SZFRIENDS_NOISE_ERR_SIZE);
    }

    for (token = message_tokens(hs); *token != TOKEN_END; token++) {
        if (*token == TOKEN_E) {
            if (hs->has_re || message_length - used < SZFRIENDS_NOISE_DHLEN) {
                return fail(hs, hs->has_re ? SZFRIENDS_NOISE_ERR_STATE : SZFRIENDS_NOISE_ERR_SIZE);
            }
            memcpy(hs->re, message + used, SZFRIENDS_NOISE_DHLEN);
            hs->has_re = 1;
            used += SZFRIENDS_NOISE_DHLEN;
            szfriends_symmetric_mix_hash(&hs->ss, hs->re, SZFRIENDS_NOISE_DHLEN);
        } else if (*token == TOKEN_S) {
            chunk = SZFRIENDS_NOISE_DHLEN + (hs->ss.cs.has_key ? SZFRIENDS_NOISE_TAGLEN : 0);
            if (hs->has_rs || message_length - used < chunk) {
                return fail(hs, hs->has_rs ? SZFRIENDS_NOISE_ERR_STATE : SZFRIENDS_NOISE_ERR_SIZE);
            }
            result = szfriends_symmetric_decrypt_and_hash(&hs->ss, message + used, chunk, hs->rs, sizeof hs->rs,
                                                          &written);
            if (result != SZFRIENDS_NOISE_OK) {
                return fail(hs, result);
            }
            hs->has_rs = 1;
            used += chunk;
        } else {
            result = process_dh(hs, *token);
            if (result != SZFRIENDS_NOISE_OK) {
                return fail(hs, result);
            }
        }
    }
    if (hs->ss.cs.has_key && message_length - used < SZFRIENDS_NOISE_TAGLEN) {
        return fail(hs, SZFRIENDS_NOISE_ERR_SIZE);
    }
    result = szfriends_symmetric_decrypt_and_hash(&hs->ss, message + used, message_length - used, payload,
                                                  payload_capacity, &written);
    if (result != SZFRIENDS_NOISE_OK) {
        return fail(hs, result);
    }
    *payload_length = written;
    hs->step++;
    return SZFRIENDS_NOISE_OK;
}

int szfriends_handshake_split(szfriends_handshake_state *hs, szfriends_cipher_state *send,
                              szfriends_cipher_state *receive) {
    szfriends_cipher_state c1, c2;
    if (!szfriends_handshake_is_finished(hs)) {
        return SZFRIENDS_NOISE_ERR_STATE;
    }
    szfriends_symmetric_split(&hs->ss, &c1, &c2);
    if (hs->initiator) {
        *send = c1;
        *receive = c2;
    } else {
        *send = c2;
        *receive = c1;
    }
    szfriends_cipher_clear(&c1);
    szfriends_cipher_clear(&c2);
    // The chaining key and handshake cipher are no longer needed; h stays for channel binding.
    sodium_memzero(hs->ss.ck, sizeof hs->ss.ck);
    szfriends_cipher_clear(&hs->ss.cs);
    sodium_memzero(hs->e_priv, sizeof hs->e_priv);
    sodium_memzero(hs->s_priv, sizeof hs->s_priv);
    sodium_memzero(hs->fixed_e, sizeof hs->fixed_e);
    return SZFRIENDS_NOISE_OK;
}

void szfriends_handshake_hash(const szfriends_handshake_state *hs, uint8_t out[SZFRIENDS_NOISE_HASHLEN]) {
    memcpy(out, hs->ss.h, SZFRIENDS_NOISE_HASHLEN);
}

const uint8_t *szfriends_handshake_remote_static(const szfriends_handshake_state *hs) {
    return hs->has_rs ? hs->rs : NULL;
}

void szfriends_handshake_clear(szfriends_handshake_state *hs) {
    sodium_memzero(hs, sizeof *hs);
}

void szfriends_noise_dummy_dh(void) {
    // The variable-base ladder a DH token runs, on the curve's base point taken as an ordinary public key: libsodium's
    // X25519 takes the same time whatever the scalar and point, so a random scalar costs exactly what a real DH does.
    static const uint8_t base_point[SZFRIENDS_NOISE_DHLEN] = {9};
    uint8_t scalar[SZFRIENDS_NOISE_DHLEN], shared[SZFRIENDS_NOISE_DHLEN];
    randombytes_buf(scalar, sizeof scalar);
    (void)crypto_scalarmult(shared, scalar, base_point);
    sodium_memzero(scalar, sizeof scalar);
    sodium_memzero(shared, sizeof shared);
}
