// Router port mapping: PCP, NAT-PMP, then UPnP (SZFriendsNATPortMapping.h).

#import "service/online/nat/SZFriendsNATPortMapping.h"

#import "service/online/nat/SZFriendsNATExchange.h"
#import "service/online/nat/SZFriendsNATPCP.h"
#import "service/online/nat/SZFriendsNATRoute.h"
#import "service/online/nat/SZFriendsNATUPnP.h"

#include <netinet/in.h>
#include <string.h>
#include <time.h>

@implementation SZFriendsNATPortMappingConfiguration

- (instancetype)init {
    if ((self = [super init])) {
        _serverPort = SZFriendsPCPPort;
        _lifetime = 7200;
        _retransmits = @[ @0.25, @0.5, @1.0 ];
        _exchangeBudget = 2;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    SZFriendsNATPortMappingConfiguration *copy = [[[self class] allocWithZone:zone] init];
    copy.internalPort = _internalPort;
    copy.gatewayIPv4 = _gatewayIPv4;
    copy.localIPv4 = _localIPv4;
    copy.gatewayIPv6 = _gatewayIPv6;
    copy.globalIPv6 = _globalIPv6;
    copy.serverPort = _serverPort;
    copy.lifetime = _lifetime;
    copy.retransmits = _retransmits;
    copy.exchangeBudget = _exchangeBudget;
    copy.upnp = _upnp;
    copy.loopbackOnly = _loopbackOnly;
    return copy;
}

+ (instancetype)configurationForPort:(uint16_t)port {
    SZFriendsNATRoute *route4 = [SZFriendsNATRoute defaultRouteForFamily:AF_INET];
    SZFriendsNATRoute *route6 = [SZFriendsNATRoute defaultRouteForFamily:AF_INET6];
    SZFriendsNATPortMappingConfiguration *configuration = [[self alloc] init];
    configuration.internalPort = port;
    if (route4.physical && route4.gateway.family == AF_INET && route4.localAddress != nil) {
        configuration.gatewayIPv4 = route4.gateway;
        configuration.localIPv4 = route4.localAddress;
        configuration.upnp = [SZFriendsNATUPnP discoveryOnInterface:route4.interfaceName gateway:route4.gateway];
    }
    if (route6.physical && route6.gateway.family == AF_INET6 &&
        route6.localAddress.scope == SZFriendsNATAddressScopeGlobal) {
        configuration.gatewayIPv6 = route6.gateway;
        configuration.globalIPv6 = route6.localAddress;
    }
    return configuration.gatewayIPv4 != nil || configuration.gatewayIPv6 != nil ? configuration : nil;
}

@end

static double MonotonicSeconds(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
}

// One family's mapping through PCP or NAT-PMP.
@interface SZFriendsNATGatewayMapping : NSObject
@property(nonatomic, strong) SZFriendsNATExchange *exchange;
@property(nonatomic, strong) SZFriendsNATEndpoint *client; // our address as the gateway sees it
@property(nonatomic) SZFriendsNATMappingProtocol protocol;
@property(nonatomic, strong, nullable) SZFriendsNATEndpoint *external;
@property(nonatomic, strong, nullable) dispatch_source_t renewal;
@property(nonatomic) BOOL finished;
@end

@implementation SZFriendsNATGatewayMapping {
@public
    uint8_t nonce[SZFriendsPCPNonceLength];
    SZFriendsNATEpoch epoch;
    uint8_t externalIPv4[4]; // NAT-PMP's external address answer
}
@end

@implementation SZFriendsNATPortMapping {
    SZFriendsNATPortMappingConfiguration *_configuration;
    __weak id<SZFriendsNATPortMappingDelegate> _delegate;
    dispatch_queue_t _queue;
    SZFriendsNATGatewayMapping *_v4, *_v6;
    NSMutableArray<SZFriendsNATEndpoint *> *_upnpMapped;
    dispatch_source_t _upnpRenewal;
    BOOL _upnpRunning, _upnpDone, _started, _closed, _reportedFinish, _remapped;
}

- (instancetype)initWithConfiguration:(SZFriendsNATPortMappingConfiguration *)configuration
                             delegate:(id<SZFriendsNATPortMappingDelegate>)delegate
                                queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _configuration = [configuration copy];
        _delegate = delegate;
        _queue = queue;
        _upnpMapped = [NSMutableArray array];
    }
    return self;
}

- (NSArray<SZFriendsNATEndpoint *> *)externalEndpoints {
    NSMutableArray<SZFriendsNATEndpoint *> *all = [NSMutableArray array];
    if (_v4.external != nil) [all addObject:_v4.external];
    if (_v6.external != nil) [all addObject:_v6.external];
    [all addObjectsFromArray:_upnpMapped];
    return all;
}

- (BOOL)allowsGateway:(SZFriendsNATEndpoint *)gateway {
    if (gateway == nil) return NO;
    if (_configuration.loopbackOnly) return SZFriendsNATLoopbackOnlyAllows(gateway);
    return gateway.scope == SZFriendsNATAddressScopePrivate || gateway.scope == SZFriendsNATAddressScopeLinkLocal ||
           gateway.scope == SZFriendsNATAddressScopeShared || gateway.scope == SZFriendsNATAddressScopeGlobal;
}

- (SZFriendsNATGatewayMapping *)mappingToGateway:(SZFriendsNATEndpoint *)gateway bind:(SZFriendsNATEndpoint *)bind {
    if (![self allowsGateway:gateway]) return nil;
    SZFriendsNATExchange *exchange =
        [[SZFriendsNATExchange alloc] initWithServer:[gateway endpointWithPort:_configuration.serverPort]
                                         bindAddress:bind
                                               queue:_queue];
    if (exchange == nil) return nil;
    SZFriendsNATGatewayMapping *mapping = [SZFriendsNATGatewayMapping new];
    mapping.exchange = exchange;
    mapping.client = exchange.localEndpoint;
    mapping.protocol = SZFriendsNATMappingProtocolPCP;
    arc4random_buf(mapping->nonce, sizeof mapping->nonce);
    return mapping;
}

- (void)start {
    if (_started || _closed) return;
    _started = YES;
    if (_configuration.internalPort == 0) {
        _upnpDone = YES;
        [self maybeFinish];
        return;
    }
    _v4 = [self mappingToGateway:_configuration.gatewayIPv4 bind:nil];
    // Bound to the global address, so the router sees the address it is asked to open (else ADDRESS_MISMATCH).
    if (_configuration.globalIPv6 != nil) _v6 = [self mappingToGateway:_configuration.gatewayIPv6
                                                                   bind:_configuration.globalIPv6];
    if (_v4 != nil) [self requestPCP:_v4 lifetime:_configuration.lifetime];
    if (_v6 != nil) [self requestPCP:_v6 lifetime:_configuration.lifetime];
    if (_v4 == nil) [self startUPnPIfNeeded];
    [self maybeFinish];
}

#pragma mark PCP and NAT-PMP

- (NSData *)pcpRequest:(SZFriendsNATGatewayMapping *)mapping lifetime:(uint32_t)lifetime {
    uint8_t client[16] = {0}, bytes[SZFriendsPCPMapRequestLength];
    if (mapping.client.family == AF_INET) {
        client[10] = client[11] = 0xff;
        memcpy(client + 12, mapping.client.address.bytes, 4);
    } else {
        memcpy(client, mapping.client.address.bytes, 16);
    }
    uint16_t suggested = mapping.external != nil ? mapping.external.port : _configuration.internalPort;
    SZFriendsPCPWriteMapRequest(bytes, mapping->nonce, client, _configuration.internalPort, suggested, lifetime);
    return [NSData dataWithBytes:bytes length:sizeof bytes];
}

- (void)requestPCP:(SZFriendsNATGatewayMapping *)mapping lifetime:(uint32_t)lifetime {
    __block SZFriendsPCPMapResponse response;
    __block SZFriendsPCPAnswer kind = SZFriendsPCPAnswerInvalid;
    uint16_t internal = _configuration.internalPort;
    BOOL ipv4 = mapping == _v4;
    __weak SZFriendsNATPortMapping *weakSelf = self;
    [mapping.exchange sendRequest:[self pcpRequest:mapping lifetime:lifetime]
        retransmits:_configuration.retransmits
        budget:_configuration.exchangeBudget
        accept:^BOOL(NSData *answer) {
            kind = SZFriendsPCPParseAnswer(answer.bytes, answer.length, mapping->nonce, internal, &response);
            // Only an IPv4 exchange falls back: NAT-PMP has no IPv6.
            return kind == SZFriendsPCPAnswerMap || (ipv4 && kind == SZFriendsPCPAnswerUnsupportedVersion);
        }
        completion:^(NSData *answer, NSError *error) {
            SZFriendsNATPortMapping *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_closed) return;
            if (answer == nil) {
                if (ipv4 && error.code == SZFriendsNATErrorRefused) strongSelf->_gatewayRefusedPort = YES;
                [strongSelf mappingFailed:mapping];
            } else if (kind == SZFriendsPCPAnswerUnsupportedVersion) {
                strongSelf->_fellBackToNATPMP = YES;
                mapping.protocol = SZFriendsNATMappingProtocolNATPMP;
                [strongSelf requestNATPMPExternal:mapping];
            } else if (response.result != SZFriendsPCPResultSuccess || response.lifetime == 0) {
                [strongSelf mappingFailed:mapping];
            } else {
                NSData *address = [NSData dataWithBytes:response.externalAddress length:16];
                SZFriendsNATEndpoint *external = [SZFriendsNATEndpoint endpointWithAddress:address
                                                                                     port:response.externalPort];
                [strongSelf mapping:mapping mappedTo:external lifetime:response.lifetime epoch:response.epoch];
            }
        }];
}

- (void)requestNATPMPExternal:(SZFriendsNATGatewayMapping *)mapping {
    uint8_t bytes[SZFriendsNATPMPExternalRequestLength];
    SZFriendsNATPMPWriteExternalAddressRequest(bytes);
    __block SZFriendsNATPMPResponse response;
    __weak SZFriendsNATPortMapping *weakSelf = self;
    [mapping.exchange sendRequest:[NSData dataWithBytes:bytes length:sizeof bytes]
        retransmits:_configuration.retransmits
        budget:_configuration.exchangeBudget
        accept:^BOOL(NSData *answer) {
            return SZFriendsNATPMPParseExternalAddress(answer.bytes, answer.length, &response);
        }
        completion:^(NSData *answer, NSError *error) {
            (void)error;
            SZFriendsNATPortMapping *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_closed) return;
            if (answer == nil || response.result != 0) {
                [strongSelf mappingFailed:mapping];
                return;
            }
            memcpy(mapping->externalIPv4, response.externalAddress, 4);
            SZFriendsNATEpochContinues(&mapping->epoch, response.epoch, MonotonicSeconds());
            [strongSelf requestNATPMPMap:mapping lifetime:strongSelf->_configuration.lifetime];
        }];
}

- (void)requestNATPMPMap:(SZFriendsNATGatewayMapping *)mapping lifetime:(uint32_t)lifetime {
    uint8_t bytes[SZFriendsNATPMPMapRequestLength];
    uint16_t internal = _configuration.internalPort;
    SZFriendsNATPMPWriteMapRequest(bytes, internal, mapping.external != nil ? mapping.external.port : internal,
                                   lifetime);
    __block SZFriendsNATPMPResponse response;
    __weak SZFriendsNATPortMapping *weakSelf = self;
    [mapping.exchange sendRequest:[NSData dataWithBytes:bytes length:sizeof bytes]
        retransmits:_configuration.retransmits
        budget:_configuration.exchangeBudget
        accept:^BOOL(NSData *answer) {
            return SZFriendsNATPMPParseMap(answer.bytes, answer.length, internal, &response);
        }
        completion:^(NSData *answer, NSError *error) {
            (void)error;
            SZFriendsNATPortMapping *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_closed) return;
            if (answer == nil || response.result != 0 || response.lifetime == 0) {
                [strongSelf mappingFailed:mapping];
                return;
            }
            NSData *address = [NSData dataWithBytes:mapping->externalIPv4 length:4];
            SZFriendsNATEndpoint *external = [SZFriendsNATEndpoint endpointWithAddress:address
                                                                                 port:response.externalPort];
            [strongSelf mapping:mapping mappedTo:external lifetime:response.lifetime epoch:response.epoch];
        }];
}

- (BOOL)isUsableExternal:(SZFriendsNATEndpoint *)external {
    if (external == nil || external.port == 0) return NO;
    if (external.scope == SZFriendsNATAddressScopeGlobal) return YES;
    // A scripted gateway in a test answers with a documentation address; nothing is ever sent to it.
    return _configuration.loopbackOnly && external.scope == SZFriendsNATAddressScopeReserved;
}

- (void)mapping:(SZFriendsNATGatewayMapping *)mapping
       mappedTo:(SZFriendsNATEndpoint *)external
       lifetime:(uint32_t)lifetime
          epoch:(uint32_t)epoch {
    BOOL continues = SZFriendsNATEpochContinues(&mapping->epoch, epoch, MonotonicSeconds());
    SZFriendsNATEndpoint *previous = mapping.external;
    if (!continues && previous != nil && !_remapped) {
        // The router restarted and lost every mapping (ADR 0011: dropped, then requested once more).
        _remapped = YES;
        mapping.external = nil;
        [_delegate portMapping:self didLoseExternal:previous];
        [self requestFresh:mapping];
        return;
    }
    if (![self isUsableExternal:external]) {
        // A private or shared external address means another NAT above this one: the mapping reaches no one.
        [self mappingFailed:mapping];
        return;
    }
    mapping.external = external;
    mapping.finished = YES;
    [self scheduleRenewal:mapping after:MAX(lifetime / 2.0, 1.0)];
    if (![external isEqual:previous]) {
        if (previous != nil) [_delegate portMapping:self didLoseExternal:previous];
        [_delegate portMapping:self didMapExternal:external protocol:mapping.protocol];
    }
    [self maybeFinish];
}

- (void)requestFresh:(SZFriendsNATGatewayMapping *)mapping {
    if (mapping.protocol == SZFriendsNATMappingProtocolNATPMP) {
        [self requestNATPMPExternal:mapping];
    } else {
        [self requestPCP:mapping lifetime:_configuration.lifetime];
    }
}

- (void)scheduleRenewal:(SZFriendsNATGatewayMapping *)mapping after:(NSTimeInterval)seconds {
    if (mapping.renewal != nil) dispatch_source_cancel(mapping.renewal);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, (uint64_t)(0.05 * NSEC_PER_SEC));
    __weak SZFriendsNATPortMapping *weakSelf = self;
    __weak SZFriendsNATGatewayMapping *weakMapping = mapping;
    dispatch_source_set_event_handler(timer, ^{
        SZFriendsNATPortMapping *strongSelf = weakSelf;
        SZFriendsNATGatewayMapping *strongMapping = weakMapping;
        if (strongSelf == nil || strongMapping == nil || strongSelf->_closed) return;
        if (strongMapping.protocol == SZFriendsNATMappingProtocolNATPMP) {
            [strongSelf requestNATPMPMap:strongMapping lifetime:strongSelf->_configuration.lifetime];
        } else {
            [strongSelf requestPCP:strongMapping lifetime:strongSelf->_configuration.lifetime];
        }
    });
    dispatch_resume(timer);
    mapping.renewal = timer;
}

- (void)mappingFailed:(SZFriendsNATGatewayMapping *)mapping {
    SZFriendsNATEndpoint *lost = mapping.external;
    mapping.external = nil;
    mapping.finished = YES;
    if (mapping.renewal != nil) {
        dispatch_source_cancel(mapping.renewal);
        mapping.renewal = nil;
    }
    if (lost != nil) [_delegate portMapping:self didLoseExternal:lost];
    if (mapping == _v4) [self startUPnPIfNeeded];
    [self maybeFinish];
}

#pragma mark UPnP

- (void)startUPnPIfNeeded {
    if (_upnpRunning || _upnpDone || _closed) return;
    SZFriendsNATUPnP *upnp = _configuration.upnp;
    SZFriendsNATEndpoint *local = _configuration.localIPv4 ?: (_v4.client.family == AF_INET ? _v4.client : nil);
    if (upnp == nil || local == nil) {
        _upnpDone = YES;
        return;
    }
    _upnpRunning = YES;
    SZFriendsNATEndpoint *pinhole = _v6.external == nil ? _configuration.globalIPv6 : nil;
    __weak SZFriendsNATPortMapping *weakSelf = self;
    [upnp mapUDPPort:_configuration.internalPort
        localAddress:local
          globalIPv6:pinhole
               queue:_queue
          completion:^(NSArray<SZFriendsNATEndpoint *> *mapped, NSError *error) {
              (void)error;
              SZFriendsNATPortMapping *strongSelf = weakSelf;
              if (strongSelf == nil || strongSelf->_closed) return;
              strongSelf->_upnpRunning = NO;
              strongSelf->_upnpDone = YES;
              [strongSelf adoptUPnPMappings:mapped];
              if (mapped.count > 0) [strongSelf scheduleUPnPRenewal];
              [strongSelf maybeFinish];
          }];
}

- (void)adoptUPnPMappings:(NSArray<SZFriendsNATEndpoint *> *)mapped {
    for (SZFriendsNATEndpoint *old in [_upnpMapped copy]) {
        if (![mapped containsObject:old]) {
            [_upnpMapped removeObject:old];
            [_delegate portMapping:self didLoseExternal:old];
        }
    }
    for (SZFriendsNATEndpoint *endpoint in mapped) {
        if ([_upnpMapped containsObject:endpoint]) continue;
        [_upnpMapped addObject:endpoint];
        [_delegate portMapping:self didMapExternal:endpoint protocol:SZFriendsNATMappingProtocolUPnP];
    }
}

- (void)scheduleUPnPRenewal {
    if (_upnpRenewal != nil) dispatch_source_cancel(_upnpRenewal);
    _upnpRenewal = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    NSTimeInterval half = _configuration.lifetime / 2.0;
    dispatch_source_set_timer(_upnpRenewal, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(half * NSEC_PER_SEC)),
                              (uint64_t)(half * NSEC_PER_SEC), (uint64_t)(1 * NSEC_PER_SEC));
    __weak SZFriendsNATPortMapping *weakSelf = self;
    dispatch_source_set_event_handler(_upnpRenewal, ^{
        SZFriendsNATPortMapping *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_closed) return;
        [strongSelf->_configuration.upnp renewOnQueue:strongSelf->_queue
                                           completion:^(NSArray<SZFriendsNATEndpoint *> *mapped, NSError *error) {
                                               (void)error;
                                               SZFriendsNATPortMapping *again = weakSelf;
                                               if (again != nil && !again->_closed) [again adoptUPnPMappings:mapped];
                                           }];
    });
    dispatch_resume(_upnpRenewal);
}

#pragma mark Ending

- (void)maybeFinish {
    if (_reportedFinish || _closed) return;
    if ((_v4 != nil && !_v4.finished) || (_v6 != nil && !_v6.finished) || _upnpRunning) return;
    if (_v4 == nil || _v4.external == nil) {
        if (!_upnpDone) return;
    }
    _reportedFinish = YES;
    [_delegate portMapping:self didFinishWithMappings:self.externalEndpoints.count];
}

- (void)stopTimers {
    for (SZFriendsNATGatewayMapping *mapping in @[ _v4 ?: [NSNull null], _v6 ?: [NSNull null] ]) {
        if (![mapping isKindOfClass:[SZFriendsNATGatewayMapping class]]) continue;
        if (mapping.renewal != nil) dispatch_source_cancel(mapping.renewal);
        mapping.renewal = nil;
    }
    if (_upnpRenewal != nil) dispatch_source_cancel(_upnpRenewal);
    _upnpRenewal = nil;
}

- (void)networkDidChange {
    if (_closed) return;
    NSArray<SZFriendsNATEndpoint *> *lost = self.externalEndpoints;
    _closed = YES;
    [self stopTimers];
    [_v4.exchange close];
    [_v6.exchange close];
    for (SZFriendsNATEndpoint *endpoint in lost) [_delegate portMapping:self didLoseExternal:endpoint];
}

- (void)deleteGatewayMapping:(SZFriendsNATGatewayMapping *)mapping {
    if (mapping == nil) return;
    if (mapping.external != nil) {
        NSData *request;
        if (mapping.protocol == SZFriendsNATMappingProtocolNATPMP) {
            uint8_t bytes[SZFriendsNATPMPMapRequestLength];
            SZFriendsNATPMPWriteMapRequest(bytes, _configuration.internalPort, 0, 0); // RFC 6886 § 3.4: delete
            request = [NSData dataWithBytes:bytes length:sizeof bytes];
        } else {
            request = [self pcpRequest:mapping lifetime:0];
        }
        // No answer is awaited: the exchange closes after a second send, 250 ms later, in case the first was lost.
        SZFriendsNATExchange *exchange = mapping.exchange;
        [exchange sendOnly:request];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), _queue, ^{
            [exchange sendOnly:request];
            [exchange close];
        });
    } else {
        [mapping.exchange close];
    }
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    [self stopTimers];
    [self deleteGatewayMapping:_v4];
    [self deleteGatewayMapping:_v6];
    if (_upnpMapped.count > 0 || _upnpRunning) [_configuration.upnp removeMappings];
}

- (void)dealloc {
    [self close];
}

@end
