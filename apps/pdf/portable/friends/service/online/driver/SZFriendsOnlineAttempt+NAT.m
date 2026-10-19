// One attempt's NAT techniques (ADR 0011; SZFriendsOnlineAttemptInternal.h): a router port mapping of each direct
// connection's port as a local candidate, predicted ports of a per-destination NAT, and the hard-NAT prober with its
// probe handover connection. The order says when (StartPrediction, StartProbing, StopProbing); this says how.

#import "service/online/driver/SZFriendsOnlineAttemptInternal.h"

#import "service/online/nat/SZFriendsNATPortMapping.h"
#import "service/online/nat/SZFriendsNATPrediction.h"
#import "service/online/nat/SZFriendsNATProber.h"

// Hands a router's mapping to the connection whose port it maps (SZFriendsNATPortMappingDelegate).
@interface SZFriendsOnlineMappingSink : NSObject <SZFriendsNATPortMappingDelegate>
@property(nonatomic, weak) SZFriendsOnlineSlot *slot;
@property(nonatomic, weak) SZFriendsOnlineAttempt *attempt;
@end

@implementation SZFriendsOnlineMappingSink

- (void)portMapping:(SZFriendsNATPortMapping *)mapping
     didMapExternal:(SZFriendsNATEndpoint *)external
           protocol:(SZFriendsNATMappingProtocol)protocol {
    (void)mapping;
    (void)protocol;
    SZFriendsOnlineAttempt *attempt = self.attempt;
    if (attempt == nil || attempt.ended) return;
    [attempt.order noteTechniqueTried:SZFriendsOnlineTechniquePortMapping];
    // The transport offers it through -onlineConnection:didGatherLocalCandidate:..., like a gathered candidate.
    [self.slot.connection addLocalCandidate:SZFriendsNATPortMappingCandidate(external)
                                  technique:SZFriendsOnlineTechniquePortMapping];
}

- (void)portMapping:(SZFriendsNATPortMapping *)mapping didLoseExternal:(SZFriendsNATEndpoint *)external {
    (void)mapping;
    (void)external; // a candidate already sent cannot be withdrawn; its checks simply fail
}

- (void)portMapping:(SZFriendsNATPortMapping *)mapping didFinishWithMappings:(NSUInteger)mapped {
    (void)mapping;
    (void)mapped;
}

@end

// The probes' short-term credentials, from this attempt's authenticated signalling on both sides (ADR 0011 § Probing
// budget): each role's ufrag and password come from its own export, so neither travels.
static void ProbeCredentials(SZFriendsSignalingSession *session, SZFriendsOnlineRole role, NSString **ufrag,
                             NSString **password) {
    NSString *label =
        role == SZFriendsOnlineRoleOfferer ? @"SZFriends probe offerer v1" : @"SZFriends probe answerer v1";
    NSData *key = [session exportKeyWithLabel:label];
    const uint8_t *bytes = key.bytes;
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < key.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    *ufrag = key.length == 32 ? [hex substringToIndex:8] : nil;
    *password = key.length == 32 ? [hex substringFromIndex:16] : nil; // 48 characters
}

@implementation SZFriendsOnlineAttempt (NAT)

#pragma mark - Port mapping (ADR 0011 § Port mapping)

// As soon as the connection's UDP port is bound (its first candidate), never for a relay connection, never in
// loopback tests and never while direct paths are blocked.
- (void)maybeAskPortMappingForSlot:(SZFriendsOnlineSlot *)slot {
    if (slot.portMappingAsked || slot.kind == SZFriendsOnlineConnectionRelay || [_context directPathsBlocked]) return;
    uint16_t port = slot.connection.localPort;
    if (port == 0 || _context.portMappingFactory == nil) return;
    slot.portMappingAsked = YES;
    SZFriendsOnlineMappingSink *sink = [SZFriendsOnlineMappingSink new];
    sink.slot = slot;
    sink.attempt = self;
    id mapping = _context.portMappingFactory(port, sink);
    if (mapping == nil) return;
    slot.portMappingSink = sink; // the mapping holds its delegate weakly
    slot.portMapping = mapping;
    [(SZFriendsNATPortMapping *)mapping start];
}

#pragma mark - Prediction (ADR 0011 § Port prediction)

- (void)startPrediction {
    _predictionPending = YES;
    // The offerer's order tells the answerer, whose order then hears -peerStartedHardNAT.
    if (_role == SZFriendsOnlineRoleOfferer && _direct != nil) {
        [self sendItems:@[ [SZFriendsSignalItem startWithConnection:_direct.number
                                                               kind:SZFriendsOnlineConnectionProbeHandover] ]];
    }
    [self predictIfPossible];
}

// The easy side adds the hard side's next mappings, continuing from its reflexive port in its step, within the
// stack's 30 remote candidates. The hard side predicts nothing.
- (void)predictIfPossible {
    if (!_predictionPending || _direct == nil || !_direct.remoteReady || _direct.remoteReflexive == nil) return;
    if (_context.natClass != SZFriendsNATClassEndpointIndependent || _remoteNAT != SZFriendsNATClassPerDestination) {
        return;
    }
    _predictionPending = NO;
    for (NSString *line in SZFriendsNATPredictedCandidates(_direct.remoteReflexive, _remoteStep,
                                                           _direct.remoteCandidates)) {
        if ([_direct.connection addRemoteCandidate:line technique:SZFriendsOnlineTechniquePredictedPort error:NULL]) {
            _direct.remoteCandidates++;
        }
    }
}

#pragma mark - Probing (ADR 0011 § Probing budget)

- (nullable SZFriendsNATProberConfiguration *)proberConfigurationForRole:(SZFriendsNATProbeRole)role
                                                         remote:(SZFriendsNATEndpoint *)remote {
    NSString *localUfrag = nil, *localPassword = nil, *remoteUfrag = nil, *remotePassword = nil;
    SZFriendsOnlineRole peerRole = _role == SZFriendsOnlineRoleOfferer ? SZFriendsOnlineRoleAnswerer
                                                                       : SZFriendsOnlineRoleOfferer;
    ProbeCredentials(_session, _role, &localUfrag, &localPassword);
    ProbeCredentials(_session, peerRole, &remoteUfrag, &remotePassword);
    if (localUfrag == nil || remoteUfrag == nil || remote == nil) return nil;
    SZFriendsNATProberConfiguration *configuration = [SZFriendsNATProberConfiguration new];
    configuration.role = role;
    configuration.peer = _friend.identityKey;
    configuration.remote = remote;
    // Only what this attempt's authenticated signalling presented (SZFriendsNATProber.h): the easy side aims at the
    // hard side's direct candidates, the hard side at the easy prober's address, which arrived the same way.
    configuration.presented = role == SZFriendsNATProbeRoleEasy ? [_direct.remoteEndpoints copy]
                                                                : (_probeRemote ? @[ _probeRemote ] : nil);
    // Also in loopback tests: behind the NAT emulator the socket's own port is not the one the peer must probe.
    configuration.stunServer = _context.stunPrimary;
    configuration.localUfrag = localUfrag;
    configuration.localPassword = localPassword;
    configuration.remoteUfrag = remoteUfrag;
    configuration.remotePassword = remotePassword;
    configuration.loopbackOnly = _context.loopbackOnly;
    return configuration;
}

// Only one side's NAT maps per destination here (the order checked): that side opens many sockets, the other
// probes random ports of its public address from one socket.
- (void)startProbing {
    if (_prober != nil) return;
    SZFriendsNATClass local = _context.natClass;
    if (local == SZFriendsNATClassPerDestination) {
        // Hard side: waits for the easy prober's own address, which the signalling brings.
        _probeWaitsForRemote = YES;
        if (_probeRemote != nil) [self proberAddressArrived:_probeRemote];
        return;
    }
    SZFriendsNATEndpoint *publicAddress = _direct.remoteReflexive;
    SZFriendsNATProberConfiguration *configuration =
        local == SZFriendsNATClassEndpointIndependent && publicAddress != nil
            ? [self proberConfigurationForRole:SZFriendsNATProbeRoleEasy remote:publicAddress]
            : nil;
    SZFriendsNATProber *prober = configuration ? _context.proberFactory(configuration) : nil;
    if (prober == nil) {
        [self perform:[_order probingEndedRefused:YES]];
        return;
    }
    _prober = prober;
    uint8_t number = _direct ? _direct.number : 0;
    __weak SZFriendsOnlineAttempt *weakSelf = self;
    [prober prepareOnQueue:_context.queue
                completion:^(SZFriendsNATEndpoint *reflexive, NSError *error) {
                    SZFriendsOnlineAttempt *strongSelf = weakSelf;
                    if (strongSelf == nil || strongSelf->_prober != prober) return;
                    if (reflexive == nil) {
                        [strongSelf proberEndedWithError:error];
                        return;
                    }
                    NSString *line = SZFriendsNATCandidateLine(reflexive, SZFriendsNATCandidateTypeServerReflexive,
                                                               NO, 0);
                    [strongSelf sendItems:@[ [SZFriendsSignalItem
                                              candidateWithConnection:number
                                                            technique:SZFriendsOnlineTechniqueProbeHandover
                                                                 line:line] ]];
                    [strongSelf runProber:prober];
                }];
}

- (void)proberAddressArrived:(SZFriendsNATEndpoint *)endpoint {
    _probeRemote = endpoint;
    if (!_probeWaitsForRemote || _prober != nil) return;
    _probeWaitsForRemote = NO;
    SZFriendsNATProberConfiguration *configuration = [self proberConfigurationForRole:SZFriendsNATProbeRoleHard
                                                                               remote:endpoint];
    SZFriendsNATProber *prober = configuration ? _context.proberFactory(configuration) : nil;
    if (prober == nil) {
        [self perform:[_order probingEndedRefused:YES]];
        return;
    }
    _prober = prober;
    [self runProber:prober];
}

- (void)runProber:(SZFriendsNATProber *)prober {
    __weak SZFriendsOnlineAttempt *weakSelf = self;
    [prober startOnQueue:_context.queue
              completion:^(SZFriendsNATProbeHit *hit, NSError *error) {
                  SZFriendsOnlineAttempt *strongSelf = weakSelf;
                  if (strongSelf == nil || strongSelf->_prober != prober) return;
                  strongSelf->_prober = nil;
                  if (hit == nil) {
                      [strongSelf proberEndedWithError:error];
                      return;
                  }
                  [strongSelf probeDidHit:hit];
              }];
}

- (void)proberEndedWithError:(NSError *)error {
    _prober = nil;
    BOOL refused = [error.domain isEqualToString:SZFriendsNATErrorDomain] && error.code == SZFriendsNATErrorBudget;
    [self perform:[_order probingEndedRefused:refused]];
}

// Both sides close every prober socket on a hit; the offerer opens the probe handover connection bound to exactly
// its winning port, and the answerer answers it from its own winning port.
- (void)probeDidHit:(SZFriendsNATProbeHit *)hit {
    _probeHit = hit;
    if (_role == SZFriendsOnlineRoleOfferer) {
        uint8_t number = (uint8_t)MIN(_nextNumber++, (NSUInteger)SZFriendsOnlineConnectionsMax);
        if (number >= SZFriendsOnlineConnectionsMax ||
            [self openSlotOfKind:SZFriendsOnlineConnectionProbeHandover number:number offer:nil relay:nil
                       localPort:hit.localPort] == nil) {
            [self perform:[_order connectionFailed:SZFriendsOnlineConnectionProbeHandover]];
        }
        return;
    }
    [self probeOfferArrived];
}

// Answerer: the offerer's probe handover offer, answered once this side's prober has its pair too.
- (void)probeOfferArrived {
    NSDictionary *pending = _offers[@(SZFriendsOnlineConnectionProbeHandover)];
    if (pending == nil || _probeHit == nil || _role != SZFriendsOnlineRoleAnswerer) return;
    [_offers removeObjectForKey:@(SZFriendsOnlineConnectionProbeHandover)];
    SZFriendsOnlineSlot *slot = [self openSlotOfKind:SZFriendsOnlineConnectionProbeHandover
                                              number:(uint8_t)[pending[@"number"] unsignedIntValue]
                                               offer:pending[@"offer"]
                                               relay:nil
                                           localPort:_probeHit.localPort];
    if (slot == nil) {
        [self perform:[_order connectionFailed:SZFriendsOnlineConnectionProbeHandover]];
        return;
    }
    NSString *line = SZFriendsNATCandidateLine(_probeHit.remote, SZFriendsNATCandidateTypeHost, NO, 65535);
    [slot.connection addRemoteCandidate:line technique:SZFriendsOnlineTechniqueProbeHandover error:NULL];
    [slot.connection remoteCandidatesDidEnd];
}

- (void)stopProbing {
    [_prober cancel];
    _prober = nil;
    _probeWaitsForRemote = NO;
    _predictionPending = NO;
    if (_probe != nil && _probe.openStreams == 0) [self closeSlot:_probe];
}

@end
