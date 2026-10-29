// The Objective-C interop peer's links: the helper's Network.framework stream (SZFriendsNetworkStream), a listener on
// loopback only and dials to 127.0.0.1, with the discovery adapter's TCP options.

#import "SZFSessionPeer.h"

#import "service/discovery/SZFriendsNetworkStream.h"
#import "service/session/SZFriendsSecureChannelInternal.h"

/// TCP without Nagle; on any interface for the device runs of tools/transfer-devices.sh.
static nw_parameters_t SZFTCPParameters(void) {
    return nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, ^(nw_protocol_options_t tcp) {
        nw_tcp_options_set_no_delay(tcp, true);
    });
}

static nw_parameters_t SZFLoopbackParameters(void) {
    nw_parameters_t parameters = SZFTCPParameters();
    nw_parameters_set_required_interface_type(parameters, nw_interface_type_loopback);
    nw_parameters_prohibit_interface_type(parameters, nw_interface_type_wifi);
    nw_parameters_prohibit_interface_type(parameters, nw_interface_type_wired);
    nw_parameters_prohibit_interface_type(parameters, nw_interface_type_cellular);
    nw_parameters_prohibit_interface_type(parameters, nw_interface_type_other);
    return parameters;
}

@implementation SZFPeer (Network)

- (SZFriendsSecureChannel *)responderOnStream:(id<SZFriendsByteStream>)stream {
    NSMutableSet<NSData *> *friends = self.friendKeys, *tokens = self.tokens;
    __weak SZFPeer *weakSelf = self;
    SZFriendsRemoteKeyPolicy policy = ^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *token) {
        if (pattern != SZFriendsHandshakeIK) return YES;
        // Our own other devices, by the chain (SZFSessionPeerDevices.m), as friends are by the list.
        return (key != nil && ([friends containsObject:key] || [weakSelf isOwnDeviceKey:key])) ||
               (token != nil && [tokens containsObject:token]);
    };
    return [[SZFriendsSecureChannel alloc] initAsResponderWithStream:stream
                                                            identity:self.identity
                                                       publicProfile:self.publicProfile
                                                           keyPolicy:policy
                                                               queue:self.queue];
}

- (void)configure:(SZFriendsSecureChannel *)channel {
    if (self.rekeyAfterBytes == 0) return;
    [channel setRekeyAfterBytes:self.rekeyAfterBytes interval:SZFriendsRekeyAfterInterval];
}

- (void)accept:(nw_connection_t)connection {
    SZFriendsNetworkStream *stream = [[SZFriendsNetworkStream alloc] initWithConnection:connection
                                                                        connectionQueue:self.networkQueue];
    [stream connectWithTimeout:10
                         ready:^(NSError *error) {
                             if (error) return;
                             dispatch_async(self.queue, ^{
                                 SZFPeerSession *session = [[SZFPeerSession alloc] init];
                                 session.sessionID = [self nextSessionID];
                                 session.stream = stream;
                                 SZFriendsSecureChannel *channel = [self responderOnStream:stream];
                                 [self configure:channel];
                                 [self attachChannel:channel toSession:session];
                                 [self emit:@{@"event" : @"accepted", @"session" : @(session.sessionID)}];
                                 [channel start];
                             });
                         }];
}

- (NSDictionary *)listenOnAnyInterface:(BOOL)any {
    nw_listener_t listener = nw_listener_create(any ? SZFTCPParameters() : SZFLoopbackParameters());
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block BOOL started = NO;
    nw_listener_set_queue(listener, self.networkQueue);
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        (void)error;
        if (state == nw_listener_state_ready || state == nw_listener_state_failed) {
            started = state == nw_listener_state_ready;
            dispatch_semaphore_signal(ready);
        }
    });
    __weak SZFPeer *weakSelf = self;
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        [weakSelf accept:connection];
    });
    nw_listener_start(listener);
    dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (!started) return @{@"error" : @"the listener did not start"};
    // Kept for the process's life: the scenarios listen once per peer.
    static NSMutableArray *listeners;
    if (listeners == nil) listeners = [NSMutableArray array];
    [listeners addObject:listener];
    return @{@"port" : @(nw_listener_get_port(listener))};
}

- (NSDictionary *)dialWithCommand:(NSDictionary *)command {
    NSString *pattern = command[@"pattern"];
    SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
    options.pattern = [pattern isEqualToString:@"XX"]   ? SZFriendsHandshakeXX
                      : [pattern isEqualToString:@"IK"] ? SZFriendsHandshakeIK
                                                        : SZFriendsHandshakeNN;
    // The route class this side declares as the initiator (it sets chunk size and window); LAN by default.
    NSDictionary *routes = @{
        @"p2p_wifi" : @(SZFriendsRouteMethodPeerToPeerWiFi), @"bluetooth" : @(SZFriendsRouteMethodBluetooth),
        @"internet" : @(SZFriendsRouteMethodInternet), @"relay" : @(SZFriendsRouteMethodRelay)
    };
    NSNumber *route = [command[@"route"] isKindOfClass:[NSString class]] ? routes[command[@"route"]] : nil;
    options.route = route ? (SZFriendsRouteMethod)route.integerValue : SZFriendsRouteMethodLAN;
    options.remoteStaticKey = SZFBytes(command[@"remote_static"]);
    options.expectedIdentityKey = SZFBytes(command[@"expected_identity"]);
    options.requestToken = SZFBytes(command[@"token"]);
    NSData *attestation = SZFBytes(command[@"attestation"]);
    SZFPeerSession *session = [[SZFPeerSession alloc] init];
    session.sessionID = [self nextSessionID];
    if (command[@"lane_of"] != nil) {
        // A lane of a fast session (ADR 0018 § 6): its token from that session's handshake hash, in IK message 1.
        SZFPeerSession *head = self.sessions[@([command[@"lane_of"] unsignedLongLongValue])];
        NSData *token = nil;
        if (head.blocks == nil ||
            [head.blocks reserveLane:session.sessionID route:options.route token:&token] == 0) {
            return @{@"error" : @"no fast session to add a lane to, or past the lanes' limits"};
        }
        options.lane = token;
        session.laneHead = head;
    }
    NSString *port = [command[@"port"] stringValue];
    NSString *host = [command[@"host"] isKindOfClass:[NSString class]] ? command[@"host"] : nil;
    nw_endpoint_t endpoint = nw_endpoint_create_host(host ? host.UTF8String : "127.0.0.1", port.UTF8String);
    nw_connection_t connection = nw_connection_create(endpoint, host ? SZFTCPParameters() : SZFLoopbackParameters());
    SZFriendsNetworkStream *stream = [[SZFriendsNetworkStream alloc] initWithConnection:connection
                                                                        connectionQueue:self.networkQueue];
    session.stream = stream;
    self.sessions[@(session.sessionID)] = session;
    [stream connectWithTimeout:10
                         ready:^(NSError *error) {
                             dispatch_async(self.queue, ^{
                                 if (error) {
                                     [self.sessions removeObjectForKey:@(session.sessionID)];
                                     [self emit:@{@"event" : @"closed", @"session" : @(session.sessionID),
                                                  @"error" : @(SZFriendsSessionErrorStreamClosed)}];
                                     return;
                                 }
                                 SZFriendsSecureChannel *channel =
                                     [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:stream
                                                                                      identity:self.identity
                                                                                       options:options
                                                                                         queue:self.queue];
                                 channel.localAttestation = attestation;
                                 channel.onPublicProfile = ^BOOL(NSDictionary *profile) {
                                     (void)profile;
                                     return YES;
                                 };
                                 [self configure:channel];
                                 [self attachChannel:channel toSession:session];
                                 [channel start];
                             });
                         }];
    return @{@"session" : @(session.sessionID)};
}

@end
