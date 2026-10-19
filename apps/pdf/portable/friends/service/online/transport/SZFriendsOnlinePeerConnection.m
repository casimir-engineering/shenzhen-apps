// One attempt toward one peer: a libdatachannel peer connection, its one data channel and, for a direct connection,
// the side path beside it. This file handles the owner's calls (start, the remote description and candidates,
// injected candidates, close); SZFriendsOnlinePeerConnection+Events.m handles what the stack reports.

#import "service/online/transport/SZFriendsOnlinePeerConnectionState.h"

#include <rtc/rtc.h>

// The data channel's label. The stream is ADR 0001's from its first byte, so nothing depends on the name.
static const char kChannelLabel[] = "szfriends";

@implementation SZFriendsOnlinePeerConnection {
    NSMutableArray<dispatch_block_t> *_cleanups;
}

@synthesize purpose = _purpose;
@synthesize role = _role;
@synthesize kind = _kind;
@synthesize peer = _peer;
@synthesize directPhase = _directPhase;

- (instancetype)initWithRequest:(id<SZFriendsOnlineConnectionRequest>)request
                      transport:(SZFriendsOnlineDataChannelTransport *)transport
                       delegate:(id<SZFriendsOnlineConnectionDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _purpose = request.purpose;
        _role = request.role;
        _kind = request.kind;
        _peer = [request.peer copy];
        _boundPort = request.localPort;
        _queue = queue;
        _delegate = delegate;
        _allowsLoopback = transport.allowsLoopback;
        _bindAddress = [transport.bindAddress copy];
        _peerConnection = -1;
        _offererChannel = -1;
        _heldLocalCandidates = [NSMutableArray array];
        _localCandidates = [NSMutableDictionary dictionary];
        _localTechniques = [NSMutableDictionary dictionary];
        _remoteCandidates = [NSMutableDictionary dictionary];
        _remoteTechniques = [NSMutableDictionary dictionary];
        _heldSideCandidates = [NSMutableArray array];
        _channels = [NSMutableSet set];
        _cleanups = [NSMutableArray array];
        _channelRoute = SZFriendsOnlineRouteMake(SZFriendsOnlineTechniqueNone, NO);
        _sideRoute = _channelRoute;
        if (_kind == SZFriendsOnlineConnectionDirect) {
            _directPhase = [[SZFriendsOnlineDirectPhaseTimer alloc] initWithQueue:queue scheduler:nil];
        }
    }
    return self;
}

- (void)dealloc {
    // Dropped without -close: still release the stack's resources, silently.
    if (!_closed) [self releaseStack];
}

#pragma mark - Properties

- (NSData *)localFingerprint {
    return self.fingerprint ?: [NSData data];
}

- (uint16_t)localPort {
    return self.boundPort;
}

- (SZFriendsOnlineRoute)route {
    BOOL channelOpen = self.channelStream != nil && !self.channelStream.ended;
    BOOL sideOpen = self.sideStream != nil && !self.sidePathDone;
    if (channelOpen && self.channelRoute.method != SZFriendsRouteMethodRelay) return self.channelRoute;
    if (sideOpen) return self.sideRoute;
    if (channelOpen) return self.channelRoute;
    return SZFriendsOnlineRouteMake(SZFriendsOnlineTechniqueNone, NO);
}

#pragma mark - Start

- (BOOL)startWithServerURL:(NSString *)serverURL
                     offer:(SZFriendsOnlineDescription *)offer
                  sidePath:(id<SZFriendsOnlineSidePath>)sidePath
                     error:(NSError **)error {
    rtcConfiguration config;
    memset(&config, 0, sizeof config);
    const char *servers[1] = {serverURL.UTF8String};
    config.iceServers = serverURL ? servers : NULL;
    config.iceServersCount = serverURL ? 1 : 0;
    config.bindAddress = _bindAddress.UTF8String;
    // A relay connection gathers and sends relay candidates only (ADR 0009 step 4).
    config.iceTransportPolicy =
        _kind == SZFriendsOnlineConnectionRelay ? RTC_TRANSPORT_POLICY_RELAY : RTC_TRANSPORT_POLICY_ALL;
    // The exact port asked for (a probe handover's, or one a router mapping was made for), else the system's.
    config.portRangeBegin = self.boundPort;
    config.portRangeEnd = self.boundPort;
    // What this side accepts per message: ADR 0001 records are at most 64 KiB on the wire (ADR 0009).
    config.maxMessageSize = (int)SZFriendsOnlineMessageMax;
    int pc = rtcCreatePeerConnection(&config);
    if (pc < 0) {
        if (error) *error = SZFriendsOnlineMakeError(SZFriendsOnlineErrorUnavailable, @"no peer connection");
        return NO;
    }
    self.peerConnection = pc;
    self.sidePath = sidePath;
    SZFriendsOnlineRegisterHandle(pc, self);
    SZFriendsOnlineInstallPeerCallbacks(pc);
    NSError *failure = nil;
    if (_role == SZFriendsOnlineRoleOfferer) {
        rtcDataChannelInit init;
        memset(&init, 0, sizeof init); // reliable and ordered
        // Creating the channel creates the offer. Its callbacks are installed just after: it cannot open before
        // the answer is applied.
        int dc = rtcCreateDataChannelEx(pc, kChannelLabel, &init);
        if (dc < 0) {
            failure = SZFriendsOnlineMakeError(SZFriendsOnlineErrorUnavailable, @"no data channel");
        } else {
            self.offererChannel = dc;
            [self.channels addObject:@(dc)];
            SZFriendsOnlineRegisterHandle(dc, self);
            SZFriendsOnlineInstallChannelCallbacks(dc);
        }
    } else {
        // The answerer applies the authenticated offer before it gathers (ADR 0011 § Signalling first): setting
        // it creates the answer, and gathering starts only then.
        self.remoteMid = offer.mid;
        if (rtcSetRemoteDescription(pc, offer.sdp.UTF8String, "offer") < 0) {
            failure = SZFriendsOnlineMakeError(self.boundPort != 0 ? SZFriendsOnlineErrorUnavailable
                                                                   : SZFriendsOnlineErrorDescriptionInvalid,
                                               @"the offer could not be applied");
        } else {
            for (NSString *line in offer.candidates) [self applyRemoteCandidate:line technique:0 error:NULL];
        }
    }
    if (failure != nil) {
        self.closed = YES;
        self.delegate = nil;
        [self releaseStack];
        if (error) *error = failure;
        return NO;
    }
    return YES;
}

#pragma mark - Remote input (authenticated exchange only)

- (BOOL)applyRemoteAnswerSDP:(NSString *)sdp remoteFingerprint:(NSData *)fingerprint error:(NSError **)error {
    if (self.closed) {
        if (error) *error = SZFriendsOnlineMakeError(SZFriendsOnlineErrorDescriptionInvalid, @"connection closed");
        return NO;
    }
    NSError *failure = nil;
    SZFriendsOnlineDescription *answer = nil;
    if (_role != SZFriendsOnlineRoleOfferer) {
        failure = SZFriendsOnlineMakeError(SZFriendsOnlineErrorDescriptionInvalid, @"only an offerer takes an answer");
    } else if (self.answerApplied) {
        failure = SZFriendsOnlineMakeError(SZFriendsOnlineErrorDescriptionInvalid, @"answer applied twice");
    } else if ((answer = [SZFriendsOnlineDescription descriptionWithSDP:sdp error:&failure]) == nil) {
        // failure set by the parser
    } else if (fingerprint.length != SZFriendsOnlineFingerprintLength ||
               ![answer.fingerprint isEqualToData:fingerprint]) {
        failure = SZFriendsOnlineMakeError(SZFriendsOnlineErrorFingerprintMismatch,
                                           @"the answer's fingerprint is not the authenticated one");
    } else if (rtcSetRemoteDescription(self.peerConnection, answer.sdp.UTF8String, "answer") < 0) {
        failure = SZFriendsOnlineMakeError(SZFriendsOnlineErrorDescriptionInvalid, @"the answer could not be applied");
    }
    if (failure != nil) {
        if (error) *error = failure;
        [self failWithError:failure deferred:YES];
        return NO;
    }
    self.answerApplied = YES;
    self.remoteMid = answer.mid;
    for (NSString *line in answer.candidates) [self applyRemoteCandidate:line technique:0 error:NULL];
    [self bothDescriptionsApplied];
    return YES;
}

- (BOOL)addRemoteCandidate:(NSString *)candidate technique:(SZFriendsOnlineTechnique)technique error:(NSError **)error {
    NSError *failure = nil;
    if (self.closed) {
        failure = SZFriendsOnlineMakeError(SZFriendsOnlineErrorCandidateRefused, @"connection closed");
    } else if (_role == SZFriendsOnlineRoleOfferer && !self.answerApplied) {
        // Rule 1: an offerer applies nothing remote until IK message 2 has authenticated the responder.
        failure = SZFriendsOnlineMakeError(SZFriendsOnlineErrorNotAuthorized, @"no authenticated answer yet");
    }
    if (failure != nil) {
        if (error) *error = failure;
        return NO;
    }
    return [self applyRemoteCandidate:candidate technique:technique error:error];
}

- (BOOL)applyRemoteCandidate:(NSString *)line technique:(SZFriendsOnlineTechnique)technique error:(NSError **)error {
    SZFriendsOnlineCandidate *candidate = [SZFriendsOnlineCandidate candidateWithLine:line];
    NSString *reason = nil;
    if (candidate == nil) {
        reason = @"malformed candidate";
    } else if (technique < SZFriendsOnlineTechniqueNone || technique > SZFriendsOnlineTechniqueRelay) {
        reason = @"unknown technique";
    } else if (!SZFriendsOnlineMayDialRemoteCandidate(candidate, _purpose, _kind, self.allowsLoopback)) {
        reason = @"an address this connection never dials";
    } else if (self.remoteTechniques[candidate.endpoint] != nil) {
        return YES; // already applied
    } else if (candidate.tcp) {
        if (self.sidePath == nil || self.sidePathDone) {
            reason = @"no TCP path";
        } else if (!self.sidePathStarted) {
            [self.heldSideCandidates addObject:candidate.line];
        } else if (![self.sidePath addRemoteCandidate:candidate.line error:error]) {
            return NO;
        }
    } else if (self.stackCandidates >= SZFriendsOnlineRemoteCandidateMax) {
        reason = @"more candidates than the stack takes";
    } else if (rtcAddRemoteCandidate(self.peerConnection, candidate.line.UTF8String, self.remoteMid.UTF8String) < 0) {
        reason = @"the stack refused the candidate";
    }
    if (reason != nil) {
        if (error) *error = SZFriendsOnlineMakeError(SZFriendsOnlineErrorCandidateRefused, reason);
        return NO;
    }
    if (!candidate.tcp) self.stackCandidates++;
    self.remoteCandidates[candidate.endpoint] = candidate;
    self.remoteTechniques[candidate.endpoint] = @(technique);
    return YES;
}

- (void)remoteCandidatesDidEnd {
    // Nothing to tell the stack: predicted candidates may still follow, and libdatachannel's C API has no
    // end-of-candidates call. The direct-phase timer, not the end of candidates, decides when to move on.
}

#pragma mark - Local candidates

- (void)addLocalCandidate:(NSString *)line technique:(SZFriendsOnlineTechnique)technique {
    if (self.closed) return;
    SZFriendsOnlineCandidate *candidate = [SZFriendsOnlineCandidate candidateWithLine:line];
    if (candidate == nil || candidate.tcp || technique <= SZFriendsOnlineTechniqueNone ||
        technique > SZFriendsOnlineTechniqueRelay) {
        return;
    }
    NSString *interface = candidate.type == SZFriendsOnlineCandidateHost
                              ? SZFriendsOnlineInterfaceForAddress(candidate.address)
                              : nil;
    // The same rules as gathered candidates: a mapping is a reflexive address the purpose may be offered.
    if (SZFriendsOnlineLocalCandidateTechnique(candidate, _purpose, _kind, interface.UTF8String,
                                               self.allowsLoopback) == SZFriendsOnlineTechniqueNone) {
        return;
    }
    [self offerLocalCandidate:candidate technique:technique];
}

- (void)offerLocalCandidate:(SZFriendsOnlineCandidate *)candidate technique:(SZFriendsOnlineTechnique)technique {
    self.localCandidates[candidate.endpoint] = candidate;
    self.localTechniques[candidate.endpoint] = @(technique);
    if (!self.descriptionSent) {
        [self.heldLocalCandidates addObject:@[ candidate.line, @(technique) ]];
        return;
    }
    [self.delegate onlineConnection:self didGatherLocalCandidate:candidate.line technique:technique];
}

- (void)bothDescriptionsApplied {
    // ADR 0011: the timer starts on the offerer when it applies the answer, on the answerer when it sends it.
    [self.directPhase start];
}

#pragma mark - Ending

- (void)addCleanup:(dispatch_block_t)cleanup {
    if (self.closed) {
        cleanup();
        return;
    }
    [_cleanups addObject:[cleanup copy]];
}

- (void)close {
    self.pendingFailureDelegate = nil; // the owner closed before hearing it: nothing after -close
    if (self.closed) return;
    self.closed = YES;
    self.delegate = nil;
    [self endEverythingWithStreamError:nil];
}

- (void)failWithError:(NSError *)error {
    [self failWithError:error deferred:NO];
}

// Deferred when the failure is found inside one of the owner's own calls, so the delegate is not re-entered from it.
- (void)failWithError:(NSError *)error deferred:(BOOL)deferred {
    if (self.closed) return;
    self.closed = YES;
    id<SZFriendsOnlineConnectionDelegate> delegate = self.delegate;
    self.delegate = nil;
    [self endEverythingWithStreamError:error];
    if (!deferred) {
        [delegate onlineConnection:self didFailWithError:error];
        return;
    }
    self.pendingFailureDelegate = delegate;
    dispatch_async(self.queue, ^{
        id<SZFriendsOnlineConnectionDelegate> pending = self.pendingFailureDelegate;
        self.pendingFailureDelegate = nil;
        [pending onlineConnection:self didFailWithError:error];
    });
}

- (void)endEverythingWithStreamError:(NSError *)streamError {
    [self.directPhase stop];
    [self stopRouteTimer];
    if (self.channelStream != nil && !self.channelStream.ended) [self.channelStream endWithError:streamError];
    [self.sidePath close];
    self.sidePath = nil;
    [self releaseStack];
    NSArray<dispatch_block_t> *cleanups = [_cleanups copy];
    [_cleanups removeAllObjects];
    for (dispatch_block_t cleanup in cleanups) cleanup();
}

// Unregisters first, so callbacks still in flight find nothing; libdatachannel's deletion blocks until its
// transports stop, so it runs on the teardown queue, never on the caller's queue or the stack's thread.
- (void)releaseStack {
    int pc = _peerConnection;
    NSSet<NSNumber *> *channels = [_channels copy];
    _peerConnection = -1;
    [_channels removeAllObjects];
    if (pc >= 0) SZFriendsOnlineUnregisterHandle(pc);
    for (NSNumber *channel in channels) SZFriendsOnlineUnregisterHandle(channel.intValue);
    if (pc < 0 && channels.count == 0) return;
    dispatch_async(SZFriendsOnlineTeardownQueue(), ^{
        for (NSNumber *channel in channels) rtcDelete(channel.intValue);
        if (pc >= 0) rtcDeletePeerConnection(pc);
    });
}

@end
