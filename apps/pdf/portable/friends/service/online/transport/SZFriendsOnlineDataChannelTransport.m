// The transport: checks each request against the pre-authentication rule as far as a request shows it (lead
// decision 6; SZFriendsOnlineTransport.h), then starts one peer connection for it.

#import "service/online/transport/SZFriendsOnlinePeerConnection.h"

#include <rtc/rtc.h>

NSErrorDomain const SZFriendsOnlineErrorDomain = @"SZFriendsOnlineErrorDomain";

void SZFriendsOnlineConfigureStack(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // One worker thread for every peer connection (ADR 0009 § Configuration); the default is one per core. It
        // applies when the pool's threads are spawned, so it must precede the first peer connection. No logger is
        // installed, so libdatachannel and libjuice log nothing: addresses never reach a log (ADR 0011).
        rtcSetThreadPoolSize(1);
    });
}

dispatch_queue_t SZFriendsOnlineTeardownQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("szfriends.online.teardown", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSError *Refused(NSString *reason) {
    return SZFriendsOnlineMakeError(SZFriendsOnlineErrorNotAuthorized, reason);
}

// What the request itself shows of the gating rule; the rest (that signalling authenticated what it carries) is the
// signalling layer's, which is why every remote input still passes the description and candidate rules later.
static NSError *GatingError(id<SZFriendsOnlineConnectionRequest> request) {
    SZFriendsOnlinePurpose purpose = request.purpose;
    if (purpose != SZFriendsOnlinePurposeFriend && purpose != SZFriendsOnlinePurposeFirstContact &&
        purpose != SZFriendsOnlinePurposeLink) {
        return Refused(@"unknown purpose");
    }
    if (request.role != SZFriendsOnlineRoleOfferer && request.role != SZFriendsOnlineRoleAnswerer) {
        return Refused(@"unknown role");
    }
    SZFriendsOnlineConnectionKind kind = request.kind;
    if (kind != SZFriendsOnlineConnectionDirect && kind != SZFriendsOnlineConnectionProbeHandover &&
        kind != SZFriendsOnlineConnectionRelay) {
        return Refused(@"unknown kind");
    }
    // The peer the signalling established: an identity key, or a link id.
    NSUInteger peerLength = purpose == SZFriendsOnlinePurposeLink ? 16 : 32;
    if (request.peer.length != peerLength) return Refused(@"no established peer");
    BOOL answerer = request.role == SZFriendsOnlineRoleAnswerer;
    BOOL hasOffer = request.remoteOfferSDP != nil || request.remoteFingerprint != nil;
    if (answerer && (request.remoteOfferSDP.length == 0 ||
                     request.remoteFingerprint.length != SZFriendsOnlineFingerprintLength)) {
        return Refused(@"an answerer needs the authenticated offer and fingerprint");
    }
    if (!answerer && hasOffer) return Refused(@"an offerer applies nothing remote before the answer");
    BOOL relay = kind == SZFriendsOnlineConnectionRelay;
    if (relay != (request.relay != nil)) {
        return Refused(relay ? @"a relay needs credentials" : @"credentials without a relay");
    }
    if (kind == SZFriendsOnlineConnectionProbeHandover && request.localPort == 0) {
        return Refused(@"a probe handover binds the prober's port");
    }
    // One STUN server, from the signed host list (ADR 0009); a relay connection gathers relay candidates only.
    if (request.stunURI != nil && (relay || !SZFriendsOnlineSTUNURIIsValid(request.stunURI))) {
        return Refused(@"STUN URI refused");
    }
    return nil;
}

@implementation SZFriendsOnlineDataChannelTransport

+ (instancetype)sharedTransport {
    static SZFriendsOnlineDataChannelTransport *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[self alloc] initWithBindAddress:nil allowsLoopback:NO];
    });
    return shared;
}

- (instancetype)initForTestingWithBindAddress:(NSString *)bindAddress {
    return [self initWithBindAddress:bindAddress allowsLoopback:YES];
}

- (instancetype)initWithBindAddress:(NSString *)bindAddress allowsLoopback:(BOOL)allowsLoopback {
    SZFriendsOnlineConfigureStack();
    if ((self = [super init])) {
        _bindAddress = [bindAddress copy];
        _allowsLoopback = allowsLoopback;
    }
    return self;
}

- (id<SZFriendsOnlineConnection>)openConnection:(id<SZFriendsOnlineConnectionRequest>)request
                                       delegate:(id<SZFriendsOnlineConnectionDelegate>)delegate
                                          queue:(dispatch_queue_t)queue
                                          error:(NSError **)error {
    NSError *refusal = GatingError(request);
    NSString *serverURL = nil;
    if (refusal == nil && request.kind == SZFriendsOnlineConnectionRelay) {
        serverURL = SZFriendsOnlineTURNServerURL(request.relay, [NSDate date], &refusal);
    } else if (refusal == nil) {
        serverURL = request.stunURI;
    }
    SZFriendsOnlineDescription *offer = nil;
    if (refusal == nil && request.role == SZFriendsOnlineRoleAnswerer) {
        offer = [SZFriendsOnlineDescription descriptionWithSDP:request.remoteOfferSDP error:&refusal];
        if (offer != nil && ![offer.fingerprint isEqualToData:request.remoteFingerprint]) {
            offer = nil;
            refusal = SZFriendsOnlineMakeError(SZFriendsOnlineErrorFingerprintMismatch,
                                               @"the offer's fingerprint is not the authenticated one");
        }
    }
    if (refusal != nil) {
        if (error) *error = refusal;
        return nil;
    }
    SZFriendsOnlinePeerConnection *connection = [[SZFriendsOnlinePeerConnection alloc] initWithRequest:request
                                                                                             transport:self
                                                                                              delegate:delegate
                                                                                                 queue:queue];
    id<SZFriendsOnlineSidePath> sidePath = nil;
    id<SZFriendsOnlineSidePath> (^factory)(id<SZFriendsOnlineConnectionRequest>) = self.sidePathFactory;
    if (factory && request.kind == SZFriendsOnlineConnectionDirect) sidePath = factory(request);
    if (![connection startWithServerURL:serverURL offer:offer sidePath:sidePath error:error]) return nil;
    return connection;
}

@end
