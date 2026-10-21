// The test air radio (SZFriendsTestAirRadio.m): two radios in one directory find each other, read each other's
// values and open a channel that carries bytes both ways; a file written as the Rust helper's test air writes it is
// read the same way; powering down takes the device off the air.

#import "SZFriendsDiscoveryTestSupport.h"
#import "service/discovery/SZFriendsBluetoothRadio.h"

#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

@interface SZFTAirRecorder : NSObject <SZFriendsBluetoothRadioDelegate>
@property(nonatomic) SZFriendsRadioPower power;
@property(nonatomic) NSMutableArray<NSString *> *discovered; // "id" or "id/public"
@property(nonatomic) NSMutableArray<NSNumber *> *published;
@property(nonatomic, nullable) NSData *readValue, *readPublic;
@property(nonatomic) BOOL readDone;
@property(nonatomic) NSMutableArray<id<SZFriendsByteStream>> *accepted;
@end

@implementation SZFTAirRecorder
- (instancetype)init {
    if ((self = [super init])) {
        _discovered = [NSMutableArray array];
        _published = [NSMutableArray array];
        _accepted = [NSMutableArray array];
    }
    return self;
}
- (void)radioDidUpdatePower:(SZFriendsRadioPower)power {
    self.power = power;
}
- (void)radioDidDiscoverPeripheral:(NSString *)peripheralID publicEntry:(BOOL)publicEntry {
    [self.discovered addObject:publicEntry ? [peripheralID stringByAppendingString:@"/public"] : peripheralID];
}
- (void)radioDidReadPresence:(NSData *)value publicValue:(NSData *)publicValue fromPeripheral:(NSString *)peripheralID {
    (void)peripheralID;
    self.readValue = value;
    self.readPublic = publicValue;
    self.readDone = YES;
}
- (void)radioDidPublishChannelWithPSM:(uint16_t)psm publicEntry:(BOOL)publicEntry {
    (void)publicEntry;
    [self.published addObject:@(psm)];
}
- (void)radioDidAcceptChannel:(id<SZFriendsByteStream>)stream publicEntry:(BOOL)publicEntry peerID:(NSString *)peerID {
    (void)publicEntry;
    (void)peerID;
    [self.accepted addObject:stream];
}
@end

static NSString *AirDirectory(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
    return path;
}

static NSArray<NSString *> *AirFiles(NSString *directory) {
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL];
    return [names filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH '.air'"]];
}

// Collects what `stream` reads, on `queue`.
static NSMutableData *Collect(id<SZFriendsByteStream> stream, dispatch_queue_t queue) {
    NSMutableData *received = [NSMutableData data];
    stream.onData = ^(NSData *data) { [received appendData:data]; };
    stream.onClose = ^(NSError *error) { (void)error; };
    [stream startWithQueue:queue];
    return received;
}

static void TestTwoRadios(void) {
    dispatch_queue_t queue = dispatch_queue_create("szft.air", DISPATCH_QUEUE_SERIAL);
    NSString *directory = AirDirectory();
    SZFTAirRecorder *ra = [SZFTAirRecorder new], *rb = [SZFTAirRecorder new];
    __block id<SZFriendsBluetoothRadio> a, b;
    dispatch_sync(queue, ^{
        a = SZFriendsMakeTestAirRadio(queue, directory, nil);
        b = SZFriendsMakeTestAirRadio(queue, directory, @"");
        a.delegate = ra;
        b.delegate = rb;
        CHECK(a.permissionWithoutPrompting == SZFriendsPermissionAllowed);
        [a powerUp];
        [b powerUp];
    });
    CHECK(SZFTestWait(queue, 2, ^BOOL { return ra.power == SZFriendsRadioPowerOn && rb.power == SZFriendsRadioPowerOn; }));
    dispatch_sync(queue, ^{
        [a publishChannelForPublicEntry:NO];
        [a advertisePresenceValue:SZFTestData(@"0102") publicValue:SZFTestData(@"0304")];
        [b startScanning];
    });
    CHECK(SZFTestWait(queue, 2, ^BOOL { return ra.published.count == 1 && rb.discovered.count == 1; }));
    __block uint16_t psm = 0;
    dispatch_sync(queue, ^{ psm = ra.published.firstObject.unsignedShortValue; });
    CHECK(psm == 0x0081, "the first dynamic PSM (%u)", psm);
    NSString *seen = rb.discovered.firstObject;
    CHECK([seen hasSuffix:@"/public"], "%@", seen);
    NSString *peripheral = [seen stringByReplacingOccurrencesOfString:@"/public" withString:@""];
    CHECK(peripheral.length == 12, "a fresh 6-byte id (%@)", peripheral);
    dispatch_sync(queue, ^{ [b readPresenceFromPeripheral:peripheral publicEntry:YES]; });
    CHECK(SZFTestWait(queue, 2, ^BOOL { return rb.readDone; }));
    CHECK([rb.readValue isEqual:SZFTestData(@"0102")] && [rb.readPublic isEqual:SZFTestData(@"0304")]);

    __block id<SZFriendsByteStream> opened = nil;
    __block BOOL done = NO;
    dispatch_sync(queue, ^{
        [b openChannelToPeripheral:peripheral
                               psm:psm
                        completion:^(id<SZFriendsByteStream> stream, NSError *error) {
                            CHECK(stream != nil, "%@", error);
                            opened = stream;
                            done = YES;
                        }];
    });
    CHECK(SZFTestWait(queue, 3, ^BOOL { return done && ra.accepted.count == 1; }));
    if (opened && ra.accepted.count == 1) {
        __block NSMutableData *atA, *atB;
        dispatch_sync(queue, ^{
            atA = Collect(ra.accepted.firstObject, queue);
            atB = Collect(opened, queue);
        });
        [opened writeData:[@"hello" dataUsingEncoding:NSUTF8StringEncoding] completion:nil];
        [ra.accepted.firstObject writeData:[@"back" dataUsingEncoding:NSUTF8StringEncoding] completion:nil];
        CHECK(SZFTestWait(queue, 3, ^BOOL { return atA.length == 5 && atB.length == 4; }), "%@ %@", atA, atB);
        [opened close];
        [ra.accepted.firstObject close];
    }

    // A rescan reports the device again; no longer public, it is reported without the public entry.
    dispatch_sync(queue, ^{
        [a advertisePresenceValue:SZFTestData(@"0102") publicValue:nil];
    });
    CHECK(SZFTestWait(queue, 2, ^BOOL { return [rb.discovered.lastObject isEqualToString:peripheral]; }), "%@",
          rb.discovered);
    dispatch_sync(queue, ^{
        [a powerDown];
        [b powerDown];
    });
    CHECK(AirFiles(directory).count == 0, "powered down, nothing on the air: %@", AirFiles(directory));
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

// The Rust helper's test air writes this; its channel is a plain loopback listener.
static void TestRustWrittenAir(void) {
    dispatch_queue_t queue = dispatch_queue_create("szft.rustair", DISPATCH_QUEUE_SERIAL);
    NSString *directory = AirDirectory();
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof(address);
    CHECK(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(listener, 1) == 0 &&
          getsockname(listener, (struct sockaddr *)&address, &length) == 0);
    NSString *json = [NSString stringWithFormat:@"{\"presence\":\"a1b2\",\"public\":null,\"channels\":{\"131\":%u}}",
                                                ntohs(address.sin_port)];
    [json writeToFile:[directory stringByAppendingPathComponent:@"00aabbccddee.air"] atomically:YES
             encoding:NSUTF8StringEncoding error:NULL];
    [@"{}" writeToFile:[directory stringByAppendingPathComponent:@".00aabbccddee.air.1.0.tmp"] atomically:YES
              encoding:NSUTF8StringEncoding error:NULL];
    SZFTAirRecorder *recorder = [SZFTAirRecorder new];
    __block id<SZFriendsBluetoothRadio> radio;
    dispatch_sync(queue, ^{
        radio = SZFriendsMakeTestAirRadio(queue, directory, nil);
        radio.delegate = recorder;
        [radio powerUp];
    });
    CHECK(SZFTestWait(queue, 2, ^BOOL { return recorder.power == SZFriendsRadioPowerOn; }));
    dispatch_sync(queue, ^{ [radio startScanning]; });
    CHECK(SZFTestWait(queue, 2, ^BOOL { return recorder.discovered.count == 1; }));
    CHECK([recorder.discovered isEqualToArray:@[ @"00aabbccddee" ]], "%@", recorder.discovered);
    dispatch_sync(queue, ^{ [radio readPresenceFromPeripheral:@"00aabbccddee" publicEntry:NO]; });
    CHECK(SZFTestWait(queue, 2, ^BOOL { return recorder.readDone; }));
    CHECK([recorder.readValue isEqual:SZFTestData(@"a1b2")] && recorder.readPublic == nil);
    __block BOOL opened = NO;
    dispatch_sync(queue, ^{
        [radio openChannelToPeripheral:@"00aabbccddee"
                                   psm:131
                            completion:^(id<SZFriendsByteStream> stream, NSError *error) {
                                CHECK(stream != nil, "%@", error);
                                [stream close];
                                opened = YES;
                            }];
    });
    CHECK(SZFTestWait(queue, 3, ^BOOL { return opened; }));
    int accepted = accept(listener, NULL, NULL);
    CHECK(accepted >= 0, "the channel reached the listener");
    if (accepted >= 0) close(accepted);
    close(listener);
    // Its own file, once advertising, is in the same format.
    dispatch_sync(queue, ^{ [radio advertisePresenceValue:SZFTestData(@"ff") publicValue:nil]; });
    NSArray<NSString *> *files = AirFiles(directory);
    CHECK(files.count == 2, "%@", files);
    for (NSString *name in files) {
        if ([name isEqualToString:@"00aabbccddee.air"]) continue;
        NSData *bytes = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
        NSDictionary *value = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
        CHECK([value[@"presence"] isEqual:@"ff"] && value[@"public"] == [NSNull null] &&
                  [value[@"channels"] isEqual:@{}],
              "%@", value);
    }
    dispatch_sync(queue, ^{ [radio powerDown]; });
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

static void TestPowerSettings(void) {
    dispatch_queue_t queue = dispatch_queue_create("szft.power", DISPATCH_QUEUE_SERIAL);
    NSString *directory = AirDirectory();
    NSDictionary<NSString *, NSNumber *> *powers = @{
        @"off" : @(SZFriendsRadioPowerOff),
        @"denied" : @(SZFriendsRadioPowerUnauthorized),
        @"unsupported" : @(SZFriendsRadioPowerUnsupported),
    };
    for (NSString *setting in powers) {
        SZFTAirRecorder *recorder = [SZFTAirRecorder new];
        __block id<SZFriendsBluetoothRadio> radio;
        dispatch_sync(queue, ^{
            radio = SZFriendsMakeTestAirRadio(queue, directory, setting);
            radio.delegate = recorder;
            [radio powerUp];
        });
        CHECK(SZFTestWait(queue, 2, ^BOOL { return recorder.power == powers[setting].integerValue; }), "%@", setting);
        dispatch_sync(queue, ^{ [radio powerDown]; });
    }
    CHECK(SZFriendsMakeTestAirRadio(queue, directory, @"denied").permissionWithoutPrompting ==
          SZFriendsPermissionDenied);
    CHECK(SZFriendsMakeTestAirRadio(queue, directory, @"ask").permissionWithoutPrompting ==
          SZFriendsPermissionNotDetermined);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

void SZFriendsRunTestAirTests(void) {
    TestTwoRadios();
    TestRustWrittenAir();
    TestPowerSettings();
    CHECK(SZFriendsCoreBluetoothManagersCreated() == 0, "the test air never creates a Bluetooth manager");
}
