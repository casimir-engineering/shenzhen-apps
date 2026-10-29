// friends-helper-check, orchestration part: what the files of the nearby test binary share. The binary links the
// helper's own objects and every service area's, and runs without radios, sockets to other machines or a host:
// services open on temporary state directories with the file key store, adapters are scripted, channels are fakes.

#import <Foundation/Foundation.h>

#import "service/helper/SZFriendsHelperServices.h"
#import "service/helper/nearby/SZFriendsNearbyInternal.h"

NS_ASSUME_NONNULL_BEGIN

extern int SZFNFailures;
#define EXPECT(cond, ...)                                                                                          \
    do {                                                                                                           \
        if (!(cond)) {                                                                                             \
            SZFNFailures++;                                                                                        \
            fprintf(stderr, "%s:%d: expected %s %s\n", __FILE__, __LINE__, #cond,                                  \
                    [[NSString stringWithFormat:@"" __VA_ARGS__] UTF8String]);                                     \
        }                                                                                                          \
    } while (0)

// Services opened on a new state directory under `scratch` (file key store, never the Keychain); nil when they
// could not open, after recording a failure.
SZFriendsHelperServices *_Nullable SZFNOpenServices(NSString *scratch, NSString *name);
// Runs the main run loop (the helper's queue in these tests) for `seconds`.
void SZFNSpin(NSTimeInterval seconds);
// A person saved in the store with fresh keys and the given relation.
SZFriendsPersonRecord *SZFNSavePerson(SZFriendsStore *store, SZFriendsRelation relation);

// A stand-in for SZFriendsSecureChannel where a test needs a link but no handshake: answers what the orchestration
// asks of a link's channel and records how it was closed.
@interface SZFNFakeChannel : NSObject
@property(nonatomic) SZFriendsHandshakePattern pattern;
@property(nonatomic) BOOL isInitiator;
@property(nonatomic, readonly) BOOL closed;
- (void)closeWithReason:(SZFriendsCloseReason)reason;
- (void)close;
- (SZFriendsSecureChannel *)asChannel;
@end

// What the NN, request and frame paths also ask of a fake channel (SZFriendsHelperNearbyLinkTests.m): a handshake
// hash, the frames sent on it, and no remote keys.
@interface SZFNFakeChannel (Session)
@property(nonatomic, copy, nullable) NSData *handshakeHash;
@property(nonatomic, readonly) NSMutableArray<SZFriendsFrame *> *sent;
@property(nonatomic, readonly, nullable) NSData *remoteIdentityKey;
@property(nonatomic, readonly, nullable) NSData *remoteStaticKey;
// The Attestation field of the payload the key policy is asked about (nil unless a test sets one).
@property(nonatomic, copy, nullable) NSData *remoteAttestation;
- (BOOL)sendFrame:(SZFriendsFrame *)frame;
// Liveness while a transfer runs (ADR 0018 § 7): a fake link never goes silent, so this does nothing.
- (void)setLivenessKeepalive:(BOOL)keepalive watch:(BOOL)watch;
@property(nonatomic, readonly) BOOL fastTransfers; // NO: fakes move files by CHUNK
@end

// A link for a fake channel, as a listener would have accepted it.
SZFriendsPeerLink *SZFNLink(SZFNFakeChannel *channel);
SZFriendsNearbyService *SZFNNearbyWith(SZFriendsHelperServices *services, NSArray *adapters);
NSData *SZFNBytes(NSUInteger count);
// A signed host list naming `url` and the pinned keys it verifies with; a file written under `directory`.
void SZFNMakeList(NSString *url, NSData *_Nonnull *_Nonnull list, NSData *_Nonnull *_Nonnull keys);
NSString *SZFNWrite(NSString *directory, NSString *name, NSData *data);

// A discovery adapter that records what it was asked to advertise and never touches a radio.
@interface SZFNRecordingAdapter : NSObject <SZFriendsDiscoveryAdapter>
@property(nonatomic, readonly) NSUInteger advertisements;
@property(nonatomic, readonly, nullable) NSData *lastTag;
@property(nonatomic, readonly) NSArray<NSData *> *lastCallbackTags;
@property(nonatomic, readonly) BOOL lastPublicEntry;
@property(nonatomic, readonly, nullable) SZFriendsAdmissionLimits *admissionLimits;
@end

void SZFNTestCallbackSecrets(NSString *scratch);
void SZFNTestAdmissionLimits(NSString *scratch);
void SZFNTestPresenceSecretOnlyToFriends(NSString *scratch);
void SZFNTestStrangerPictures(NSString *scratch);
void SZFNTestFoundMethods(NSString *scratch);
void SZFNTestKeyPolicy(NSString *scratch);
void SZFNTestFriendsChains(NSString *scratch);
void SZFNTestOwnChainToFriends(NSString *scratch);
void SZFNTestOwnDeviceSync(NSString *scratch);
void SZFNTestOwnDeviceRouteMigration(NSString *scratch);
void SZFNTestFriendDevices(NSString *scratch);
void SZFNTestIdleClose(NSString *scratch);
void SZFNTestResetOrder(NSString *scratch);
void SZFNTestStrangerCap(NSString *scratch);
void SZFNTestStrangerFrames(NSString *scratch);
void SZFNTestStrangerLifetime(NSString *scratch);
void SZFNTestPendingRequestKeys(NSString *scratch);
void SZFNTestRequestCodes(NSString *scratch);
void SZFNTestRequestExpiry(NSString *scratch);
void SZFNTestAnswerAttestationVerdicts(NSString *scratch);
void SZFNTestCallbackShowsAttestation(NSString *scratch);
void SZFNTestAttestedAnswers(NSString *scratch);
void SZFNTestResetForgetsAttestation(NSString *scratch);
void SZFNTestUnconfirmedAcceptIsARequest(NSString *scratch);
void SZFNTestOutgoingRequestKeys(NSString *scratch);
void SZFNTestNNPerAddress(NSString *scratch);
void SZFNTestWrittenBeforeSend(NSString *scratch);
void SZFNTestDialRank(NSString *scratch);
void SZFNTestOnlineDelegate(NSString *scratch);
void SZFNTestOnlineReach(NSString *scratch);
void SZFNTestByIDOnline(NSString *scratch);
void SZFNTestJoin(NSString *scratch);
void SZFNTestDevices(NSString *scratch);
void SZFNTestAgain(NSString *scratch);
void SZFNTestFirstContact(NSString *scratch);
void SZFNTestLoopbackICE(void);

NS_ASSUME_NONNULL_END
