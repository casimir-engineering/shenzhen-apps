/* Headless check that the vendored libsodium and cJSON build correctly for the helper's target.
 *
 * Known-answer vectors come from RFC 8032 (Ed25519), RFC 7748 (X25519), RFC 8439 (ChaCha20-Poly1305) and
 * RFC 7693 (BLAKE2b), and were recomputed with an independent implementation when vendored. Round trips
 * alone pass on a build whose configuration macros are wrong for the target, because both ends share the
 * mistake: libsodium built with NATIVE_BIG_ENDIAN still signs and verifies its own Ed25519 signatures but
 * fails both RFC 8032 vectors. The vectors catch that here instead of as a handshake that fails only
 * against another Mac. */

#include <sodium.h>

#include "cJSON.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

#define EXPECT(condition, ...)                         \
    do {                                               \
        if (!(condition)) {                            \
            fprintf(stderr, "FAIL " __VA_ARGS__);      \
            fprintf(stderr, " [line %d]\n", __LINE__); \
            ++failures;                                \
        }                                              \
    } while (0)

/* A parser of our own rather than sodium_hex2bin, so a broken libsodium cannot also corrupt the vectors. */
static void from_hex(const char *hex, unsigned char *out, size_t len) {
    size_t i;
    if (strlen(hex) != len * 2) {
        fprintf(stderr, "FAIL vector length for %.16s...\n", hex);
        ++failures;
        memset(out, 0, len);
        return;
    }
    for (i = 0; i < len; i++) {
        unsigned int byte = 0;
        sscanf(hex + 2 * i, "%2x", &byte);
        out[i] = (unsigned char)byte;
    }
}

static int is_all_zero(const unsigned char *bytes, size_t len) {
    size_t i;
    unsigned char acc = 0;
    for (i = 0; i < len; i++) acc |= bytes[i];
    return acc == 0;
}

static void check_version(void) {
    /* Header and archive from the same release: a stale build product would mismatch here. */
    EXPECT(strcmp(sodium_version_string(), SODIUM_VERSION_STRING) == 0, "libsodium version %s vs header %s",
           sodium_version_string(), SODIUM_VERSION_STRING);
    EXPECT(sodium_library_version_major() == SODIUM_LIBRARY_VERSION_MAJOR, "libsodium library major");
    EXPECT(sodium_library_minimal() == 0, "libsodium built minimal; Friends needs the full API");
}

static void check_ed25519(void) {
    static const struct {
        const char *seed, *pk, *msg, *sig;
    } vectors[] = {
        /* RFC 8032 section 7.1, TEST 1 (empty message) and TEST 2 (one byte). */
        {"9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25b"
         "f5f0595bbe24655141438e7a100b"},
        {"4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
         "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
         "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b"
         "2eaeb4302aeeb00d291612bb0c00"},
    };
    unsigned char seed[32], pk[32], sk[64], want_pk[32], want_sig[64], sig[64], msg[2], other_pk[32];
    unsigned char big_msg[1024], signed_msg[1024 + crypto_sign_BYTES], opened[1024];
    unsigned char x_pk[32], x_sk[32], x_from_sk[32];
    unsigned long long siglen = 0, smlen = 0, mlen = 0;
    size_t i;

    for (i = 0; i < sizeof vectors / sizeof vectors[0]; i++) {
        size_t msglen = strlen(vectors[i].msg) / 2;
        from_hex(vectors[i].seed, seed, 32);
        from_hex(vectors[i].pk, want_pk, 32);
        from_hex(vectors[i].sig, want_sig, 64);
        from_hex(vectors[i].msg, msg, msglen);
        from_hex(vectors[1 - i].pk, other_pk, 32);
        crypto_sign_seed_keypair(pk, sk, seed);
        EXPECT(memcmp(pk, want_pk, 32) == 0, "Ed25519 public key, RFC 8032 vector %zu", i + 1);
        EXPECT(crypto_sign_detached(sig, &siglen, msg, msglen, sk) == 0 && siglen == 64, "Ed25519 sign");
        EXPECT(memcmp(sig, want_sig, 64) == 0, "Ed25519 signature, RFC 8032 vector %zu", i + 1);
        EXPECT(crypto_sign_verify_detached(want_sig, msg, msglen, pk) == 0, "Ed25519 verify vector %zu", i + 1);
        /* The verifier must reject a changed message, a changed signature and the wrong key. */
        msg[msglen] = 0x01;
        EXPECT(crypto_sign_verify_detached(want_sig, msg, msglen + 1, pk) != 0, "Ed25519 accepted a longer message");
        sig[63] ^= 0x40;
        EXPECT(crypto_sign_verify_detached(sig, msg, msglen, pk) != 0, "Ed25519 accepted a tampered signature");
        EXPECT(crypto_sign_verify_detached(want_sig, msg, msglen, other_pk) != 0, "Ed25519 accepted the wrong key");
    }

    /* Random keys and a 1 KiB message through the combined form. */
    crypto_sign_keypair(pk, sk);
    randombytes_buf(big_msg, sizeof big_msg);
    EXPECT(crypto_sign(signed_msg, &smlen, big_msg, sizeof big_msg, sk) == 0, "Ed25519 combined sign");
    EXPECT(smlen == sizeof signed_msg, "Ed25519 combined length");
    EXPECT(crypto_sign_open(opened, &mlen, signed_msg, smlen, pk) == 0 && mlen == sizeof big_msg &&
               memcmp(opened, big_msg, sizeof big_msg) == 0,
           "Ed25519 combined round trip");
    signed_msg[crypto_sign_BYTES + 500] ^= 0x01;
    EXPECT(crypto_sign_open(opened, &mlen, signed_msg, smlen, pk) != 0, "Ed25519 opened a tampered message");

    /* An Ed25519 identity converted to X25519 must stay a consistent key pair. */
    EXPECT(crypto_sign_ed25519_pk_to_curve25519(x_pk, pk) == 0, "Ed25519 to X25519 public key");
    EXPECT(crypto_sign_ed25519_sk_to_curve25519(x_sk, sk) == 0, "Ed25519 to X25519 secret key");
    EXPECT(crypto_scalarmult_base(x_from_sk, x_sk) == 0 && memcmp(x_from_sk, x_pk, 32) == 0,
           "converted X25519 keys disagree");
}

static void check_x25519(void) {
    /* RFC 7748 section 6.1. */
    unsigned char a_sk[32], a_pk[32], b_sk[32], b_pk[32], want_shared[32];
    unsigned char pk[32], s1[32], s2[32], zero_point[32] = {0};
    from_hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a", a_sk, 32);
    from_hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", a_pk, 32);
    from_hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb", b_sk, 32);
    from_hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f", b_pk, 32);
    from_hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742", want_shared, 32);

    EXPECT(crypto_scalarmult_base(pk, a_sk) == 0 && memcmp(pk, a_pk, 32) == 0, "X25519 Alice public key");
    EXPECT(crypto_scalarmult_base(pk, b_sk) == 0 && memcmp(pk, b_pk, 32) == 0, "X25519 Bob public key");
    EXPECT(crypto_scalarmult(s1, a_sk, b_pk) == 0 && memcmp(s1, want_shared, 32) == 0, "X25519 shared (Alice)");
    EXPECT(crypto_scalarmult(s2, b_sk, a_pk) == 0 && memcmp(s2, want_shared, 32) == 0, "X25519 shared (Bob)");

    /* A low-order peer point yields an all-zero secret; libsodium must refuse it rather than hand it to a
     * handshake as key material. */
    EXPECT(crypto_scalarmult(s1, a_sk, zero_point) != 0, "X25519 accepted a low-order point");

    randombytes_buf(a_sk, 32);
    randombytes_buf(b_sk, 32);
    crypto_scalarmult_base(a_pk, a_sk);
    crypto_scalarmult_base(b_pk, b_sk);
    EXPECT(crypto_scalarmult(s1, a_sk, b_pk) == 0 && crypto_scalarmult(s2, b_sk, a_pk) == 0, "X25519 random");
    EXPECT(memcmp(s1, s2, 32) == 0 && !is_all_zero(s1, 32), "X25519 random key agreement");
}

static void check_aead(void) {
    /* RFC 8439 section 2.8.2. */
    static const char plaintext[] = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip "
                                    "for the future, sunscreen would be it.";
    enum { PT_LEN = sizeof plaintext - 1, CT_LEN = PT_LEN + crypto_aead_chacha20poly1305_ietf_ABYTES };
    unsigned char key[32], nonce[12], aad[12], want_ct[PT_LEN], want_tag[16];
    unsigned char ct[CT_LEN], pt[PT_LEN], tampered[CT_LEN];
    unsigned long long ct_len = 0, pt_len = 0;
    size_t i;

    for (i = 0; i < 32; i++) key[i] = (unsigned char)(0x80 + i);
    from_hex("070000004041424344454647", nonce, 12);
    from_hex("50515253c0c1c2c3c4c5c6c7", aad, 12);
    from_hex("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b"
             "1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
             "3ff4def08e4b7a9de576d26586cec64b6116",
             want_ct, PT_LEN);
    from_hex("1ae10b594f09e26a7e902ecbd0600691", want_tag, 16);

    EXPECT(crypto_aead_chacha20poly1305_ietf_encrypt(ct, &ct_len, (const unsigned char *)plaintext, PT_LEN, aad,
                                                     sizeof aad, NULL, nonce, key) == 0 &&
               ct_len == CT_LEN,
           "AEAD encrypt");
    EXPECT(memcmp(ct, want_ct, PT_LEN) == 0, "AEAD ciphertext, RFC 8439 2.8.2");
    EXPECT(memcmp(ct + PT_LEN, want_tag, 16) == 0, "AEAD tag, RFC 8439 2.8.2");
    EXPECT(crypto_aead_chacha20poly1305_ietf_decrypt(pt, &pt_len, NULL, ct, ct_len, aad, sizeof aad, nonce, key) ==
                   0 &&
               pt_len == PT_LEN && memcmp(pt, plaintext, PT_LEN) == 0,
           "AEAD decrypt round trip");

    /* Any change to ciphertext, tag, associated data or nonce, or a truncated message, must fail. */
    memcpy(tampered, ct, CT_LEN);
    tampered[7] ^= 0x01;
    EXPECT(crypto_aead_chacha20poly1305_ietf_decrypt(pt, &pt_len, NULL, tampered, CT_LEN, aad, sizeof aad, nonce,
                                                     key) != 0,
           "AEAD accepted tampered ciphertext");
    memcpy(tampered, ct, CT_LEN);
    tampered[CT_LEN - 1] ^= 0x80;
    EXPECT(crypto_aead_chacha20poly1305_ietf_decrypt(pt, &pt_len, NULL, tampered, CT_LEN, aad, sizeof aad, nonce,
                                                     key) != 0,
           "AEAD accepted a tampered tag");
    aad[0] ^= 0x01;
    EXPECT(crypto_aead_chacha20poly1305_ietf_decrypt(pt, &pt_len, NULL, ct, CT_LEN, aad, sizeof aad, nonce, key) != 0,
           "AEAD accepted changed associated data");
    aad[0] ^= 0x01;
    nonce[11] ^= 0x01;
    EXPECT(crypto_aead_chacha20poly1305_ietf_decrypt(pt, &pt_len, NULL, ct, CT_LEN, aad, sizeof aad, nonce, key) != 0,
           "AEAD accepted the wrong nonce");
    nonce[11] ^= 0x01;
    EXPECT(crypto_aead_chacha20poly1305_ietf_decrypt(pt, &pt_len, NULL, ct, CT_LEN - 1, aad, sizeof aad, nonce,
                                                     key) != 0,
           "AEAD accepted a truncated message");
    EXPECT(crypto_aead_chacha20poly1305_ietf_decrypt(pt, &pt_len, NULL, ct, 15, aad, sizeof aad, nonce, key) != 0,
           "AEAD accepted a message shorter than its tag");

    /* An empty payload still authenticates: frames such as acknowledgements may carry no body. */
    crypto_aead_chacha20poly1305_ietf_keygen(key);
    randombytes_buf(nonce, sizeof nonce);
    EXPECT(crypto_aead_chacha20poly1305_ietf_encrypt(ct, &ct_len, NULL, 0, NULL, 0, NULL, nonce, key) == 0 &&
               ct_len == crypto_aead_chacha20poly1305_ietf_ABYTES,
           "AEAD empty encrypt");
    EXPECT(crypto_aead_chacha20poly1305_ietf_decrypt(pt, &pt_len, NULL, ct, ct_len, NULL, 0, nonce, key) == 0 &&
               pt_len == 0,
           "AEAD empty round trip");
}

/* AES-256-GCM seals the helper's download links. libsodium offers it only with hardware support (ARMv8 crypto, or
   AES-NI, PCLMUL and AVX on x86_64), found at run time, so a build that cannot detect it fails here. GCM spec test
   case 14: zero key, zero nonce, 16 zero bytes. */
static void check_aes256gcm(void) {
    unsigned char key[32] = {0}, nonce[12] = {0}, plaintext[16] = {0}, want[32], sealed[32], opened[16];
    unsigned long long sealed_len = 0, opened_len = 0;

    EXPECT(crypto_aead_aes256gcm_is_available() == 1, "AES-256-GCM is not available on this CPU");
    if (!crypto_aead_aes256gcm_is_available()) return;
    from_hex("cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919", want, 32);
    EXPECT(crypto_aead_aes256gcm_encrypt(sealed, &sealed_len, plaintext, 16, NULL, 0, NULL, nonce, key) == 0 &&
               sealed_len == 32 && memcmp(sealed, want, 32) == 0,
           "AES-256-GCM test case 14");
    EXPECT(crypto_aead_aes256gcm_decrypt(opened, &opened_len, NULL, sealed, 32, NULL, 0, nonce, key) == 0 &&
               opened_len == 16 && memcmp(opened, plaintext, 16) == 0,
           "AES-256-GCM opens its own seal");
    sealed[0] ^= 1;
    EXPECT(crypto_aead_aes256gcm_decrypt(opened, &opened_len, NULL, sealed, 32, NULL, 0, nonce, key) != 0,
           "AES-256-GCM opened a changed seal");
}

static void check_blake2b(void) {
    unsigned char out[64], want[64], key[32];
    crypto_generichash_state state;
    size_t i;

    /* RFC 7693 appendix A ("abc"), the empty input, and a keyed 32-byte digest. */
    from_hex("ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc95"
             "18d38aa8dbf1925ab92386edd4009923",
             want, 64);
    EXPECT(crypto_generichash(out, 64, (const unsigned char *)"abc", 3, NULL, 0) == 0 && memcmp(out, want, 64) == 0,
           "BLAKE2b-512(\"abc\"), RFC 7693");
    from_hex("786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b"
             "903a685b1448b755d56f701afe9be2ce",
             want, 64);
    EXPECT(crypto_generichash(out, 64, NULL, 0, NULL, 0) == 0 && memcmp(out, want, 64) == 0, "BLAKE2b-512(\"\")");
    for (i = 0; i < 32; i++) key[i] = (unsigned char)i;
    from_hex("cb6b83547dffe03b714ac298703185f56f38688b4ee62ba5a092b567b0daa39a", want, 32);
    EXPECT(crypto_generichash(out, 32, (const unsigned char *)"Shenzhen Friends", 16, key, 32) == 0 &&
               memcmp(out, want, 32) == 0,
           "keyed BLAKE2b-256");

    /* Streaming in uneven pieces must equal the one-shot digest (file hashes are computed chunk by chunk). */
    crypto_generichash_init(&state, key, 32, 32);
    crypto_generichash_update(&state, (const unsigned char *)"Shen", 4);
    crypto_generichash_update(&state, (const unsigned char *)"", 0);
    crypto_generichash_update(&state, (const unsigned char *)"zhen Friends", 12);
    crypto_generichash_final(&state, out, 32);
    EXPECT(memcmp(out, want, 32) == 0, "streaming BLAKE2b differs from one-shot");
}

static void check_random(void) {
    enum { SAMPLE = 64 * 1024 };
    unsigned char a[32], b[32], seed[randombytes_SEEDBYTES] = {0}, d1[64], d2[64];
    unsigned char *sample = malloc(SAMPLE);
    unsigned long ones = 0, expected = SAMPLE * 4UL, slack = SAMPLE * 8UL / 100;
    int seen[6] = {0};
    size_t i;

    randombytes_buf(a, sizeof a);
    randombytes_buf(b, sizeof b);
    EXPECT(memcmp(a, b, sizeof a) != 0 && !is_all_zero(a, sizeof a) && !is_all_zero(b, sizeof b),
           "randombytes_buf repeated itself or returned zeros");

    /* Half the bits set, within 1%: about seven standard deviations for 524,288 bits, so this never flakes,
     * yet a source stuck on a constant or on one bit per byte fails it. */
    if (sample) {
        randombytes_buf(sample, SAMPLE);
        for (i = 0; i < SAMPLE; i++) {
            unsigned int v = sample[i];
            while (v) {
                ones += v & 1U;
                v >>= 1;
            }
        }
        free(sample);
    }
    EXPECT(ones + slack >= expected && ones <= expected + slack, "random bit balance: %lu of %lu", ones,
           expected * 2);

    for (i = 0; i < 6000; i++) {
        uint32_t v = randombytes_uniform(6);
        if (v < 6) seen[v]++;
        else seen[0] = -100000;
    }
    for (i = 0; i < 6; i++) EXPECT(seen[i] > 0, "randombytes_uniform(6) never produced %zu or went out of range", i);

    randombytes_buf_deterministic(d1, sizeof d1, seed);
    randombytes_buf_deterministic(d2, sizeof d2, seed);
    EXPECT(memcmp(d1, d2, sizeof d1) == 0, "deterministic random differs for one seed");
    seed[0] = 1;
    randombytes_buf_deterministic(d2, sizeof d2, seed);
    EXPECT(memcmp(d1, d2, sizeof d1) != 0, "deterministic random ignores its seed");
}

static void check_cjson(void) {
    /* Escapes, \u escapes for 合同 (contract), nested containers and every scalar type. */
    static const char doc[] = "{ \"v\": 1, \"name\": \"Mei \\u5408\\u540c\", \"tags\": [\"a\", \"b\\n\"],"
                              " \"size\": -42, \"ratio\": 0.5, \"ok\": true, \"none\": null, \"cap\": 8388608 }";
    static const char want_print[] = "{\"v\":1,\"name\":\"Mei \xe5\x90\x88\xe5\x90\x8c\",\"tags\":[\"a\",\"b\\n\"],"
                                     "\"size\":-42,\"ratio\":0.5,\"ok\":true,\"none\":null,\"cap\":8388608}";
    static const char framed[] = "{\"a\":1}\n{\"b\":2}";
    cJSON *root = cJSON_Parse(doc), *again = NULL, *built = NULL, *line = NULL;
    const cJSON *tags;
    char *printed = NULL, *deep = NULL;
    const char *end = NULL;
    size_t i;

    EXPECT(root && cJSON_IsObject(root), "cJSON parse");
    if (!root) return;
    EXPECT(cJSON_GetObjectItemCaseSensitive(root, "v")->valueint == 1, "cJSON integer");
    EXPECT(strcmp(cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(root, "name")),
                  "Mei \xe5\x90\x88\xe5\x90\x8c") == 0,
           "cJSON \\u escape to UTF-8");
    tags = cJSON_GetObjectItemCaseSensitive(root, "tags");
    EXPECT(cJSON_GetArraySize(tags) == 2 && strcmp(cJSON_GetArrayItem(tags, 1)->valuestring, "b\n") == 0,
           "cJSON array and escape");
    EXPECT(cJSON_GetNumberValue(cJSON_GetObjectItemCaseSensitive(root, "size")) == -42.0, "cJSON negative");
    EXPECT(cJSON_GetNumberValue(cJSON_GetObjectItemCaseSensitive(root, "ratio")) == 0.5, "cJSON fraction");
    EXPECT(cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(root, "ok")), "cJSON true");
    EXPECT(cJSON_IsNull(cJSON_GetObjectItemCaseSensitive(root, "none")), "cJSON null");

    printed = cJSON_PrintUnformatted(root);
    EXPECT(printed && strcmp(printed, want_print) == 0, "cJSON print: %s", printed ? printed : "(null)");
    again = printed ? cJSON_Parse(printed) : NULL;
    EXPECT(again && cJSON_Compare(root, again, 1), "cJSON print/parse round trip");
    cJSON_free(printed);
    cJSON_Delete(again);
    cJSON_Delete(root);

    built = cJSON_CreateObject();
    cJSON_AddStringToObject(built, "type", "hello");
    cJSON_AddNumberToObject(built, "protocol", 1);
    printed = cJSON_PrintUnformatted(built);
    EXPECT(printed && strcmp(printed, "{\"type\":\"hello\",\"protocol\":1}") == 0, "cJSON build and print");
    cJSON_free(printed);
    cJSON_Delete(built);

    /* Newline framing hands cJSON a line inside a larger buffer, with no terminating NUL after it. */
    line = cJSON_ParseWithLength(framed, 7);
    EXPECT(line && cJSON_GetObjectItemCaseSensitive(line, "a"), "cJSON parse of a length-bounded line");
    cJSON_Delete(line);
    line = cJSON_ParseWithOpts(framed, &end, 1);
    EXPECT(line == NULL, "cJSON accepted trailing data with require_null_terminated");
    cJSON_Delete(line);

    EXPECT(cJSON_Parse("{\"a\":}") == NULL, "cJSON accepted a missing value");
    EXPECT(cJSON_Parse("[1,2") == NULL, "cJSON accepted an unterminated array");
    EXPECT(cJSON_Parse("\"\\uD800\"") == NULL, "cJSON accepted a lone surrogate");

    /* Hostile nesting must be refused, not recursed into until the stack runs out. */
    deep = malloc(2 * (CJSON_NESTING_LIMIT + 1) + 1);
    if (deep) {
        for (i = 0; i < CJSON_NESTING_LIMIT + 1; i++) {
            deep[i] = '[';
            deep[CJSON_NESTING_LIMIT + 1 + i] = ']';
        }
        deep[2 * (CJSON_NESTING_LIMIT + 1)] = '\0';
        EXPECT(cJSON_Parse(deep) == NULL, "cJSON accepted nesting beyond its limit");
        free(deep);
    }
}

int main(void) {
    EXPECT(sodium_init() == 0, "sodium_init");
    EXPECT(sodium_init() == 1, "sodium_init is not idempotent");
    check_version();
    check_ed25519();
    check_x25519();
    check_aead();
    check_aes256gcm();
    check_blake2b();
    check_random();
    check_cjson();
    if (failures) {
        fprintf(stderr, "SZFriendsDepsTests failed: %d\n", failures);
        return 1;
    }
    puts("SZFriendsDepsTests passed");
    return 0;
}
