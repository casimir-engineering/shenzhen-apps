// Every Noise_{NN,XX,IK}_25519_ChaChaPoly_BLAKE2b vector from cacophony and snow, byte for byte: each handshake
// and transport ciphertext, each decrypted payload, and the final handshake hash where the file has one (snow's
// do not). Provenance (URL, commit, license) sits in each vector file and in tests/vectors/README.md. Loading zero
// vectors, or missing a pattern from either source, fails the suite, so a broken filter cannot pass silently.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

#import <sodium.h>

#import "service/session/szfriends_noise.h"

static NSData *SZFVectorHex(NSDictionary *vector, NSString *key) {
    NSString *hex = vector[key];
    return [hex isKindOfClass:[NSString class]] ? SZFHex(hex) : nil;
}

static BOOL SZFPatternForName(NSString *name, szfriends_noise_pattern *pattern) {
    NSDictionary<NSString *, NSNumber *> *names = @{
        @"Noise_NN_25519_ChaChaPoly_BLAKE2b" : @(SZFRIENDS_NOISE_NN),
        @"Noise_XX_25519_ChaChaPoly_BLAKE2b" : @(SZFRIENDS_NOISE_XX),
        @"Noise_IK_25519_ChaChaPoly_BLAKE2b" : @(SZFRIENDS_NOISE_IK),
    };
    NSNumber *value = names[name];
    if (value) {
        *pattern = (szfriends_noise_pattern)value.intValue;
    }
    return value != nil;
}

// Runs one vector; returns NO (after recording failures) on any mismatch.
static BOOL SZFRunVector(NSDictionary *vector, NSString *label) {
    szfriends_noise_pattern pattern;
    if (!SZFPatternForName(vector[@"protocol_name"], &pattern)) {
        SZF_CHECK(NO, @"%@: unexpected protocol %@", label, vector[@"protocol_name"]);
        return NO;
    }
    int failuresBefore = SZFTestFailures;
    NSData *initPrologue = SZFVectorHex(vector, @"init_prologue");
    NSData *respPrologue = SZFVectorHex(vector, @"resp_prologue");
    NSData *initStatic = SZFVectorHex(vector, @"init_static");
    NSData *respStatic = SZFVectorHex(vector, @"resp_static");
    NSData *initRemote = SZFVectorHex(vector, @"init_remote_static");
    szfriends_handshake_state initiator, responder;
    SZF_CHECK(szfriends_handshake_init(&initiator, pattern, 1, initPrologue.bytes, initPrologue.length,
                                       initStatic.bytes, pattern == SZFRIENDS_NOISE_IK ? initRemote.bytes : NULL) ==
                  SZFRIENDS_NOISE_OK,
              @"%@: initiator init", label);
    SZF_CHECK(szfriends_handshake_init(&responder, pattern, 0, respPrologue.bytes, respPrologue.length,
                                       respStatic.bytes, NULL) == SZFRIENDS_NOISE_OK,
              @"%@: responder init", label);
    szfriends_handshake_set_fixed_ephemeral(&initiator, SZFVectorHex(vector, @"init_ephemeral").bytes);
    szfriends_handshake_set_fixed_ephemeral(&responder, SZFVectorHex(vector, @"resp_ephemeral").bytes);

    int handshakeMessages = szfriends_handshake_message_count(pattern);
    szfriends_cipher_state initSend, initReceive, respSend, respReceive;
    NSArray<NSDictionary *> *messages = vector[@"messages"];
    SZF_CHECK(messages.count > (NSUInteger)handshakeMessages, @"%@: too few messages", label);
    uint8_t buffer[SZFRIENDS_NOISE_MAX_MESSAGE], plain[SZFRIENDS_NOISE_MAX_MESSAGE];
    for (NSUInteger i = 0; i < messages.count; i++) {
        NSData *payload = SZFVectorHex(messages[i], @"payload");
        NSData *expected = SZFVectorHex(messages[i], @"ciphertext");
        BOOL fromInitiator = i % 2 == 0;
        size_t written = 0, read = 0;
        int writeResult, readResult;
        if (i < (NSUInteger)handshakeMessages) {
            szfriends_handshake_state *writer = fromInitiator ? &initiator : &responder;
            szfriends_handshake_state *reader = fromInitiator ? &responder : &initiator;
            writeResult = szfriends_handshake_write(writer, payload.bytes, payload.length, buffer, sizeof buffer,
                                                    &written);
            readResult = szfriends_handshake_read(reader, buffer, written, plain, sizeof plain, &read);
        } else {
            szfriends_cipher_state *sender = fromInitiator ? &initSend : &respSend;
            szfriends_cipher_state *receiver = fromInitiator ? &respReceive : &initReceive;
            writeResult = szfriends_cipher_encrypt(sender, NULL, 0, payload.bytes, payload.length, buffer,
                                                   sizeof buffer, &written);
            readResult = szfriends_cipher_decrypt(receiver, NULL, 0, buffer, written, plain, sizeof plain, &read);
        }
        NSData *ciphertext = [NSData dataWithBytes:buffer length:written];
        SZF_CHECK(writeResult == SZFRIENDS_NOISE_OK && [ciphertext isEqualToData:expected],
                  @"%@: message %lu ciphertext %@, expected %@", label, (unsigned long)i, SZFHexString(ciphertext),
                  SZFHexString(expected));
        SZF_CHECK(readResult == SZFRIENDS_NOISE_OK && [[NSData dataWithBytes:plain length:read] isEqualToData:payload],
                  @"%@: message %lu payload", label, (unsigned long)i);
        if (i + 1 == (NSUInteger)handshakeMessages) {
            uint8_t initHash[64], respHash[64];
            szfriends_handshake_hash(&initiator, initHash);
            szfriends_handshake_hash(&responder, respHash);
            SZF_CHECK(memcmp(initHash, respHash, 64) == 0, @"%@: handshake hashes differ", label);
            NSData *expectedHash = SZFVectorHex(vector, @"handshake_hash");
            if (expectedHash) {
                SZF_CHECK([[NSData dataWithBytes:initHash length:64] isEqualToData:expectedHash],
                          @"%@: handshake hash", label);
            }
            if (pattern != SZFRIENDS_NOISE_NN) {
                const uint8_t *learned = szfriends_handshake_remote_static(&responder);
                uint8_t initStaticPublic[32];
                crypto_scalarmult_base(initStaticPublic, initStatic.bytes);
                SZF_CHECK(learned && memcmp(learned, initStaticPublic, 32) == 0, @"%@: responder's rs", label);
            }
            SZF_CHECK(szfriends_handshake_split(&initiator, &initSend, &initReceive) == SZFRIENDS_NOISE_OK &&
                          szfriends_handshake_split(&responder, &respSend, &respReceive) == SZFRIENDS_NOISE_OK,
                      @"%@: split", label);
        }
    }
    szfriends_handshake_clear(&initiator);
    szfriends_handshake_clear(&responder);
    return SZFTestFailures == failuresBefore;
}

void SZFRunNoiseVectorTests(NSString *vectorDirectory) {
    NSArray<NSString *> *sources = @[ @"cacophony", @"snow" ];
    NSUInteger total = 0;
    for (NSString *source in sources) {
        NSString *path = [vectorDirectory
            stringByAppendingPathComponent:[source stringByAppendingString:@"-25519-chachapoly-blake2b.json"]];
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSDictionary *document = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSDictionary *provenance = document[@"provenance"];
        SZF_CHECK([provenance[@"commit"] length] == 40 && [provenance[@"license"] length] > 0,
                  @"%@: provenance with commit and license", source);
        NSMutableSet<NSString *> *patterns = [NSMutableSet set];
        NSUInteger loaded = 0;
        for (NSDictionary *vector in document[@"vectors"]) {
            NSString *label = [NSString stringWithFormat:@"%@ %@", source, vector[@"protocol_name"]];
            if (SZFRunVector(vector, label)) {
                [patterns addObject:vector[@"protocol_name"]];
            }
            loaded++;
        }
        SZF_CHECK(loaded > 0, @"%@: zero vectors loaded from %@", source, path);
        SZF_CHECK(patterns.count == 3, @"%@: NN, XX and IK must each pass at least once (%@)", source, patterns);
        total += loaded;
    }
    SZF_CHECK(total >= 6, @"only %lu Noise vectors loaded", (unsigned long)total);
    printf("noise vectors: %lu checked\n", (unsigned long)total);
}
