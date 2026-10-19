// Known answers and misuse for the Noise core (szfriends_noise.h): HMAC and HKDF against Python's hashlib and hmac,
// Rekey against OpenSSL 3.6.3's ChaCha20, the prologue bytes, nonce exhaustion, all-zero DH, message limits and
// out-of-turn calls. The golden values were computed once with those independent tools (vectors/README.md).

#import <sodium.h>

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

#import "service/session/SZFriendsSecureChannelInternal.h"
#import "service/session/szfriends_noise.h"

static void SZFTestHMACAndHKDF(void) {
    uint8_t key[64], out[64], out2[64], out3[64], longKey[200];
    for (int i = 0; i < 64; i++) {
        key[i] = (uint8_t)i;
    }
    for (int i = 0; i < 200; i++) {
        longKey[i] = (uint8_t)i;
    }
    const char *data = "SZFriends hmac test";
    szfriends_noise_hmac(key, sizeof key, (const uint8_t *)data, strlen(data), out);
    SZF_CHECK([SZFHexString([NSData dataWithBytes:out length:64])
                  isEqualToString:@"1345ee9b8ecb95bdc1406d0825d2c540f500501dcb30be34926a43c3ed05448a"
                                  @"e4e860fdaddcb2cfb8d01fcf4f0f41bdac322f68c85f0a8c4d4de179ceeb9cf3"],
              @"HMAC-BLAKE2b with a 64-byte key");
    szfriends_noise_hmac(longKey, sizeof longKey, (const uint8_t *)data, strlen(data), out);
    SZF_CHECK([SZFHexString([NSData dataWithBytes:out length:64])
                  isEqualToString:@"a8d809e2809e47799fe18cf9dcc1719770fd49f2e6f12fd3225637810d890e1c"
                                  @"a934243ce0b26836e1370ad3d57c2dc3b376d5106d2bf5ea1dacc4e627095e47"],
              @"HMAC-BLAKE2b hashes a key longer than its block");

    uint8_t chainingKey[64], ikm[32];
    memset(chainingKey, 0x42, sizeof chainingKey);
    for (int i = 0; i < 32; i++) {
        ikm[i] = (uint8_t)i;
    }
    szfriends_noise_hkdf(chainingKey, ikm, sizeof ikm, out, out2, out3);
    SZF_CHECK([SZFHexString([NSData dataWithBytes:out length:64])
                  isEqualToString:@"fc81e729b87cab0758eb1b5fb78872aa756c0703c1ba06dd1041c8548bce1b89"
                                  @"a618053708acdd691cba4d1586b59b60c5cd35b00baa11cf8b63754ec1ef9f92"],
              @"HKDF output 1");
    SZF_CHECK([SZFHexString([NSData dataWithBytes:out2 length:64])
                  isEqualToString:@"85aa3d643ca2b49fc5ccae19b6389c553225449f9328c8d0e5e15e428cb652e7"
                                  @"7f2a9e769b408aad334c9fd7769ed89aeaee1c5fb9ac8743137ca45cc214cf2c"],
              @"HKDF output 2");
    SZF_CHECK([SZFHexString([NSData dataWithBytes:out3 length:64])
                  isEqualToString:@"4ffe1dabf6f58d73e26e813c817f4a264a7f589d2436972980c686641b2d0115"
                                  @"adc5fc1e1057ec4c442e54f86db11c45f3da6016431005529d270d1943b8e479"],
              @"HKDF output 3");
    szfriends_noise_hkdf(chainingKey, NULL, 0, out, out2, NULL);
    SZF_CHECK([SZFHexString([NSData dataWithBytes:out length:64])
                  isEqualToString:@"cebc0900ee3289c98a14eb06b3c53e770ce20d2cf6599ac7cb30d9f33bf52785"
                                  @"aca69de375e37f25ab7938709c92d0f97e707e5803c4cb0478c13f285444148c"],
              @"HKDF with empty input (Split)");
}

static void SZFTestRekeyAndNonces(void) {
    uint8_t key[32];
    for (int i = 0; i < 32; i++) {
        key[i] = (uint8_t)i;
    }
    szfriends_cipher_state cs;
    szfriends_cipher_init(&cs, key);
    cs.n = 7;
    SZF_CHECK(szfriends_cipher_rekey(&cs) == SZFRIENDS_NOISE_OK && cs.n == 7, @"Rekey keeps n");
    SZF_CHECK([SZFHexString([NSData dataWithBytes:cs.k length:32])
                  isEqualToString:@"50835543a205b22c9323f2022bc4f67d838f90e61d5ccf33c4513e01f85b5042"],
              @"Rekey = ChaCha20 keystream at nonce 2^64-1, block 1 (OpenSSL cross-check)");
    szfriends_cipher_rekey(&cs);
    SZF_CHECK([SZFHexString([NSData dataWithBytes:cs.k length:32])
                  isEqualToString:@"30fe3726fa0f864af01d15663c77f95e490e30143788af57e90d56fb9aa71609"],
              @"second Rekey");

    // n = 2^64-1 is reserved: the last usable nonce is 2^64-2, after which both directions refuse.
    uint8_t plain[4] = {1, 2, 3, 4}, sealed[4 + 16], opened[4];
    size_t length = 0;
    szfriends_cipher_state sender, receiver;
    szfriends_cipher_init(&sender, key);
    szfriends_cipher_init(&receiver, key);
    sender.n = UINT64_MAX - 1;
    receiver.n = UINT64_MAX - 1;
    SZF_CHECK(szfriends_cipher_encrypt(&sender, NULL, 0, plain, 4, sealed, sizeof sealed, &length) ==
                  SZFRIENDS_NOISE_OK,
              @"nonce 2^64-2 encrypts");
    SZF_CHECK(szfriends_cipher_decrypt(&receiver, NULL, 0, sealed, length, opened, sizeof opened, &length) ==
                  SZFRIENDS_NOISE_OK,
              @"nonce 2^64-2 decrypts");
    SZF_CHECK(szfriends_cipher_encrypt(&sender, NULL, 0, plain, 4, sealed, sizeof sealed, &length) ==
                  SZFRIENDS_NOISE_ERR_NONCE,
              @"nonce 2^64-1 refused on send");
    SZF_CHECK(szfriends_cipher_decrypt(&receiver, NULL, 0, sealed, 20, opened, sizeof opened, &length) ==
                  SZFRIENDS_NOISE_ERR_NONCE,
              @"nonce 2^64-1 refused on receive");

    // A failed decryption leaves n where it was.
    szfriends_cipher_init(&sender, key);
    szfriends_cipher_init(&receiver, key);
    szfriends_cipher_encrypt(&sender, NULL, 0, plain, 4, sealed, sizeof sealed, &length);
    sealed[0] ^= 1;
    SZF_CHECK(szfriends_cipher_decrypt(&receiver, NULL, 0, sealed, length, opened, sizeof opened, &length) ==
                      SZFRIENDS_NOISE_ERR_DECRYPT &&
                  receiver.n == 0,
              @"tampered ciphertext refused, n unchanged");
}

static void SZFTestHandshakeMisuse(void) {
    uint8_t s[32], rs[32], buffer[SZFRIENDS_NOISE_MAX_MESSAGE + 64], payload[SZFRIENDS_NOISE_MAX_MESSAGE];
    randombytes_buf(s, sizeof s);
    randombytes_buf(rs, sizeof rs);
    szfriends_handshake_state hs;
    size_t length = 0;
    SZF_CHECK(szfriends_handshake_init(&hs, SZFRIENDS_NOISE_NN, 1, NULL, 0, s, NULL) == SZFRIENDS_NOISE_ERR_ARGUMENT,
              @"NN refuses a static key");
    SZF_CHECK(szfriends_handshake_init(&hs, SZFRIENDS_NOISE_IK, 1, NULL, 0, s, NULL) == SZFRIENDS_NOISE_ERR_ARGUMENT,
              @"IK initiator needs the responder's static");
    SZF_CHECK(szfriends_handshake_init(&hs, SZFRIENDS_NOISE_IK, 0, NULL, 0, s, rs) == SZFRIENDS_NOISE_ERR_ARGUMENT,
              @"IK responder is not handed a remote static");
    SZF_CHECK(szfriends_handshake_init(&hs, SZFRIENDS_NOISE_XX, 1, NULL, 0, NULL, NULL) ==
                  SZFRIENDS_NOISE_ERR_ARGUMENT,
              @"XX needs a static key");
    SZF_CHECK(szfriends_handshake_init(&hs, (szfriends_noise_pattern)7, 1, NULL, 0, NULL, NULL) ==
                  SZFRIENDS_NOISE_ERR_ARGUMENT,
              @"unknown pattern");

    // Out of turn: the responder cannot write first, and a dead state stays dead.
    SZF_CHECK(szfriends_handshake_init(&hs, SZFRIENDS_NOISE_NN, 0, NULL, 0, NULL, NULL) == SZFRIENDS_NOISE_OK, @"NN");
    SZF_CHECK(szfriends_handshake_write(&hs, NULL, 0, buffer, sizeof buffer, &length) == SZFRIENDS_NOISE_ERR_STATE,
              @"responder writing first");
    SZF_CHECK(szfriends_handshake_read(&hs, buffer, 32, payload, sizeof payload, &length) == SZFRIENDS_NOISE_ERR_STATE,
              @"dead after misuse");

    // The 65,535-byte limit counts keys and tags: XX message 1 is 32 bytes of key plus a plaintext payload.
    szfriends_handshake_init(&hs, SZFRIENDS_NOISE_XX, 1, NULL, 0, s, NULL);
    SZF_CHECK(szfriends_handshake_overhead(&hs) == 32, @"XX message 1 overhead");
    SZF_CHECK(szfriends_handshake_write(&hs, payload, SZFRIENDS_NOISE_MAX_MESSAGE - 31, buffer, sizeof buffer,
                                        &length) == SZFRIENDS_NOISE_ERR_SIZE,
              @"one byte over the message limit");
    szfriends_handshake_init(&hs, SZFRIENDS_NOISE_XX, 1, NULL, 0, s, NULL);
    SZF_CHECK(szfriends_handshake_write(&hs, payload, SZFRIENDS_NOISE_MAX_MESSAGE - 32, buffer, sizeof buffer,
                                        &length) == SZFRIENDS_NOISE_OK &&
                  length == SZFRIENDS_NOISE_MAX_MESSAGE,
              @"exactly the message limit");

    // A low-order remote ephemeral makes X25519 all zeros: the read fails instead of mixing a known secret.
    szfriends_handshake_state responder;
    szfriends_handshake_init(&responder, SZFRIENDS_NOISE_NN, 0, NULL, 0, NULL, NULL);
    uint8_t lowOrder[32] = {0};
    size_t payloadLength = 0;
    SZF_CHECK(szfriends_handshake_read(&responder, lowOrder, 32, payload, sizeof payload, &payloadLength) ==
                  SZFRIENDS_NOISE_OK,
              @"message 1 carries only e");
    SZF_CHECK(szfriends_handshake_write(&responder, NULL, 0, buffer, sizeof buffer, &length) == SZFRIENDS_NOISE_ERR_DH,
              @"all-zero DH refused");

    // Truncated messages: short of the key, or short of the tag once a key exists.
    szfriends_handshake_init(&responder, SZFRIENDS_NOISE_NN, 0, NULL, 0, NULL, NULL);
    SZF_CHECK(szfriends_handshake_read(&responder, buffer, 31, payload, sizeof payload, &payloadLength) ==
                  SZFRIENDS_NOISE_ERR_SIZE,
              @"message shorter than e");
    szfriends_handshake_state initiator;
    szfriends_handshake_init(&initiator, SZFRIENDS_NOISE_NN, 1, NULL, 0, NULL, NULL);
    szfriends_handshake_init(&responder, SZFRIENDS_NOISE_NN, 0, NULL, 0, NULL, NULL);
    szfriends_handshake_write(&initiator, NULL, 0, buffer, sizeof buffer, &length);
    szfriends_handshake_read(&responder, buffer, length, payload, sizeof payload, &payloadLength);
    szfriends_handshake_write(&responder, NULL, 0, buffer, sizeof buffer, &length);
    SZF_CHECK(length == 48, @"NN message 2 is e plus an empty encrypted payload");
    SZF_CHECK(szfriends_handshake_read(&initiator, buffer, 40, payload, sizeof payload, &payloadLength) ==
                  SZFRIENDS_NOISE_ERR_SIZE,
              @"message shorter than its tag");
    szfriends_handshake_clear(&hs);
}

static void SZFTestPrologue(void) {
    NSMutableData *prologue = [NSMutableData dataWithBytes:SZFriendsPrologueLabel length:sizeof SZFriendsPrologueLabel];
    uint8_t preamble[4] = {'S', 'Z', 1, SZFriendsHandshakeIK};
    [prologue appendBytes:preamble length:4];
    SZF_CHECK([SZFHexString(prologue) isEqualToString:@"535a467269656e64732073657373696f6e00535a0101"],
              @"prologue = \"SZFriends session\\0\" || 'S' 'Z' 1 pattern");
}

void SZFRunNoiseUnitTests(void) {
    SZFTestHMACAndHKDF();
    SZFTestRekeyAndNonces();
    SZFTestHandshakeMisuse();
    SZFTestPrologue();
}
