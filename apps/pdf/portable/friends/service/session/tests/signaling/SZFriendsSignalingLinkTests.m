// Download-link payloads: the order nonce, challenge, proof; the gating of the sender until the proof; replays and
// splices between exchanges; and a payload made by WebCrypto (Node's crypto.subtle), as the browser page makes it.

#import <Foundation/Foundation.h>

#import <sodium.h>

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSignalingTests.h"
#import "service/session/SZFriendsSignaling.h"

static NSArray *SZFSTLinkOffer(void) {
    return @[ [SZFriendsSignalItem descriptionWithConnection:0 kind:1 sdp:@"v=0\r\n" fingerprint:SZFBytes(0xc1, 32)] ];
}

static void SZFSTLinkExchange(void) {
    NSData *linkID = SZFRandomBytes(16), *secret = SZFRandomBytes(32);
    SZFriendsSignalingLink *opener = [[SZFriendsSignalingLink alloc] initAsOpener:YES linkID:linkID secret:secret];
    SZFriendsSignalingLink *sender = [[SZFriendsSignalingLink alloc] initAsOpener:NO linkID:linkID secret:secret];
    SZF_CHECK(opener && sender, @"no link exchange");
    SZF_CHECK([[SZFriendsSignalingLink alloc] initAsOpener:YES linkID:SZFRandomBytes(15) secret:secret] == nil,
              @"a short link id accepted");
    NSData *hello = [opener sealItems:SZFSTLinkOffer() error:NULL];
    SZF_CHECK(hello.length > 0 && [opener sealItems:@[] error:NULL] == nil, @"the opener sealed before the challenge");
    NSArray<SZFriendsSignalItem *> *first = [sender openPayload:hello error:NULL];
    SZF_CHECK(first.count == 1 && first[0].type == SZFriendsSignalItemDescription && !sender.proven,
              @"the opener's first payload");
    SZF_CHECK([sender exportKeyWithLabel:@"x"] == nil, @"an export key before the challenge");
    NSData *challenge = [sender sealItems:@[] error:NULL];
    SZF_CHECK(challenge != nil, @"the sender sealed no challenge");
    // Gating: nothing more from the sender until the proof verifies.
    SZFriendsSignalingLink *early = [[SZFriendsSignalingLink alloc] initAsOpener:NO linkID:linkID secret:secret];
    [early openPayload:hello error:NULL];
    [early sealItems:@[] error:NULL];
    SZF_CHECK([early sealItems:SZFSTLinkOffer() error:NULL] == nil, @"the sender sent a description before the proof");
    SZF_CHECK([opener openPayload:challenge error:NULL].count == 0, @"the challenge is the exchange's own item");
    NSData *proof = [opener sealItems:@[ [SZFriendsSignalItem candidateWithConnection:0 technique:3 line:@"c:1"] ]
                                error:NULL];
    NSArray<SZFriendsSignalItem *> *afterProof = [sender openPayload:proof error:NULL];
    SZF_CHECK(sender.proven && afterProof.count == 1 && afterProof[0].type == SZFriendsSignalItemCandidate,
              @"the proof did not verify");
    NSData *answer = [sender sealItems:SZFSTLinkOffer() error:NULL];
    SZF_CHECK([opener openPayload:answer error:NULL].count == 1, @"the sender's answer");
    SZF_CHECK([[opener exportKeyWithLabel:@"probe"] isEqualToData:[sender exportKeyWithLabel:@"probe"]],
              @"export keys differ");
    SZF_CHECK([opener openPayload:answer error:NULL] == nil, @"a replayed payload opened");
    SZF_CHECK([sender openPayload:answer error:NULL] == nil, @"the sender opened its own payload (reflection)");

    // Wrong secret: nothing opens, and nothing is learned.
    SZFriendsSignalingLink *stranger = [[SZFriendsSignalingLink alloc] initAsOpener:YES
                                                                             linkID:linkID
                                                                             secret:SZFRandomBytes(32)];
    SZFriendsSignalingLink *sender2 = [[SZFriendsSignalingLink alloc] initAsOpener:NO linkID:linkID secret:secret];
    SZF_CHECK([sender2 openPayload:[stranger sealItems:@[] error:NULL] error:NULL] == nil, @"wrong secret opened");
    SZFriendsSignalingLink *otherLink = [[SZFriendsSignalingLink alloc] initAsOpener:NO
                                                                              linkID:SZFRandomBytes(16)
                                                                              secret:secret];
    SZF_CHECK([otherLink openPayload:hello error:NULL] == nil, @"a payload opened under another link id");

    // Someone who saw an exchange (the host) replays the opener's payloads into a new one: the first payload elicits a
    // fresh challenge, but the old proof is bound to the old challenge and opens nowhere else.
    SZFriendsSignalingLink *victim = [[SZFriendsSignalingLink alloc] initAsOpener:NO linkID:linkID secret:secret];
    SZF_CHECK([victim openPayload:hello error:NULL] != nil && [victim sealItems:@[] error:NULL] != nil,
              @"a replayed first payload is answered with a challenge");
    SZF_CHECK([victim openPayload:proof error:NULL] == nil && !victim.proven, @"a replayed proof was accepted");
    SZF_CHECK([victim sealItems:SZFSTLinkOffer() error:NULL] == nil, @"the victim revealed something after a replay");
}

// Made by Node's WebCrypto (crypto.subtle): HKDF-SHA-256 of 32 bytes a0..bf with salt 01..10 and info
// "SZFriends link seal v1"; AES-256-GCM with IV 50..5b, associated data "SZFriends link seal v1" 01 00000000; the
// plaintext a LinkNonce of 32 bytes 10..2f and an End item (reason 0).
static void SZFSTLinkWebCrypto(void) {
    NSMutableData *linkID = [NSMutableData dataWithLength:16], *secret = [NSMutableData dataWithLength:32];
    for (int i = 0; i < 16; i++) ((uint8_t *)linkID.mutableBytes)[i] = (uint8_t)(i + 1);
    for (int i = 0; i < 32; i++) ((uint8_t *)secret.mutableBytes)[i] = (uint8_t)(0xa0 + i);
    NSData *payload = SZFHex(@"505152535455565758595a5ba4bc7d7520d93155f5ed260ac750fda12ebf1cdadb045218c49b5f8ac5aa54e3"
                             @"c326ac432be9f789211d465e0dbbf28e3278786b771b947a2d0ad52dd9");
    SZFriendsSignalingLink *sender = [[SZFriendsSignalingLink alloc] initAsOpener:NO linkID:linkID secret:secret];
    NSArray<SZFriendsSignalItem *> *items = [sender openPayload:payload error:NULL];
    SZF_CHECK(items.count == 1 && items[0].type == SZFriendsSignalItemEnd,
              @"a browser's first payload did not open: the derivation or the associated data differ");
}

// The format written out independently of SZFriendsSignalingLink.m, as the browser page implements it: HKDF keys,
// AES-256-GCM with the associated data the header gives, and the proof's HMAC.
static NSData *SZFSTKey(NSData *secret, NSData *linkID, const char *info) {
    uint8_t prk[32];
    crypto_kdf_hkdf_sha256_extract(prk, linkID.bytes, linkID.length, secret.bytes, secret.length);
    NSMutableData *key = [NSMutableData dataWithLength:32];
    crypto_kdf_hkdf_sha256_expand(key.mutableBytes, 32, info, strlen(info), prk);
    return key;
}

static NSData *SZFSTAD(uint8_t direction, uint32_t count, NSArray<NSData *> *context) {
    NSMutableData *ad = [[@"SZFriends link seal v1" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    uint8_t place[5] = {direction, (uint8_t)(count >> 24), (uint8_t)(count >> 16), (uint8_t)(count >> 8),
                        (uint8_t)count};
    [ad appendBytes:place length:5];
    for (NSData *part in context) [ad appendData:part];
    return ad;
}

static NSData *SZFSTOpen(NSData *key, NSData *ad, NSData *payload) {
    NSMutableData *plaintext = [NSMutableData dataWithLength:payload.length];
    unsigned long long length = 0;
    if (crypto_aead_aes256gcm_decrypt(plaintext.mutableBytes, &length, NULL, (const uint8_t *)payload.bytes + 12,
                                      payload.length - 12, ad.bytes, ad.length, payload.bytes, key.bytes) != 0) {
        return nil;
    }
    plaintext.length = (NSUInteger)length;
    return plaintext;
}

static NSData *SZFSTSeal(NSData *key, NSData *ad, NSArray *items) {
    NSData *plaintext = SZFriendsEncodeSignalItems(items, 4000, NULL);
    NSMutableData *payload = [NSMutableData dataWithLength:12 + plaintext.length + 16];
    randombytes_buf(payload.mutableBytes, 12);
    crypto_aead_aes256gcm_encrypt((uint8_t *)payload.mutableBytes + 12, NULL, plaintext.bytes, plaintext.length,
                                  ad.bytes, ad.length, NULL, payload.bytes, key.bytes);
    return payload;
}

static SZFriendsSignalItem *SZFSTProofItem(NSData *proof) {
    return [SZFriendsSignalItem itemWithType:SZFriendsSignalItemLinkProof fields:@{@(SZFriendsSignalTagProof) : proof}];
}

// A sender, its key, the opener's nonce and the sender's challenge, read from the payloads with the format alone.
static SZFriendsSignalingLink *SZFSTChallenged(NSData *linkID, NSData *secret, NSData **nonce, NSData **challenge) {
    NSData *key = SZFSTKey(secret, linkID, "SZFriends link seal v1");
    SZFriendsSignalingLink *opener = [[SZFriendsSignalingLink alloc] initAsOpener:YES linkID:linkID secret:secret];
    SZFriendsSignalingLink *sender = [[SZFriendsSignalingLink alloc] initAsOpener:NO linkID:linkID secret:secret];
    NSData *hello = [opener sealItems:@[] error:NULL];
    [sender openPayload:hello error:NULL];
    *nonce = [SZFriendsDecodeSignalItems(SZFSTOpen(key, SZFSTAD(1, 0, @[]), hello), NULL).firstObject
        dataForTag:SZFriendsSignalTagNonce];
    NSData *challengePayload = [sender sealItems:@[] error:NULL];
    *challenge = [SZFriendsDecodeSignalItems(SZFSTOpen(key, SZFSTAD(2, 0, @[ *nonce ]), challengePayload), NULL)
                      .firstObject dataForTag:SZFriendsSignalTagNonce];
    return sender;
}

static void SZFSTLinkFormat(void) {
    NSData *linkID = SZFRandomBytes(16), *secret = SZFRandomBytes(32), *nonce = nil, *challenge = nil;
    NSData *key = SZFSTKey(secret, linkID, "SZFriends link seal v1");
    NSData *proofKey = SZFSTKey(secret, linkID, "SZFriends link proof v1");
    SZFriendsSignalingLink *sender = SZFSTChallenged(linkID, secret, &nonce, &challenge);
    SZF_CHECK(nonce.length == 32 && challenge.length == 32, @"the nonce and challenge are not where the format says");
    NSMutableData *proofInput = [[@"SZFriends link proof v1" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    for (NSData *part in @[ linkID, nonce, challenge ]) [proofInput appendData:part];
    NSMutableData *proof = [NSMutableData dataWithLength:32];
    crypto_auth_hmacsha256(proof.mutableBytes, proofInput.bytes, proofInput.length, proofKey.bytes);
    NSArray *context = @[ nonce, challenge ];
    SZF_CHECK([sender openPayload:SZFSTSeal(key, SZFSTAD(1, 1, context), @[ SZFSTProofItem(proof) ]) error:NULL] &&
                  sender.proven,
              @"a proof made from the format alone was refused");

    // The proof is checked on its own too: under the right key and context, a wrong one fails.
    sender = SZFSTChallenged(linkID, secret, &nonce, &challenge);
    SZF_CHECK([sender openPayload:SZFSTSeal(key, SZFSTAD(1, 1, @[ nonce, challenge ]),
                                            @[ SZFSTProofItem(SZFRandomBytes(32)) ])
                            error:NULL] == nil &&
                  !sender.proven,
              @"a wrong proof was accepted");
    // The right proof, sealed without the challenge in its context, opens nowhere.
    sender = SZFSTChallenged(linkID, secret, &nonce, &challenge);
    proofInput = [[@"SZFriends link proof v1" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    for (NSData *part in @[ linkID, nonce, challenge ]) [proofInput appendData:part];
    crypto_auth_hmacsha256(proof.mutableBytes, proofInput.bytes, proofInput.length, proofKey.bytes);
    SZF_CHECK([sender openPayload:SZFSTSeal(key, SZFSTAD(1, 1, @[ nonce ]), @[ SZFSTProofItem(proof) ]) error:NULL] ==
                      nil &&
                  !sender.proven,
              @"a payload outside the exchange's context opened");
}

void SZFRunSignalingLinkTests(void) {
    SZFSTLinkExchange();
    SZFSTLinkWebCrypto();
    SZFSTLinkFormat();
}
