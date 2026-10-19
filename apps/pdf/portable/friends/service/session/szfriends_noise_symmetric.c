// Noise rev 34 primitives, CipherState and SymmetricState for 25519_ChaChaPoly_BLAKE2b (szfriends_noise.h).

#include "szfriends_noise.h"

#include <string.h>

#include <sodium.h>

#pragma mark - HASH, HMAC, HKDF (spec § 4.3)

void szfriends_noise_hash(const uint8_t *data, size_t length, uint8_t out[SZFRIENDS_NOISE_HASHLEN]) {
    crypto_generichash(out, SZFRIENDS_NOISE_HASHLEN, data, (unsigned long long)length, NULL, 0);
}

// RFC 2104 over BLAKE2b-512 with its 128-byte block. Not BLAKE2b's built-in keyed mode: the spec defines HMAC
// for every hash, and the vectors are computed that way.
void szfriends_noise_hmac(const uint8_t *key, size_t key_length, const uint8_t *data, size_t data_length,
                          uint8_t out[SZFRIENDS_NOISE_HASHLEN]) {
    uint8_t block[SZFRIENDS_NOISE_BLOCKLEN];
    uint8_t inner[SZFRIENDS_NOISE_HASHLEN];
    crypto_generichash_state state;
    size_t i;

    memset(block, 0, sizeof block);
    if (key_length > SZFRIENDS_NOISE_BLOCKLEN) {
        szfriends_noise_hash(key, key_length, block);
    } else if (key_length > 0) {
        memcpy(block, key, key_length);
    }

    for (i = 0; i < sizeof block; i++) {
        block[i] ^= 0x36;
    }
    crypto_generichash_init(&state, NULL, 0, SZFRIENDS_NOISE_HASHLEN);
    crypto_generichash_update(&state, block, sizeof block);
    if (data_length > 0) {
        crypto_generichash_update(&state, data, (unsigned long long)data_length);
    }
    crypto_generichash_final(&state, inner, sizeof inner);

    // 0x36 ^ 0x5c turns the inner pad into the outer pad without keeping the raw key around.
    for (i = 0; i < sizeof block; i++) {
        block[i] ^= 0x36 ^ 0x5c;
    }
    crypto_generichash_init(&state, NULL, 0, SZFRIENDS_NOISE_HASHLEN);
    crypto_generichash_update(&state, block, sizeof block);
    crypto_generichash_update(&state, inner, sizeof inner);
    crypto_generichash_final(&state, out, SZFRIENDS_NOISE_HASHLEN);

    sodium_memzero(block, sizeof block);
    sodium_memzero(inner, sizeof inner);
    sodium_memzero(&state, sizeof state);
}

void szfriends_noise_hkdf(const uint8_t chaining_key[SZFRIENDS_NOISE_HASHLEN], const uint8_t *ikm, size_t ikm_length,
                          uint8_t out1[SZFRIENDS_NOISE_HASHLEN], uint8_t out2[SZFRIENDS_NOISE_HASHLEN],
                          uint8_t *out3) {
    uint8_t temp_key[SZFRIENDS_NOISE_HASHLEN];
    uint8_t input[SZFRIENDS_NOISE_HASHLEN + 1];

    szfriends_noise_hmac(chaining_key, SZFRIENDS_NOISE_HASHLEN, ikm, ikm_length, temp_key);

    input[0] = 0x01;
    szfriends_noise_hmac(temp_key, sizeof temp_key, input, 1, out1);

    memcpy(input, out1, SZFRIENDS_NOISE_HASHLEN);
    input[SZFRIENDS_NOISE_HASHLEN] = 0x02;
    szfriends_noise_hmac(temp_key, sizeof temp_key, input, sizeof input, out2);

    if (out3 != NULL) {
        memcpy(input, out2, SZFRIENDS_NOISE_HASHLEN);
        input[SZFRIENDS_NOISE_HASHLEN] = 0x03;
        szfriends_noise_hmac(temp_key, sizeof temp_key, input, sizeof input, out3);
    }

    sodium_memzero(temp_key, sizeof temp_key);
    sodium_memzero(input, sizeof input);
}

#pragma mark - CipherState (spec § 5.1)

// ChaChaPoly nonce (spec § 12.3): 32 bits of zeros, then the 64-bit counter little-endian.
static void szfriends_noise_nonce(uint64_t n, uint8_t nonce[crypto_aead_chacha20poly1305_ietf_NPUBBYTES]) {
    int i;
    memset(nonce, 0, 4);
    for (i = 0; i < 8; i++) {
        nonce[4 + i] = (uint8_t)(n >> (8 * i));
    }
}

void szfriends_cipher_init(szfriends_cipher_state *cs, const uint8_t *key) {
    sodium_memzero(cs, sizeof *cs);
    if (key != NULL) {
        memcpy(cs->k, key, SZFRIENDS_NOISE_KEYLEN);
        cs->has_key = 1;
    }
}

int szfriends_cipher_encrypt(szfriends_cipher_state *cs, const uint8_t *ad, size_t ad_length, const uint8_t *in,
                             size_t in_length, uint8_t *out, size_t out_capacity, size_t *out_length) {
    uint8_t nonce[crypto_aead_chacha20poly1305_ietf_NPUBBYTES];
    unsigned long long written = 0;

    if (!cs->has_key) {
        if (out_capacity < in_length) {
            return SZFRIENDS_NOISE_ERR_ARGUMENT;
        }
        if (in_length > 0 && out != in) {
            memmove(out, in, in_length);
        }
        *out_length = in_length;
        return SZFRIENDS_NOISE_OK;
    }
    if (cs->n == UINT64_MAX) {
        return SZFRIENDS_NOISE_ERR_NONCE;
    }
    if (in_length > SIZE_MAX - SZFRIENDS_NOISE_TAGLEN || out_capacity < in_length + SZFRIENDS_NOISE_TAGLEN) {
        return SZFRIENDS_NOISE_ERR_ARGUMENT;
    }
    szfriends_noise_nonce(cs->n, nonce);
    crypto_aead_chacha20poly1305_ietf_encrypt(out, &written, in, (unsigned long long)in_length, ad,
                                              (unsigned long long)ad_length, NULL, nonce, cs->k);
    cs->n++;
    *out_length = (size_t)written;
    return SZFRIENDS_NOISE_OK;
}

int szfriends_cipher_decrypt(szfriends_cipher_state *cs, const uint8_t *ad, size_t ad_length, const uint8_t *in,
                             size_t in_length, uint8_t *out, size_t out_capacity, size_t *out_length) {
    uint8_t nonce[crypto_aead_chacha20poly1305_ietf_NPUBBYTES];
    unsigned long long written = 0;

    if (!cs->has_key) {
        if (out_capacity < in_length) {
            return SZFRIENDS_NOISE_ERR_ARGUMENT;
        }
        if (in_length > 0 && out != in) {
            memmove(out, in, in_length);
        }
        *out_length = in_length;
        return SZFRIENDS_NOISE_OK;
    }
    if (cs->n == UINT64_MAX) {
        return SZFRIENDS_NOISE_ERR_NONCE;
    }
    if (in_length < SZFRIENDS_NOISE_TAGLEN) {
        return SZFRIENDS_NOISE_ERR_DECRYPT;
    }
    if (out_capacity < in_length - SZFRIENDS_NOISE_TAGLEN) {
        return SZFRIENDS_NOISE_ERR_ARGUMENT;
    }
    szfriends_noise_nonce(cs->n, nonce);
    if (crypto_aead_chacha20poly1305_ietf_decrypt(out, &written, NULL, in, (unsigned long long)in_length, ad,
                                                  (unsigned long long)ad_length, nonce, cs->k) != 0) {
        return SZFRIENDS_NOISE_ERR_DECRYPT;
    }
    cs->n++;
    *out_length = (size_t)written;
    return SZFRIENDS_NOISE_OK;
}

int szfriends_cipher_rekey(szfriends_cipher_state *cs) {
    uint8_t nonce[crypto_aead_chacha20poly1305_ietf_NPUBBYTES];
    uint8_t zeros[SZFRIENDS_NOISE_KEYLEN];
    uint8_t output[SZFRIENDS_NOISE_KEYLEN + SZFRIENDS_NOISE_TAGLEN];
    unsigned long long written = 0;

    if (!cs->has_key) {
        return SZFRIENDS_NOISE_ERR_STATE;
    }
    memset(zeros, 0, sizeof zeros);
    szfriends_noise_nonce(UINT64_MAX, nonce);
    crypto_aead_chacha20poly1305_ietf_encrypt(output, &written, zeros, sizeof zeros, NULL, 0, NULL, nonce, cs->k);
    memcpy(cs->k, output, SZFRIENDS_NOISE_KEYLEN);
    sodium_memzero(output, sizeof output);
    return SZFRIENDS_NOISE_OK;
}

void szfriends_cipher_clear(szfriends_cipher_state *cs) {
    sodium_memzero(cs, sizeof *cs);
}

#pragma mark - SymmetricState (spec § 5.2)

void szfriends_symmetric_init(szfriends_symmetric_state *ss, const char *protocol_name) {
    size_t length = strlen(protocol_name);
    sodium_memzero(ss, sizeof *ss);
    if (length <= SZFRIENDS_NOISE_HASHLEN) {
        memcpy(ss->h, protocol_name, length);
    } else {
        szfriends_noise_hash((const uint8_t *)protocol_name, length, ss->h);
    }
    memcpy(ss->ck, ss->h, SZFRIENDS_NOISE_HASHLEN);
    szfriends_cipher_init(&ss->cs, NULL);
}

int szfriends_symmetric_mix_key(szfriends_symmetric_state *ss, const uint8_t *ikm, size_t ikm_length) {
    uint8_t ck[SZFRIENDS_NOISE_HASHLEN];
    uint8_t temp_k[SZFRIENDS_NOISE_HASHLEN];
    szfriends_noise_hkdf(ss->ck, ikm, ikm_length, ck, temp_k, NULL);
    memcpy(ss->ck, ck, sizeof ck);
    // HASHLEN 64 > 32: the spec truncates temp_k to the cipher's key length.
    szfriends_cipher_init(&ss->cs, temp_k);
    sodium_memzero(ck, sizeof ck);
    sodium_memzero(temp_k, sizeof temp_k);
    return SZFRIENDS_NOISE_OK;
}

void szfriends_symmetric_mix_hash(szfriends_symmetric_state *ss, const uint8_t *data, size_t length) {
    crypto_generichash_state state;
    crypto_generichash_init(&state, NULL, 0, SZFRIENDS_NOISE_HASHLEN);
    crypto_generichash_update(&state, ss->h, SZFRIENDS_NOISE_HASHLEN);
    if (length > 0) {
        crypto_generichash_update(&state, data, (unsigned long long)length);
    }
    crypto_generichash_final(&state, ss->h, SZFRIENDS_NOISE_HASHLEN);
}

int szfriends_symmetric_encrypt_and_hash(szfriends_symmetric_state *ss, const uint8_t *in, size_t in_length,
                                         uint8_t *out, size_t out_capacity, size_t *out_length) {
    int result = szfriends_cipher_encrypt(&ss->cs, ss->h, SZFRIENDS_NOISE_HASHLEN, in, in_length, out,
                                          out_capacity, out_length);
    if (result == SZFRIENDS_NOISE_OK) {
        szfriends_symmetric_mix_hash(ss, out, *out_length);
    }
    return result;
}

// The hash mixes the ciphertext, which may share a buffer with the plaintext output, so it is mixed first into a
// copy of h and committed only after decryption succeeds.
int szfriends_symmetric_decrypt_and_hash(szfriends_symmetric_state *ss, const uint8_t *in, size_t in_length,
                                         uint8_t *out, size_t out_capacity, size_t *out_length) {
    uint8_t h_before[SZFRIENDS_NOISE_HASHLEN];
    int result;
    memcpy(h_before, ss->h, sizeof h_before);
    szfriends_symmetric_mix_hash(ss, in, in_length);
    result = szfriends_cipher_decrypt(&ss->cs, h_before, sizeof h_before, in, in_length, out, out_capacity,
                                      out_length);
    if (result != SZFRIENDS_NOISE_OK) {
        memcpy(ss->h, h_before, sizeof h_before);
    }
    return result;
}

void szfriends_symmetric_split(szfriends_symmetric_state *ss, szfriends_cipher_state *c1,
                               szfriends_cipher_state *c2) {
    uint8_t temp_k1[SZFRIENDS_NOISE_HASHLEN];
    uint8_t temp_k2[SZFRIENDS_NOISE_HASHLEN];
    szfriends_noise_hkdf(ss->ck, NULL, 0, temp_k1, temp_k2, NULL);
    szfriends_cipher_init(c1, temp_k1);
    szfriends_cipher_init(c2, temp_k2);
    sodium_memzero(temp_k1, sizeof temp_k1);
    sodium_memzero(temp_k2, sizeof temp_k2);
}

void szfriends_symmetric_clear(szfriends_symmetric_state *ss) {
    sodium_memzero(ss, sizeof *ss);
}
