// PCP and NAT-PMP against a scripted gateway on loopback: mapping, renewal at half the lifetime, delete on close, the
// NAT-PMP fallback, "port unreachable", silence, a router that lost its state, and the route lookups.

#import "SZFriendsNATTestSupport.h"

#import "service/online/nat/SZFriendsNATPCP.h"
#import "service/online/nat/SZFriendsNATPortMapping.h"
#import "service/online/nat/SZFriendsNATRoute.h"

#include <netinet/in.h>
#include <unistd.h>

typedef NS_ENUM(NSInteger, GatewayMode) { GatewayPCP, GatewayNATPMPOnly, GatewaySilent };

// What a scripted gateway saw and how it answers.
@interface ScriptedGateway : NSObject
@property(nonatomic) GatewayMode mode;
@property(nonatomic) uint32_t grantLifetime;
@property(nonatomic) uint32_t epoch;
@property(nonatomic) BOOL privateExternal;
@property(nonatomic, strong) NSMutableArray<NSData *> *requests;
@property(nonatomic, strong) SZFTestUDPServer *server;
@end

@implementation ScriptedGateway

- (instancetype)initOnHost:(NSString *)host mode:(GatewayMode)mode {
    if ((self = [super init])) {
        _mode = mode;
        _grantLifetime = 7200;
        _epoch = 5000;
        _requests = [NSMutableArray array];
        __weak ScriptedGateway *weakSelf = self;
        SZFTestUDPHandler handler = ^NSArray<NSData *> *(NSData *p, SZFriendsNATEndpoint *f) {
            (void)f;
            return [weakSelf answer:p];
        };
        _server = [[SZFTestUDPServer alloc] initWithHost:host port:0 handler:handler];
    }
    return self;
}

- (NSArray<NSData *> *)requestsCopy {
    @synchronized(self) {
        return [_requests copy];
    }
}

- (NSArray<NSData *> *)answer:(NSData *)request {
    @synchronized(self) {
        [_requests addObject:request];
    }
    const uint8_t *r = request.bytes;
    if (_mode == GatewaySilent || request.length < 2) return @[];
    if (r[0] == 2 && request.length == 60) {
        if (_mode == GatewayNATPMPOnly) {
            const uint8_t refusal[8] = {0, (uint8_t)(128 + r[1]), 0, 1, 0, 0, 0, 1};
            return @[ [NSData dataWithBytes:refusal length:sizeof refusal] ];
        }
        NSMutableData *answer = [NSMutableData dataWithLength:60];
        uint8_t *a = answer.mutableBytes;
        uint32_t asked = ((uint32_t)r[4] << 24) | ((uint32_t)r[5] << 16) | ((uint32_t)r[6] << 8) | r[7];
        uint32_t lifetime = MIN(asked, _grantLifetime);
        a[0] = 2, a[1] = 0x81;
        a[4] = (uint8_t)(lifetime >> 24), a[5] = (uint8_t)(lifetime >> 16), a[6] = (uint8_t)(lifetime >> 8);
        a[7] = (uint8_t)lifetime;
        a[8] = (uint8_t)(_epoch >> 24), a[9] = (uint8_t)(_epoch >> 16), a[10] = (uint8_t)(_epoch >> 8);
        a[11] = (uint8_t)_epoch;
        memcpy(a + 24, r + 24, 18); // nonce, protocol, reserved, internal port
        a[42] = r[40], a[43] = (uint8_t)(r[41] + 1); // external port: internal + 1
        BOOL v4 = r[18] == 0xff && r[19] == 0xff;
        if (v4) {
            a[54] = a[55] = 0xff;
            a[56] = _privateExternal ? 10 : 203, a[57] = 0, a[58] = _privateExternal ? 0 : 113, a[59] = 9;
        } else {
            const uint8_t documentation[16] = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9};
            memcpy(a + 44, documentation, 16);
        }
        return @[ answer ];
    }
    if (r[0] == 0 && r[1] == 0 && request.length == 2) {
        const uint8_t external[12] = {0, 128, 0, 0, 0, 0, 0x13, 0x88, 203, 0, 113, 10};
        return @[ [NSData dataWithBytes:external length:sizeof external] ];
    }
    if (r[0] == 0 && r[1] == 1 && request.length == 12) {
        uint32_t asked = ((uint32_t)r[8] << 24) | ((uint32_t)r[9] << 16) | ((uint32_t)r[10] << 8) | r[11];
        uint32_t lifetime = MIN(asked, _grantLifetime);
        uint8_t map[16] = {0, 129, 0, 0, 0, 0, 0x13, 0x89, r[4], r[5], r[4], (uint8_t)(r[5] + 2)};
        map[12] = (uint8_t)(lifetime >> 24), map[13] = (uint8_t)(lifetime >> 16), map[14] = (uint8_t)(lifetime >> 8);
        map[15] = (uint8_t)lifetime;
        return @[ [NSData dataWithBytes:map length:sizeof map] ];
    }
    return @[];
}

@end

@interface MappingRecorder : NSObject <SZFriendsNATPortMappingDelegate>
@property(nonatomic, strong) NSMutableArray<SZFriendsNATEndpoint *> *mapped, *lost;
@property(nonatomic) SZFriendsNATMappingProtocol lastProtocol;
@property(nonatomic) NSInteger finished;
@property(nonatomic) NSUInteger finishedWith;
@property(nonatomic, strong) dispatch_semaphore_t finish, change;
@end

@implementation MappingRecorder
- (instancetype)init {
    if ((self = [super init])) {
        _mapped = [NSMutableArray array];
        _lost = [NSMutableArray array];
        _finish = dispatch_semaphore_create(0);
        _change = dispatch_semaphore_create(0);
    }
    return self;
}
- (void)portMapping:(SZFriendsNATPortMapping *)mapping
     didMapExternal:(SZFriendsNATEndpoint *)external
           protocol:(SZFriendsNATMappingProtocol)protocol {
    (void)mapping;
    [_mapped addObject:external];
    _lastProtocol = protocol;
    dispatch_semaphore_signal(_change);
}
- (void)portMapping:(SZFriendsNATPortMapping *)mapping didLoseExternal:(SZFriendsNATEndpoint *)external {
    (void)mapping;
    [_lost addObject:external];
    dispatch_semaphore_signal(_change);
}
- (void)portMapping:(SZFriendsNATPortMapping *)mapping didFinishWithMappings:(NSUInteger)mapped {
    (void)mapping;
    _finished++;
    _finishedWith = mapped;
    dispatch_semaphore_signal(_finish);
}
@end

static SZFriendsNATPortMappingConfiguration *Configuration(SZFriendsNATEndpoint *gateway, uint16_t port) {
    SZFriendsNATPortMappingConfiguration *configuration = [SZFriendsNATPortMappingConfiguration new];
    configuration.internalPort = port;
    configuration.gatewayIPv4 = gateway;
    configuration.serverPort = gateway.port;
    configuration.retransmits = @[ @0.1, @0.3 ];
    configuration.exchangeBudget = 0.6;
    configuration.loopbackOnly = YES;
    return configuration;
}

static void TestPCPMapRenewDelete(void) {
    ScriptedGateway *gateway = [[ScriptedGateway alloc] initOnHost:@"127.0.0.1" mode:GatewayPCP];
    gateway.grantLifetime = 2; // renewal due after 1 s
    MappingRecorder *recorder = [MappingRecorder new];
    dispatch_queue_t queue = SZFTestQueue("szf.test.pcp");
    SZFriendsNATPortMapping *mapping =
        [[SZFriendsNATPortMapping alloc] initWithConfiguration:Configuration(gateway.server.endpoint, 40000)
                                                      delegate:recorder
                                                         queue:queue];
    SZFTestSync(queue, ^{
        [mapping start];
    });
    CHECK(SZFTestWait(recorder.finish, 3) && recorder.finishedWith == 1);
    SZFriendsNATEndpoint *expected = [SZFriendsNATEndpoint endpointWithHost:@"203.0.113.9" port:40001];
    CHECK([recorder.mapped.firstObject isEqual:expected] && recorder.lastProtocol == SZFriendsNATMappingProtocolPCP);
    NSData *first = gateway.requestsCopy.firstObject;
    const uint8_t *r = first.bytes;
    CHECK(first.length == 60 && r[7] == (7200 & 0xff) && r[6] == (7200 >> 8) && r[20] == 127 && r[23] == 1,
          "MAP for 7,200 s from ::ffff:127.0.0.1");
    usleep(1500 * 1000);
    NSArray<NSData *> *requests = gateway.requestsCopy;
    CHECK(requests.count == 2 && memcmp((const uint8_t *)requests[1].bytes + 24, r + 24, 12) == 0,
          "renewed at half the lifetime with the same nonce (%lu requests)", (unsigned long)requests.count);
    CHECK(recorder.mapped.count == 1 && recorder.lost.count == 0, "an unchanged renewal reports nothing");
    SZFTestSync(queue, ^{
        [mapping close];
    });
    usleep(400 * 1000);
    requests = gateway.requestsCopy;
    const uint8_t *last = requests.lastObject.bytes;
    CHECK(requests.count == 4 && last[4] == 0 && last[5] == 0 && last[6] == 0 && last[7] == 0 &&
          memcmp(last + 24, r + 24, 12) == 0, "close deletes it (lifetime 0, twice): %lu",
          (unsigned long)requests.count);
    [gateway.server close];
}

static void TestNATPMPFallback(void) {
    ScriptedGateway *gateway = [[ScriptedGateway alloc] initOnHost:@"127.0.0.1" mode:GatewayNATPMPOnly];
    MappingRecorder *recorder = [MappingRecorder new];
    dispatch_queue_t queue = SZFTestQueue("szf.test.natpmp");
    SZFriendsNATPortMapping *mapping =
        [[SZFriendsNATPortMapping alloc] initWithConfiguration:Configuration(gateway.server.endpoint, 41000)
                                                      delegate:recorder
                                                         queue:queue];
    SZFTestSync(queue, ^{
        [mapping start];
    });
    CHECK(SZFTestWait(recorder.finish, 3) && recorder.finishedWith == 1);
    CHECK(mapping.fellBackToNATPMP && recorder.lastProtocol == SZFriendsNATMappingProtocolNATPMP);
    CHECK([recorder.mapped.firstObject isEqual:[SZFriendsNATEndpoint endpointWithHost:@"203.0.113.10" port:41002]],
          "NAT-PMP's external address with its mapped port");
    SZFTestSync(queue, ^{
        [mapping close];
    });
    usleep(400 * 1000);
    const uint8_t *last = gateway.requestsCopy.lastObject.bytes;
    CHECK(last[1] == 1 && last[6] == 0 && last[7] == 0 && last[11] == 0, "deleted: external port 0, lifetime 0");
    [gateway.server close];
}

static void TestRefusedAndSilent(void) {
    // A port nothing listens on: the kernel answers "port unreachable" at once.
    ScriptedGateway *closed = [[ScriptedGateway alloc] initOnHost:@"127.0.0.1" mode:GatewaySilent];
    SZFriendsNATEndpoint *nowhere = closed.server.endpoint;
    [closed.server close];
    usleep(50 * 1000);
    MappingRecorder *recorder = [MappingRecorder new];
    dispatch_queue_t queue = SZFTestQueue("szf.test.refused");
    SZFriendsNATPortMapping *refused =
        [[SZFriendsNATPortMapping alloc] initWithConfiguration:Configuration(nowhere, 42000)
                                                      delegate:recorder
                                                         queue:queue];
    NSDate *start = [NSDate date];
    SZFTestSync(queue, ^{
        [refused start];
    });
    CHECK(SZFTestWait(recorder.finish, 2) && recorder.finishedWith == 0 && refused.gatewayRefusedPort);
    CHECK(-start.timeIntervalSinceNow < 0.5, "port unreachable ends the exchange at once");

    ScriptedGateway *silent = [[ScriptedGateway alloc] initOnHost:@"127.0.0.1" mode:GatewaySilent];
    recorder = [MappingRecorder new];
    SZFriendsNATPortMapping *mapping =
        [[SZFriendsNATPortMapping alloc] initWithConfiguration:Configuration(silent.server.endpoint, 42001)
                                                      delegate:recorder
                                                         queue:queue];
    start = [NSDate date];
    SZFTestSync(queue, ^{
        [mapping start];
    });
    CHECK(SZFTestWait(recorder.finish, 3) && recorder.finishedWith == 0 && !mapping.gatewayRefusedPort);
    NSTimeInterval elapsed = -start.timeIntervalSinceNow;
    CHECK(elapsed > 0.55 && elapsed < 1.0 && silent.requestsCopy.count == 3,
          "sent at 0, 0.1, 0.3 s and gave up at the budget (%.2f s, %lu)", elapsed,
          (unsigned long)silent.requestsCopy.count);
    [silent.server close];

    ScriptedGateway *doubleNAT = [[ScriptedGateway alloc] initOnHost:@"127.0.0.1" mode:GatewayPCP];
    doubleNAT.privateExternal = YES;
    recorder = [MappingRecorder new];
    mapping = [[SZFriendsNATPortMapping alloc] initWithConfiguration:Configuration(doubleNAT.server.endpoint, 42002)
                                                            delegate:recorder
                                                               queue:queue];
    SZFTestSync(queue, ^{
        [mapping start];
    });
    CHECK(SZFTestWait(recorder.finish, 3) && recorder.finishedWith == 0 && recorder.mapped.count == 0,
          "a private external address reaches no one");
    SZFTestSync(queue, ^{
        [mapping close];
    });
    [doubleNAT.server close];
}

static void TestLostStateAndNetworkChange(void) {
    ScriptedGateway *gateway = [[ScriptedGateway alloc] initOnHost:@"127.0.0.1" mode:GatewayPCP];
    gateway.grantLifetime = 2;
    MappingRecorder *recorder = [MappingRecorder new];
    dispatch_queue_t queue = SZFTestQueue("szf.test.epoch");
    SZFriendsNATPortMapping *mapping =
        [[SZFriendsNATPortMapping alloc] initWithConfiguration:Configuration(gateway.server.endpoint, 43000)
                                                      delegate:recorder
                                                         queue:queue];
    SZFTestSync(queue, ^{
        [mapping start];
    });
    CHECK(SZFTestWait(recorder.finish, 3) && recorder.mapped.count == 1);
    CHECK(SZFTestWait(recorder.change, 1), "the first mapping's report");
    gateway.epoch = 3; // the router restarted before the renewal
    CHECK(SZFTestWait(recorder.change, 3) && SZFTestWait(recorder.change, 3), "lost, then mapped again");
    CHECK(recorder.lost.count == 1 && recorder.mapped.count == 2 && mapping.externalEndpoints.count == 1);
    __block NSUInteger before = 0;
    SZFTestSync(queue, ^{
        before = gateway.requestsCopy.count;
        [mapping networkDidChange];
    });
    usleep(300 * 1000);
    CHECK(recorder.lost.count == 2 && gateway.requestsCopy.count == before, "dropped without a word to the router");
    [gateway.server close];
}

static void TestIPv6Pinhole(void) {
    ScriptedGateway *gateway = [[ScriptedGateway alloc] initOnHost:@"::1" mode:GatewayPCP];
    if (gateway.server == nil) {
        fprintf(stderr, "    skipped: IPv6 pinhole (no ::1)\n");
        return;
    }
    SZFriendsNATPortMappingConfiguration *configuration = Configuration(nil, 44000);
    configuration.gatewayIPv6 = gateway.server.endpoint;
    configuration.globalIPv6 = [SZFriendsNATEndpoint endpointWithHost:@"::1" port:0];
    configuration.serverPort = gateway.server.endpoint.port;
    MappingRecorder *recorder = [MappingRecorder new];
    dispatch_queue_t queue = SZFTestQueue("szf.test.pcp6");
    SZFriendsNATPortMapping *mapping = [[SZFriendsNATPortMapping alloc] initWithConfiguration:configuration
                                                                                     delegate:recorder
                                                                                        queue:queue];
    SZFTestSync(queue, ^{
        [mapping start];
    });
    CHECK(SZFTestWait(recorder.finish, 3) && recorder.finishedWith == 1);
    CHECK([recorder.mapped.firstObject isEqual:[SZFriendsNATEndpoint endpointWithHost:@"2001:db8::9" port:44001]]);
    const uint8_t *r = gateway.requestsCopy.firstObject.bytes;
    CHECK(r[23] == 1 && r[8] == 0 && r[18] == 0, "the client address is the bound IPv6 one, not IPv4-mapped");
    SZFTestSync(queue, ^{
        [mapping close];
    });
    [gateway.server close];
}

static void TestRoutes(void) {
    SZFriendsNATEndpoint *local = [SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:0];
    SZFriendsNATRoute *loopback = [SZFriendsNATRoute routeToDestination:local];
    CHECK([loopback.interfaceName hasPrefix:@"lo"] && !loopback.physical && loopback.gateway == nil);
    SZFriendsNATRoute *internet = [SZFriendsNATRoute defaultRouteForFamily:AF_INET];
    if (internet == nil) {
        fprintf(stderr, "    no IPv4 route toward the Internet here\n");
        return;
    }
    CHECK(internet.interfaceName.length > 0 && internet.networkKey.length > 0);
    SZFriendsNATPortMappingConfiguration *configuration = [SZFriendsNATPortMappingConfiguration configurationForPort:1];
    CHECK((configuration.gatewayIPv4 != nil) == (internet.physical && internet.gateway != nil),
          "port mapping only on a physical default route (here %s)", internet.interfaceName.UTF8String);
    fprintf(stderr, "    the route toward the Internet is %s (%s)\n", internet.interfaceName.UTF8String,
            internet.physical ? "physical: port mapping would run" : "a tunnel: port mapping is skipped");
}

void SZFTestPortMapping(void) {
    TestPCPMapRenewDelete();
    TestNATPMPFallback();
    TestRefusedAndSilent();
    TestLostStateAndNetworkChange();
    TestIPv6Pinhole();
    TestRoutes();
}
