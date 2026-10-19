// What libdatachannel and the side path report, turned into the delegate's callbacks in the order the frozen header
// promises: one local description; candidates and at most one end of gathering after it; then streams and route
// changes; at most one failure. Each stack event arrives on one of the stack's threads, is parsed there (nothing
// shared is touched), and continues on the connection's queue, where a closed connection ignores it.

#import "service/online/transport/SZFriendsOnlinePeerConnectionState.h"

#include <rtc/rtc.h>

// How often the selected pair under an open data channel is read again: a relayed connection can settle on a direct
// pair by itself (ADR 0009 step 5), and libdatachannel's C API reports no pair change.
static const NSTimeInterval kRouteInterval = 2;
// Room for a selected-pair candidate string.
enum { kPairBufferSize = 256 };

@implementation SZFriendsOnlinePeerConnection (Events)

#pragma mark - Description and candidates

- (void)stackDidCreateDescription:(NSString *)sdp {
    dispatch_async(self.queue, ^{
        if (self.closed || self.descriptionSent) return;
        // The stack's own description passes the same checks as a remote one; candidates trickle separately.
        SZFriendsOnlineDescription *description = [SZFriendsOnlineDescription descriptionWithSDP:sdp error:NULL];
        if (description == nil) {
            [self failWithError:SZFriendsOnlineMakeError(SZFriendsOnlineErrorUnavailable, @"no usable description")];
            return;
        }
        self.fingerprint = description.fingerprint;
        self.descriptionSent = YES;
        [self.delegate onlineConnection:self
              didCreateLocalDescription:description.sdp
                            fingerprint:description.fingerprint];
        NSArray<NSArray *> *held = [self.heldLocalCandidates copy];
        [self.heldLocalCandidates removeAllObjects];
        for (NSArray *entry in held) {
            if (self.closed) return;
            [self.delegate onlineConnection:self
                    didGatherLocalCandidate:entry[0]
                                  technique:(SZFriendsOnlineTechnique)[entry[1] integerValue]];
        }
        if (self.closed) return;
        if (self.role == SZFriendsOnlineRoleAnswerer) [self bothDescriptionsApplied];
        [self startSidePath];
        [self reportGatheringIfDue];
    });
}

- (void)stackDidGatherCandidate:(NSString *)line {
    SZFriendsOnlineCandidate *candidate = [SZFriendsOnlineCandidate candidateWithLine:line];
    if (candidate == nil) return;
    // The interface is looked up off the queue: getifaddrs walks every address.
    NSString *interface = candidate.type == SZFriendsOnlineCandidateHost
                              ? SZFriendsOnlineInterfaceForAddress(candidate.address)
                              : nil;
    SZFriendsOnlineTechnique technique = SZFriendsOnlineLocalCandidateTechnique(
        candidate, self.purpose, self.kind, interface.UTF8String, self.allowsLoopback);
    uint16_t base = candidate.type == SZFriendsOnlineCandidateHost              ? candidate.port
                    : candidate.type == SZFriendsOnlineCandidateServerReflexive ? candidate.relatedPort
                                                                                : 0;
    dispatch_async(self.queue, ^{
        if (self.closed) return;
        if (self.boundPort == 0 && base != 0) self.boundPort = base;
        if (technique == SZFriendsOnlineTechniqueRelay) self.relayCandidates++;
        if (technique != SZFriendsOnlineTechniqueNone) [self offerLocalCandidate:candidate technique:technique];
    });
}

- (void)stackGatheringDidComplete {
    dispatch_async(self.queue, ^{
        if (self.closed) return;
        self.gatheringFinished = YES;
        // TURN refused the credentials, the quota or the peer, or never answered: there is nothing to relay with.
        if (self.kind == SZFriendsOnlineConnectionRelay && self.relayCandidates == 0) {
            [self failWithError:SZFriendsOnlineMakeError(SZFriendsOnlineErrorRelayRefused, @"no relay allocation")];
            return;
        }
        [self reportGatheringIfDue];
    });
}

- (void)reportGatheringIfDue {
    if (self.closed || !self.descriptionSent || !self.gatheringFinished || self.gatheringReported) return;
    self.gatheringReported = YES;
    [self.delegate onlineConnectionDidFinishGathering:self];
}

#pragma mark - Connection state

- (void)stackICEDidConnect {
    dispatch_async(self.queue, ^{
        if (self.closed) return;
        self.iceConnected = YES;
        [self refreshRoute];
    });
}

- (void)stackStateDidChange:(SZFriendsOnlinePCState)state {
    if (state != SZFriendsOnlinePCStateFailed && state != SZFriendsOnlinePCStateClosed) return;
    dispatch_async(self.queue, ^{
        if (self.closed || self.channelPathDone) return;
        self.channelPathDone = YES;
        NSError *error;
        if (self.streamEverOpened) {
            error = SZFriendsOnlineMakeError(SZFriendsOnlineErrorPeerClosed, @"the peer connection ended");
        } else if (self.kind == SZFriendsOnlineConnectionRelay && self.relayCandidates == 0) {
            error = SZFriendsOnlineMakeError(SZFriendsOnlineErrorRelayRefused, @"no relay allocation");
        } else if (self.iceConnected) {
            // A checked pair existed, so DTLS failed: with both fingerprints authenticated and the SDP checked, the
            // peer's certificate is not the one the signalling named (or the peer gave up mid-handshake).
            error = SZFriendsOnlineMakeError(SZFriendsOnlineErrorFingerprintMismatch, @"DTLS refused the peer");
        } else {
            error = SZFriendsOnlineMakeError(SZFriendsOnlineErrorConnectivityFailed, @"every candidate pair failed");
        }
        self.channelError = error;
        if (self.channelStream != nil && !self.channelStream.ended) [self.channelStream endWithError:error];
        [self stopRouteTimer];
        [self failIfNoPathLeft];
    });
}

// The connection fails only when no path is left: the data channel's peer connection and the side path both ended.
- (void)failIfNoPathLeft {
    if (!self.channelPathDone || (self.sidePath != nil && !self.sidePathDone)) return;
    NSError *error = self.channelError;
    if (self.streamEverOpened) error = SZFriendsOnlineMakeError(SZFriendsOnlineErrorPeerClosed, @"every path ended");
    [self failWithError:error];
}

#pragma mark - The data channel

- (void)stackChannelDidOpen:(int)channel {
    dispatch_async(self.queue, ^{
        if (self.closed) return;
        BOOL ours = self.role == SZFriendsOnlineRoleOfferer ? channel == self.offererChannel
                                                            : self.channelStream == nil;
        if (self.channelStream != nil || !ours) {
            if (channel != self.offererChannel && channel != self.channelStream.channel) [self dropChannel:channel];
            return;
        }
        [self.channels addObject:@(channel)];
        int messageMax = rtcMaxMessageSize(channel);
        SZFriendsOnlineDataChannelStream *stream =
            [[SZFriendsOnlineDataChannelStream alloc] initWithChannel:channel
                                                      connectionQueue:self.queue
                                                           messageMax:messageMax > 0 ? (NSUInteger)messageMax : 0];
        __weak SZFriendsOnlinePeerConnection *weakSelf = self;
        stream.onOwnerClose = ^{
            [weakSelf stopRouteTimer];
        };
        self.channelStream = stream;
        self.channelRoute = [self selectedPairRoute];
        self.streamEverOpened = YES;
        [self.directPhase stop];
        [self startRouteTimer];
        [self.delegate onlineConnection:self didOpenStream:stream route:self.channelRoute];
    });
}

- (void)dropChannel:(int)channel {
    SZFriendsOnlineUnregisterHandle(channel);
    [self.channels removeObject:@(channel)];
    dispatch_async(SZFriendsOnlineTeardownQueue(), ^{
        rtcDelete(channel);
    });
}

- (void)stackChannel:(int)channel didReceive:(NSData *)data {
    dispatch_async(self.queue, ^{
        if (!self.closed && self.channelStream.channel == channel) [self.channelStream channelDidReceive:data];
    });
}

- (void)stackChannelDidReceiveText:(int)channel {
    dispatch_async(self.queue, ^{
        if (self.closed || self.channelStream.channel != channel || self.channelStream.ended) return;
        [self.channelStream endWithError:SZFriendsOnlineMakeError(SZFriendsOnlineErrorPeerClosed, @"text message")];
        [self stopRouteTimer];
        dispatch_async(SZFriendsOnlineTeardownQueue(), ^{
            rtcClose(channel);
        });
    });
}

- (void)stackChannelBufferedAmountLow:(int)channel {
    dispatch_async(self.queue, ^{
        if (!self.closed && self.channelStream.channel == channel) [self.channelStream channelBufferedAmountLow];
    });
}

- (void)stackChannelDidClose:(int)channel {
    dispatch_async(self.queue, ^{
        if (self.closed || self.channelStream.channel != channel) return;
        // The peer closed its end of the channel: an orderly end of this path, not an error.
        [self.channelStream endWithError:nil];
        [self stopRouteTimer];
    });
}

#pragma mark - Routes

- (SZFriendsOnlineRoute)selectedPairRoute {
    char local[kPairBufferSize] = "", remote[kPairBufferSize] = "";
    SZFriendsOnlineCandidate *localCandidate = nil, *remoteCandidate = nil;
    if (rtcGetSelectedCandidatePair(self.peerConnection, local, sizeof local, remote, sizeof remote) >= 0) {
        localCandidate = [SZFriendsOnlineCandidate candidateWithLine:@(local)];
        remoteCandidate = [SZFriendsOnlineCandidate candidateWithLine:@(remote)];
    }
    if (localCandidate == nil || remoteCandidate == nil) {
        // No pair to read (it cannot happen once a channel is open): name the connection's own kind.
        SZFriendsOnlineTechnique technique = self.kind == SZFriendsOnlineConnectionRelay ? SZFriendsOnlineTechniqueRelay
                                             : self.kind == SZFriendsOnlineConnectionProbeHandover
                                                 ? SZFriendsOnlineTechniqueProbeHandover
                                                 : SZFriendsOnlineTechniqueHostPrivate;
        return SZFriendsOnlineRouteMake(technique, NO);
    }
    NSString *localEndpoint = localCandidate.endpoint, *remoteEndpoint = remoteCandidate.endpoint;
    localCandidate = self.localCandidates[localEndpoint] ?: localCandidate;
    remoteCandidate = self.remoteCandidates[remoteEndpoint] ?: remoteCandidate;
    SZFriendsOnlineTechnique localTechnique = [self.localTechniques[localEndpoint] integerValue];
    SZFriendsOnlineTechnique remoteTechnique = [self.remoteTechniques[remoteEndpoint] integerValue];
    SZFriendsOnlineTechnique technique = SZFriendsOnlineTechniqueForPair(localCandidate, localTechnique,
                                                                         remoteCandidate, remoteTechnique, self.kind);
    return SZFriendsOnlineRouteMake(technique, remoteCandidate.ipv6);
}

- (void)refreshRoute {
    SZFriendsOnlineDataChannelStream *stream = self.channelStream;
    if (self.closed || stream == nil || stream.ended) return;
    SZFriendsOnlineRoute route = [self selectedPairRoute];
    SZFriendsOnlineRoute current = self.channelRoute;
    if (route.technique == current.technique && route.ipv6 == current.ipv6) return;
    self.channelRoute = route;
    [self.delegate onlineConnection:self stream:stream didChangeRoute:route];
}

- (void)startRouteTimer {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    uint64_t interval = (uint64_t)(kRouteInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, interval / 2);
    __weak SZFriendsOnlinePeerConnection *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf refreshRoute];
    });
    self.routeTimer = timer;
    dispatch_resume(timer);
}

- (void)stopRouteTimer {
    if (self.routeTimer != nil) dispatch_source_cancel(self.routeTimer);
    self.routeTimer = nil;
}

#pragma mark - Side path (SZFriendsOnlineSidePathEvents)

- (void)startSidePath {
    if (self.sidePath == nil || self.sidePathStarted) return;
    self.sidePathStarted = YES;
    [self.sidePath startWithQueue:self.queue events:self];
    NSArray<NSString *> *held = [self.heldSideCandidates copy];
    [self.heldSideCandidates removeAllObjects];
    for (NSString *line in held) {
        if (self.closed || self.sidePathDone) return;
        [self.sidePath addRemoteCandidate:line error:NULL];
    }
}

- (void)sidePath:(id<SZFriendsOnlineSidePath>)path didGatherLocalCandidate:(NSString *)line {
    if (self.closed || path != self.sidePath) return;
    SZFriendsOnlineCandidate *candidate = [SZFriendsOnlineCandidate candidateWithLine:line];
    if (candidate == nil || !candidate.tcp) return;
    NSString *interface = candidate.type == SZFriendsOnlineCandidateHost
                              ? SZFriendsOnlineInterfaceForAddress(candidate.address)
                              : nil;
    SZFriendsOnlineTechnique technique = SZFriendsOnlineLocalCandidateTechnique(
        candidate, self.purpose, self.kind, interface.UTF8String, self.allowsLoopback);
    if (technique == SZFriendsOnlineTechniqueTCPSimultaneousOpen) {
        [self offerLocalCandidate:candidate technique:technique];
    }
}

- (void)sidePath:(id<SZFriendsOnlineSidePath>)path didOpenStream:(id<SZFriendsByteStream>)stream ipv6:(BOOL)ipv6 {
    if (self.closed || path != self.sidePath || self.sideStream != nil) {
        [stream close];
        return;
    }
    self.sideStream = stream;
    self.sideRoute = SZFriendsOnlineRouteMake(SZFriendsOnlineTechniqueTCPSimultaneousOpen, ipv6);
    self.streamEverOpened = YES;
    [self.directPhase stop];
    [self.delegate onlineConnection:self didOpenStream:stream route:self.sideRoute];
}

- (void)sidePath:(id<SZFriendsOnlineSidePath>)path didFailWithError:(NSError *)error {
    if (self.closed || path != self.sidePath || self.sidePathDone) return;
    (void)error; // the data channel's error says more: the TCP path only ever runs out of time or is refused
    self.sidePathDone = YES;
    [self failIfNoPathLeft];
}

@end
