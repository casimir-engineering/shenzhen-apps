// Session limits and error names (SZFriendsSession.h § Limits, § Errors). The numbers are ADR 0001's; the ones
// marked "the spike tunes" there (chunk sizes and windows) change only with a measurement in the journal.

#import "service/session/SZFriendsSession.h"

#import <sodium.h>

const uint8_t SZFriendsSessionMajor = 1;
const NSUInteger SZFriendsNoiseMessageMax = 65535;
// One frame per transport message: the Noise limit minus ChaChaPoly's 16-byte tag.
const NSUInteger SZFriendsFramePlaintextMax = 65535 - 16;
const NSUInteger SZFriendsFrameTextMax = 32768;
const NSUInteger SZFriendsFramePictureMax = 49152;
// SZFriendsThumbnailMaxBytes ("64 KB"): with its id, width and height the frame stays inside one transport message.
const NSUInteger SZFriendsFrameThumbnailMax = 64000;
// SZFriendsDeviceChainEncodedMax: 128 links of at most 495 bytes fit, and the frame stays inside one transport message.
const NSUInteger SZFriendsFrameChainMax = 64000;
// SZFriendsJoinMessageMax: every join message, a welcome's Part included, fits one signalling Frame item online.
const NSUInteger SZFriendsFrameJoinMax = 1000;
// SZFriendsSyncMessageMax: one event of the largest body, or a file part, with its framing.
const NSUInteger SZFriendsFrameSyncMax = 64000;
// SZFriendsAgain messages: a file part with its framing, as SYNC's.
const NSUInteger SZFriendsFrameAgainMax = 64000;
const NSUInteger SZFriendsChunkBytesWiFi = 61440;
const NSUInteger SZFriendsChunkBytesBluetooth = 4096;
const uint64_t SZFriendsSendWindowWiFi = 8ull * 1024 * 1024;
const uint64_t SZFriendsSendWindowBluetooth = 256ull * 1024;
const uint64_t SZFriendsRekeyAfterBytes = 1ull << 30;
const NSTimeInterval SZFriendsRekeyAfterInterval = 900;
const NSTimeInterval SZFriendsSessionMaxAge = 86400;
const NSTimeInterval SZFriendsHandshakeTimeout = 10;
// Longer than any refusal's work under load (a store lookup included), short enough that a refused connection
// holds an admission slot only briefly.
const NSTimeInterval SZFriendsRefusalDelay = 1.5;
const NSTimeInterval SZFriendsReplayWindow = 600;
const uint16_t SZFriendsSessionMinor = 4;
const uint16_t SZFriendsFastTransfersMinor = 4;
// ADR 0018 § 7, as szfriends_wire::consts (KEEPALIVE_MILLISECONDS, SILENCE_MILLISECONDS, SILENCE_BLUETOOTH_...).
const NSTimeInterval SZFriendsKeepaliveInterval = 1;
const NSTimeInterval SZFriendsSilenceLimit = 8;
const NSTimeInterval SZFriendsSilenceLimitBluetooth = 12;
// A host signature (64 bytes), the identity key (32), the Friends ID (at most 64) and a few dates and key ids fit in
// well under half of this; the rest leaves the host area room to grow the format without a session change.
const NSUInteger SZFriendsAttestationMax = 512;
// 750 bytes at most today (SZFriendsSession.h); the rest is room for a few more payload fields, still bounded.
const NSUInteger SZFriendsResponderHandshakeMax = 1024;

static BOOL SZFriendsFastTransfersOff = NO;

static BOOL SZFriendsDirectWiFiBoostOn = NO;

void SZFriendsSetDirectWiFiBoostEnabled(BOOL enabled) {
    SZFriendsDirectWiFiBoostOn = enabled;
}

void SZFriendsSetFastTransfersEnabled(BOOL enabled) {
    SZFriendsFastTransfersOff = !enabled;
}

SZFriendsCapabilities SZFriendsDefaultCapabilities(void) {
    const char *test = getenv("SZFRIENDS_TEST_FAST_TRANSFERS");
    if (SZFriendsFastTransfersOff || (test != NULL && strcmp(test, "0") == 0)) return 0;
    return SZFriendsCapabilityFastTransfers | SZFriendsCapabilityPieces |
           (SZFriendsDirectWiFiBoostOn ? SZFriendsCapabilityDirectWiFiBoost : 0);
}

NSData *SZFriendsLaneToken(NSData *handshakeHash, uint8_t index) {
    if (handshakeHash.length != 64) return nil;
    static const char label[] = "SZFriends lane v1";
    crypto_generichash_state state;
    crypto_generichash_init(&state, handshakeHash.bytes, handshakeHash.length, 16);
    crypto_generichash_update(&state, (const uint8_t *)label, sizeof label - 1);
    crypto_generichash_update(&state, &index, 1);
    uint8_t out[16];
    crypto_generichash_final(&state, out, sizeof out);
    return [NSData dataWithBytes:out length:sizeof out];
}

NSErrorDomain const SZFriendsSessionErrorDomain = @"SZFriendsSessionErrorDomain";
NSString *const SZFriendsSessionCloseReasonKey = @"SZFriendsSessionCloseReason";

NSUInteger SZFriendsChunkBytesForRoute(SZFriendsRouteMethod route) {
    return route == SZFriendsRouteMethodBluetooth ? SZFriendsChunkBytesBluetooth : SZFriendsChunkBytesWiFi;
}

uint64_t SZFriendsSendWindowForRoute(SZFriendsRouteMethod route) {
    return route == SZFriendsRouteMethodBluetooth ? SZFriendsSendWindowBluetooth : SZFriendsSendWindowWiFi;
}
