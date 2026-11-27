// The Wi-Fi Direct boost in the Mac helper (ADR 0019): the decisions, BOOST against the shared vectors
// (fixtures/vectors/transfer/frames.json, written by the Rust core), the negotiation, the way back with crash
// recovery, and the coordinator against a mocked Wi-Fi. Nothing here touches the Mac's real Wi-Fi: CoreWLAN is never
// linked into this binary.

#import <Foundation/Foundation.h>

#import "service/transfer/SZFriendsDirectWiFiBoost.h"

static int failures = 0;
#define CHECK(condition, ...)                                                                                         \
    do {                                                                                                              \
        if (!(condition)) {                                                                                           \
            failures++;                                                                                               \
            fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); \
        }                                                                                                             \
    } while (0)

static NSString *Hex(NSData *data) {
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < data.length; i++) [out appendFormat:@"%02x", ((const uint8_t *)data.bytes)[i]];
    return out;
}

static NSData *Bytes(NSString *hex) {
    NSMutableData *out = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned value = 0;
        sscanf([hex substringWithRange:NSMakeRange(i, 2)].UTF8String, "%2x", &value);
        uint8_t byte = (uint8_t)value;
        [out appendBytes:&byte length:1];
    }
    return out;
}

static SZFriendsBoostConnectivity *HomeWiFi(void) {
    SZFriendsBoostConnectivity *c = [SZFriendsBoostConnectivity new];
    c.onWiFi = YES;
    c.wifiName = @"HomeWiFi";
    return c;
}

// A phone on its Wi-Fi with mobile data: the one device the owner's rule (ADR 0022) lets leave its Wi-Fi.
static SZFriendsBoostConnectivity *PhoneOnWiFi(void) {
    SZFriendsBoostConnectivity *c = HomeWiFi();
    c.mobile = YES;
    c.phone = YES;
    return c;
}

// On no Wi-Fi network (a cable, or nothing): a Mac's only way to boost.
static SZFriendsBoostConnectivity *OffWiFi(void) {
    return [SZFriendsBoostConnectivity new];
}

static void TestDecisions(void) {
    const uint64_t MiB = 1 << 20;
    CHECK(!SZFriendsBoostWorthIt(4 * MiB, 0, NULL), @"4 MiB saves under 20 s");
    SZFriendsBoostEstimate e;
    CHECK(SZFriendsBoostWorthIt(8 * MiB, 0, &e) && e.bluetoothSeconds - e.directSeconds > 39, @"8 MiB is worth it");
    CHECK(!SZFriendsBoostWorthIt(40 * MiB, 2e6, NULL), @"a fast Bluetooth link is left alone");
    CHECK(SZFriendsBoostNotOnSameNetwork(YES, 10, NO, 0), @"never seen on the network in 10 s");
    CHECK(!SZFriendsBoostNotOnSameNetwork(YES, 9, NO, 0), @"too early");
    CHECK(!SZFriendsBoostNotOnSameNetwork(YES, 10, YES, 2), @"seen: the network dials first");
    CHECK(SZFriendsBoostNotOnSameNetwork(YES, 10, YES, 3), @"three dials failed");
    CHECK(!SZFriendsBoostNotOnSameNetwork(NO, 60, NO, 9), @"another route carries it");

    SZFriendsBoostAbilities mac = SZFriendsBoostCanJoin;
    SZFriendsBoostAbilities phone =
        SZFriendsBoostCanHost | SZFriendsBoostCanJoin | SZFriendsBoostHostKeepsWiFi | SZFriendsBoostJoinKeepsWiFi;
    CHECK(SZFriendsBoostRoleFor(mac, phone, YES) == SZFriendsBoostRoleJoin, @"the Mac joins");
    CHECK(SZFriendsBoostRoleFor(phone, mac, NO) == SZFriendsBoostRoleHost, @"the phone hosts");
    CHECK(SZFriendsBoostRoleFor(mac, mac, YES) == SZFriendsBoostRoleNone, @"two Macs have AWDL");
    CHECK(SZFriendsBoostRoleFor(phone, phone, YES) == SZFriendsBoostRoleHost &&
              SZFriendsBoostRoleFor(phone, phone, NO) == SZFriendsBoostRoleJoin,
          @"a tie goes by key order");

    // The owner's rule (ADR 0022): on no Wi-Fi network, or a phone on mobile data.
    SZFriendsBoostConnectivity *wired = HomeWiFi(), *macMobile = HomeWiFi();
    wired.wired = macMobile.mobile = YES;
    CHECK(OffWiFi().allowsDirectWiFi && PhoneOnWiFi().allowsDirectWiFi, @"off Wi-Fi, or a phone on mobile data");
    CHECK(!HomeWiFi().allowsDirectWiFi && !wired.allowsDirectWiFi && !macMobile.allowsDirectWiFi,
          @"any other device on a Wi-Fi network: never");

    SZFriendsBoostCost *cost = [SZFriendsBoostCost costForRole:SZFriendsBoostRoleJoin abilities:mac
                                                  connectivity:PhoneOnWiFi()];
    CHECK(cost.kind == SZFriendsBoostCostLeavesWiFi && cost.overMobile && cost.asks &&
              [cost.network isEqualToString:@"HomeWiFi"],
          @"a phone leaving its Wi-Fi is asked, never silently");
    cost = [SZFriendsBoostCost costForRole:SZFriendsBoostRoleJoin abilities:mac connectivity:wired];
    CHECK(cost.asks, @"leaving a Wi-Fi network always asks");
    cost = [SZFriendsBoostCost costForRole:SZFriendsBoostRoleJoin abilities:mac connectivity:OffWiFi()];
    CHECK(cost.kind == SZFriendsBoostCostNothing && !cost.asks, @"on no Wi-Fi: nothing to lose, nobody asked");
}

static void TestLinkAndFrames(void) {
    SZFriendsBoostLink *a = [SZFriendsBoostLink random], *b = [SZFriendsBoostLink random];
    CHECK(![a.network isEqualToString:b.network] && a.network.length == 17 && [a.network hasPrefix:@"DIRECT-"] &&
              a.passphrase.length == 20,
          @"random links: %@ %@", a.network, b.network);
    CHECK(![a.description containsString:a.passphrase], @"the passphrase never reaches a log");
    CHECK([SZFriendsBoostLink linkWithNetwork:@"HomeWiFi" passphrase:@"12345678"] == nil, @"not a DIRECT- name");
    CHECK(SZFriendsBoostAddressIsPrivate(Bytes(@"c0a83101")) && !SZFriendsBoostAddressIsPrivate(Bytes(@"08080808")) &&
              SZFriendsBoostAddressIsPrivate(Bytes(@"fe800000000000000000000000000001")),
          @"private addresses only");

    // The Rust core's vectors, byte for byte.
    NSData *json = [NSData dataWithContentsOfFile:@"friends/fixtures/vectors/transfer/frames.json"];
    NSDictionary *vectors = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL] : nil;
    CHECK(vectors != nil, @"frames.json (run from portable/)");
    NSData *transfer = Bytes(@"1fb38b3957c13dfa57e5b603761145a3");
    NSMutableData *random = [NSMutableData dataWithLength:64];
    memset(random.mutableBytes, 0x2a, 64);
    NSDictionary<NSString *, SZFriendsBoostMessage *> *ours = @{
        @"boost_propose" : [SZFriendsBoostMessage propose:SZFriendsBoostCanJoin],
        @"boost_ready" : [SZFriendsBoostMessage ready:SZFriendsBoostCanHost | SZFriendsBoostCanJoin |
                                                      SZFriendsBoostHostKeepsWiFi | SZFriendsBoostJoinKeepsWiFi],
        @"boost_host" : [SZFriendsBoostMessage host:[SZFriendsBoostLink linkFromRandom:random]
                                            address:Bytes(@"c0a83101")
                                               port:49200],
        @"boost_end" : [SZFriendsBoostMessage end:SZFriendsBoostReasonSlower],
        @"boost_decline" : [SZFriendsBoostMessage decline:SZFriendsBoostReasonNotNow],
    };
    NSUInteger seen = 0;
    for (NSDictionary *c in vectors[@"encode"]) {
        SZFriendsBoostMessage *message = ours[c[@"name"]];
        if (message == nil) continue;
        seen++;
        NSData *encoded = SZFriendsEncodeFrame([message frameForTransfer:transfer], NULL);
        CHECK([Hex(encoded) isEqualToString:c[@"encoded"]], @"%@: %@", c[@"name"], Hex(encoded));
        SZFriendsFrame *frame = SZFriendsDecodeFrame(Bytes(c[@"encoded"]), NULL);
        NSData *back = nil;
        SZFriendsBoostMessage *decoded = [SZFriendsBoostMessage messageFromFrame:frame transfer:&back];
        CHECK(decoded.step == message.step && [back isEqualToData:transfer], @"%@ decodes", c[@"name"]);
    }
    CHECK(seen == 5, @"five BOOST vectors, saw %lu", (unsigned long)seen);
    printf("Wi-Fi Direct boost: %lu BOOST vectors match the Rust core's\n", (unsigned long)seen);
    for (NSDictionary *c in vectors[@"decode"]) {
        if (![c[@"name"] hasPrefix:@"boost_"]) continue;
        CHECK(SZFriendsDecodeFrame(Bytes(c[@"input"]), NULL) == nil, @"%@ is refused", c[@"name"]);
    }
    SZFriendsFrame *public = [[SZFriendsBoostMessage host:a address:Bytes(@"08080808") port:80] frameForTransfer:transfer];
    NSData *ignored = nil;
    CHECK([SZFriendsBoostMessage messageFromFrame:public transfer:&ignored] == nil, @"a public address is refused");
}

#pragma mark - Negotiation

@interface Side : NSObject <SZFriendsBoostDriver>
@property(nonatomic, strong) SZFriendsBoost *boost;
@property(nonatomic, weak) Side *other;
@property(nonatomic, strong) NSMutableArray<NSString *> *log;
@property(nonatomic, strong) SZFriendsBoostLink *joined;
@end

@implementation Side
- (instancetype)init {
    if ((self = [super init])) _log = [NSMutableArray array];
    return self;
}
- (void)boostSend:(SZFriendsBoostMessage *)message {
    [self.log addObject:[NSString stringWithFormat:@"send %d.%d", message.step, message.reason]];
    // Through the codec, as the session would carry it.
    NSData *transfer = nil;
    SZFriendsFrame *frame = SZFriendsDecodeFrame(
        SZFriendsEncodeFrame([message frameForTransfer:[NSMutableData dataWithLength:16]], NULL), NULL);
    SZFriendsBoostMessage *carried = [SZFriendsBoostMessage messageFromFrame:frame transfer:&transfer];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.other.boost message:carried now:0];
    });
}
- (void)boostAsk:(BOOL)asking {
    [self.log addObject:asking ? @"ask" : @"unask"];
}
- (void)boostHost:(SZFriendsBoostLink *)link {
    [self.log addObject:@"host"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.boost hostedAt:[NSData dataWithBytes:(uint8_t[]){192, 168, 49, 1} length:4] port:50000 now:1];
    });
}
- (void)boostJoin:(SZFriendsBoostLink *)link {
    self.joined = link;
    [self.log addObject:@"join"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.boost joinedAt:2];
    });
}
- (void)boostDialAddress:(NSData *)address port:(uint16_t)port {
    [self.log addObject:[NSString stringWithFormat:@"dial %@:%u", Hex(address), port]];
}
- (void)boostAllowDirectLane:(BOOL)allowed {
    [self.log addObject:allowed ? @"allow" : @"disallow"];
}
- (void)boostStopHosting {
    [self.log addObject:@"stop"];
}
- (void)boostLeaveJoined {
    [self.log addObject:@"leave"];
}
@end

static void Settle(void) {
    for (int i = 0; i < 20; i++) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
}

static void TestNegotiation(void) {
    NSData *transfer = [NSMutableData dataWithLength:16];
    SZFriendsBoostAbilities phone = SZFriendsBoostCanHost | SZFriendsBoostCanJoin;
    SZFriendsBoostAbilities phoneAllowed = phone | SZFriendsBoostDirectWiFiAllowed;
    // The phone, on its Wi-Fi with mobile data, proposes and asks its person; the Mac, on no Wi-Fi network, agrees
    // without asking; Go faster; the phone hosts, the Mac joins and dials.
    Side *mac = [Side new], *android = [Side new];
    mac.other = android;
    android.other = mac;
    android.boost = [SZFriendsBoost proposeTransfer:transfer abilities:phone connectivity:PhoneOnWiFi() sortsFirst:YES
                                            driver:android];
    mac.boost = [SZFriendsBoost proposedTransfer:transfer abilities:SZFriendsBoostCanJoin peer:phoneAllowed
                                    connectivity:OffWiFi() sortsFirst:NO driver:mac now:0];
    Settle();
    CHECK(![mac.log containsObject:@"ask"] && mac.boost.phase == SZFriendsBoostPhaseAgreed,
          @"the Mac, off Wi-Fi, is not asked: %@", mac.log);
    CHECK(android.boost.phase == SZFriendsBoostPhaseAsking && [android.log containsObject:@"ask"],
          @"the phone leaving its Wi-Fi asks: %@", android.log);
    CHECK(![android.log containsObject:@"host"], @"nothing hosted before the phone's person agrees");
    [android.boost answer:YES now:3];
    Settle();
    CHECK([android.log containsObject:@"host"] && mac.joined != nil, @"hosted and joined: %@ / %@", android.log, mac.log);
    CHECK([mac.log containsObject:@"dial c0a83101:50000"], @"the Mac dials the link: %@", mac.log);
    [mac.boost laneUpAt:4];
    [android.boost laneUpAt:4];
    [mac.boost directRate:0.1e6 bluetoothRate:0.2e6 now:12];
    Settle();
    CHECK(mac.boost.endReason == SZFriendsBoostReasonSlower && [mac.log containsObject:@"leave"] &&
              [android.log containsObject:@"stop"],
          @"slower than Bluetooth: it ends and comes back: %@ / %@", mac.log, android.log);

    // Not now: final, and the phone hosts nothing.
    mac = [Side new];
    android = [Side new];
    mac.other = android;
    android.other = mac;
    android.boost = [SZFriendsBoost proposeTransfer:transfer abilities:phone connectivity:PhoneOnWiFi() sortsFirst:YES
                                            driver:android];
    mac.boost = [SZFriendsBoost proposedTransfer:transfer abilities:SZFriendsBoostCanJoin peer:phoneAllowed
                                    connectivity:OffWiFi() sortsFirst:NO driver:mac now:0];
    Settle();
    [android.boost answer:NO now:1];
    Settle();
    CHECK(mac.boost.declinedByPerson && android.boost.declinedByPerson && ![android.log containsObject:@"host"],
          @"Not now is final: %@", android.log);

    // The rule: a Mac on its Wi-Fi declines, and so does a Mac whose friend's side did not allow it (an older helper).
    Side *onWiFi = [Side new];
    onWiFi.boost = [SZFriendsBoost proposedTransfer:transfer abilities:SZFriendsBoostCanJoin peer:phoneAllowed
                                       connectivity:HomeWiFi() sortsFirst:NO driver:onWiFi now:0];
    CHECK(onWiFi.boost.endReason == SZFriendsBoostReasonUnsupported, @"a Mac on Wi-Fi never boosts");
    Side *older = [Side new];
    older.boost = [SZFriendsBoost proposedTransfer:transfer abilities:SZFriendsBoostCanJoin peer:phone
                                      connectivity:OffWiFi() sortsFirst:NO driver:older now:0];
    CHECK(older.boost.endReason == SZFriendsBoostReasonUnsupported, @"a peer that did not say it allows it");
}

#pragma mark - Coming back

@interface Rejoiner : NSObject <SZFriendsBoostRejoinDriver>
@property(nonatomic, strong) NSMutableArray<NSString *> *log;
@end
@implementation Rejoiner
- (instancetype)init {
    if ((self = [super init])) _log = [NSMutableArray array];
    return self;
}
- (void)rejoinWrite:(SZFriendsBoostSaved *)saved {
    [self.log addObject:@"write"];
}
- (void)rejoinNetwork:(NSString *)network leaving:(NSString *)joined {
    [self.log addObject:[NSString stringWithFormat:@"rejoin %@", network ?: @"-"]];
}
- (void)rejoinCheckOnline {
    [self.log addObject:@"check"];
}
- (void)rejoinForget {
    [self.log addObject:@"forget"];
}
- (void)rejoinTellNetworkName:(NSString *)networkName {
    [self.log addObject:[NSString stringWithFormat:@"tell %@", networkName]];
}
@end

static void TestRejoin(void) {
    SZFriendsBoostSaved *saved = [SZFriendsBoostSaved savedWithNetwork:@"HomeWiFi" networkName:@"HomeWiFi"
                                                                joined:@"DIRECT-ab12345678" leftAt:1.8e9];
    SZFriendsBoostSaved *back = [SZFriendsBoostSaved savedFromJSON:saved.JSON];
    CHECK([back.network isEqualToString:@"HomeWiFi"] && [back.joined isEqualToString:@"DIRECT-ab12345678"],
          @"the record round-trips");
    CHECK([SZFriendsBoostSaved savedFromJSON:[@"{\"version\":2,\"joined\":\"x\",\"left_at\":1}"
                                                 dataUsingEncoding:NSUTF8StringEncoding]] == nil,
          @"a later version is left alone");

    Rejoiner *driver = [Rejoiner new];
    SZFriendsBoostRejoin *rejoin = [[SZFriendsBoostRejoin alloc] initWithDriver:driver];
    [rejoin leaving:saved];
    [rejoin comeBackAt:100];
    [rejoin rejoined:YES now:103];
    [rejoin online:NO now:104];
    [rejoin tick:106];
    [rejoin online:YES now:106];
    CHECK(([driver.log isEqualToArray:@[ @"write", @"rejoin HomeWiFi", @"check", @"check", @"forget" ]]),
          @"back and online: %@", driver.log);

    driver = [Rejoiner new];
    rejoin = [[SZFriendsBoostRejoin alloc] initWithDriver:driver];
    [rejoin leaving:saved];
    [rejoin comeBackAt:0];
    [rejoin rejoined:NO now:1];
    [rejoin tick:4];
    [rejoin rejoined:NO now:5];
    [rejoin tick:8];
    [rejoin rejoined:NO now:9];
    CHECK([driver.log.lastObject isEqualToString:@"tell HomeWiFi"] &&
              [driver.log filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'rejoin'"]]
                      .count == 3,
          @"three tries, then the person is told: %@", driver.log);

    // A crash while away: the next launch comes back first.
    driver = [Rejoiner new];
    rejoin = [[SZFriendsBoostRejoin alloc] initWithDriver:driver];
    [rejoin launchedWithRecord:saved now:0];
    [rejoin rejoined:YES now:1];
    [rejoin online:YES now:2];
    CHECK(([driver.log isEqualToArray:@[ @"rejoin HomeWiFi", @"check", @"forget" ]]), @"after a crash: %@", driver.log);
}

#pragma mark - The coordinator against a mocked Wi-Fi

@interface MockWiFi : NSObject <SZFriendsWiFiJoining>
@property(nonatomic, copy, nullable) NSString *network;
@property(nonatomic, strong) NSMutableArray<NSString *> *log;
@end
@implementation MockWiFi
- (instancetype)init {
    if ((self = [super init])) {
        _log = [NSMutableArray array];
        _network = nil; // on Ethernet, no Wi-Fi network: the owner's rule lets this Mac boost
    }
    return self;
}
- (SZFriendsBoostConnectivity *)connectivity {
    SZFriendsBoostConnectivity *c = [SZFriendsBoostConnectivity new];
    c.onWiFi = self.network != nil;
    c.wifiName = [self.network hasPrefix:@"DIRECT-"] ? nil : self.network;
    return c;
}
- (NSString *)currentNetwork {
    return self.network;
}
- (void)joinNetwork:(NSString *)network passphrase:(NSString *)passphrase completion:(void (^)(BOOL))completion {
    [self.log addObject:[@"join " stringByAppendingString:network]];
    self.network = network;
    completion(YES);
}
- (void)rejoinNetwork:(NSString *)network leaving:(NSString *)joined completion:(void (^)(BOOL))completion {
    [self.log addObject:[NSString stringWithFormat:@"rejoin %@ from %@", network ?: @"-", joined]];
    self.network = network;
    completion(YES);
}
- (void)checkOnline:(void (^)(BOOL))completion {
    completion(![self.network hasPrefix:@"DIRECT-"]); // Ethernet, or the Wi-Fi it rejoined
}
@end

@interface Group : NSObject <SZFriendsDirectWiFiGroup>
@property(nonatomic, strong) NSMutableArray<SZFriendsBoostMessage *> *sent;
@property(nonatomic, strong) NSMutableArray<NSString *> *log;
@end
@implementation Group
- (instancetype)init {
    if ((self = [super init])) {
        _sent = [NSMutableArray array];
        _log = [NSMutableArray array];
    }
    return self;
}
- (BOOL)boostSendFrame:(SZFriendsFrame *)frame {
    NSData *transfer = nil;
    SZFriendsBoostMessage *message = [SZFriendsBoostMessage messageFromFrame:frame transfer:&transfer];
    if (message) [self.sent addObject:message];
    return YES;
}
- (void)boostDialAddress:(NSData *)address port:(uint16_t)port {
    [self.log addObject:[NSString stringWithFormat:@"dial %@:%u", Hex(address), port]];
}
- (void)boostCloseDirectLane {
    [self.log addObject:@"close lane"];
}
- (void)boostAllowDirectWiFi:(BOOL)allowed {
    (void)allowed;
}
@end

static void Spin(void) {
    for (int i = 0; i < 20; i++) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
}

static SZFriendsFrame *PhoneSays(SZFriendsBoostMessage *message, NSString *transfer) {
    return [message frameForTransfer:Bytes(transfer)];
}

static void TestCoordinator(void) {
    NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *record = [home stringByAppendingPathComponent:@"direct-wifi.json"];
    NSString *t = @"00112233445566778899aabbccddeeff";
    SZFriendsBoostAbilities phone = SZFriendsBoostCanHost | SZFriendsBoostCanJoin | SZFriendsBoostDirectWiFiAllowed;

    // This Mac is on Ethernet, on no Wi-Fi network: it agrees at once, with nothing to ask (ADR 0022).
    MockWiFi *wifi = [MockWiFi new];
    SZFriendsDirectWiFiCoordinator *mac = [[SZFriendsDirectWiFiCoordinator alloc] initWithWiFi:wifi recordPath:record
                                                                                        queue:dispatch_get_main_queue()];
    Group *group = [Group new];
    [mac group:@1 receivedFrame:PhoneSays([SZFriendsBoostMessage propose:phone], t) remaining:50 << 20 sortsFirst:NO
         group:group];
    SZFriendsBoostRow *row = [mac rowForTransfer:t];
    CHECK(row.stage != SZFriendsBoostStageAsking && !row.leavesWiFi, @"no question on the row");
    CHECK(group.sent.lastObject.step == SZFriendsBoostStepReady &&
              (group.sent.lastObject.abilities & SZFriendsBoostDirectWiFiAllowed),
          @"READY at once, saying this Mac allows it");
    CHECK(![mac answerTransfer:t goFaster:YES], @"nothing to answer");
    SZFriendsBoostLink *link = [SZFriendsBoostLink random];
    [mac group:@1 receivedFrame:PhoneSays([SZFriendsBoostMessage ready:phone], t) remaining:0 sortsFirst:NO group:group];
    [mac group:@1
        receivedFrame:PhoneSays([SZFriendsBoostMessage host:link address:Bytes(@"c0a83101") port:50000], t)
            remaining:0
           sortsFirst:NO
                group:group];
    Spin();
    CHECK([wifi.log containsObject:[@"join " stringByAppendingString:link.network]], @"joined: %@", wifi.log);
    CHECK([[NSFileManager defaultManager] fileExistsAtPath:record], @"the network to come back to is written down");
    CHECK([group.log containsObject:@"dial c0a83101:50000"], @"the lane is dialed: %@", group.log);
    [mac group:@1 directLaneUp:YES];
    CHECK([mac rowForTransfer:t].stage == SZFriendsBoostStageDirect, @"direct");
    [mac group:@1 transferEnded:t];
    Spin();
    CHECK([wifi.log.lastObject isEqualToString:[@"rejoin - from " stringByAppendingString:link.network]],
          @"off the link, back on Ethernet only: %@", wifi.log);
    CHECK(group.sent.lastObject.step == SZFriendsBoostStepEnd && [group.log containsObject:@"close lane"],
          @"END sent, the lane closed");
    Spin();
    CHECK(![[NSFileManager defaultManager] fileExistsAtPath:record], @"the record is gone once online again");
    CHECK([mac rowForTransfer:t].stage == SZFriendsBoostStageNone, @"nothing more on the row");

    // A crash while on a link: the next launch goes back to the network the record names, then deletes it.
    SZFriendsBoostSaved *saved = [SZFriendsBoostSaved savedWithNetwork:@"HomeWiFi" networkName:@"HomeWiFi"
                                                                joined:@"DIRECT-k3Qp7xTz2a" leftAt:1.8e9];
    [saved.JSON writeToFile:record atomically:YES];
    MockWiFi *afterCrash = [MockWiFi new];
    afterCrash.network = @"DIRECT-k3Qp7xTz2a";
    SZFriendsDirectWiFiCoordinator *relaunched =
        [[SZFriendsDirectWiFiCoordinator alloc] initWithWiFi:afterCrash recordPath:record
                                                       queue:dispatch_get_main_queue()];
    [relaunched launched];
    Spin();
    CHECK(([afterCrash.log isEqualToArray:@[ @"rejoin HomeWiFi from DIRECT-k3Qp7xTz2a" ]] &&
           ![[NSFileManager defaultManager] fileExistsAtPath:record]),
          @"back after a crash: %@", afterCrash.log);

    // The owner's rule: a Mac on its Wi-Fi declines without asking, and so does any Mac to a phone that did not
    // say it allows direct Wi-Fi (on Wi-Fi without mobile data, or a helper from before the rule).
    Group *second = [Group new];
    MockWiFi *homeWiFi = [MockWiFi new];
    homeWiFi.network = @"HomeWiFi";
    SZFriendsDirectWiFiCoordinator *onWiFi = [[SZFriendsDirectWiFiCoordinator alloc] initWithWiFi:homeWiFi
                                                                                       recordPath:record
                                                                                            queue:dispatch_get_main_queue()];
    [onWiFi group:@2 receivedFrame:PhoneSays([SZFriendsBoostMessage propose:phone], t) remaining:50 << 20 sortsFirst:NO
            group:second];
    CHECK([onWiFi rowForTransfer:t].stage == SZFriendsBoostStageNone &&
              second.sent.lastObject.reason == SZFriendsBoostReasonUnsupported && homeWiFi.log.count == 0,
          @"on Wi-Fi: declined, nothing joined");
    Group *third = [Group new];
    SZFriendsDirectWiFiCoordinator *older = [[SZFriendsDirectWiFiCoordinator alloc] initWithWiFi:[MockWiFi new]
                                                                                      recordPath:record
                                                                                           queue:dispatch_get_main_queue()];
    SZFriendsBoostAbilities oldPhone = SZFriendsBoostCanHost | SZFriendsBoostCanJoin;
    [older group:@3 receivedFrame:PhoneSays([SZFriendsBoostMessage propose:oldPhone], t) remaining:50 << 20
          sortsFirst:NO group:third];
    CHECK(third.sent.lastObject.reason == SZFriendsBoostReasonUnsupported,
          @"a phone that did not say it allows it: declined");
    [[NSFileManager defaultManager] removeItemAtPath:home error:NULL];
}

int SZFriendsDirectWiFiBoostTests(void) {
    TestDecisions();
    TestLinkAndFrames();
    TestNegotiation();
    TestRejoin();
    TestCoordinator();
    return failures;
}
