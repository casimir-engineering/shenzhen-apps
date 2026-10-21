// A test home's Bluetooth: an SZFriendsBluetoothRadio over a directory the test made, on loopback only, the same
// air as the Rust helper's (core-rs/crates/szfriends-helper/src/nearby/test_air.rs), so a Rust helper and this one
// sharing a directory find each other and open channels. One Mac cannot discover itself, and a real radio would ask
// the person for access; real radios are tested on hardware only (hardware-matrix.md).
//
// Each powered radio is `<id>.air`, JSON {"presence": hex|null, "public": hex|null, "channels": {"<psm>": port}},
// with a fresh random id each power-up, as a real device's address would be. Advertising writes the values (none
// while not advertising); scanning polls the directory and reports each device once per scan, and again when its
// public flag changes; a read returns the file's values; a channel is a TCP listener on 127.0.0.1 whose connections
// reach the adapter as run-loop streams, as an L2CAP channel's do.

#import "service/discovery/SZFriendsCoreBluetoothRadioInternal.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

static NSString *const kSuffix = @".air";
static const NSTimeInterval kPoll = 0.15;
static const uint16_t kFirstPSM = 0x0081; // LE dynamic PSMs: odd, 0x0081 to 0x00FF

static NSString *Hex(NSData *data) {
    NSMutableString *text = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [text appendFormat:@"%02x", bytes[i]];
    return text;
}

static NSData *FromHex(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] % 2) return nil;
    NSString *text = value;
    NSMutableData *data = [NSMutableData dataWithCapacity:text.length / 2];
    for (NSUInteger i = 0; i < text.length; i += 2) {
        unsigned int byte = 0;
        NSScanner *scanner = [NSScanner scannerWithString:[text substringWithRange:NSMakeRange(i, 2)]];
        if (![scanner scanHexInt:&byte] || !scanner.isAtEnd) return nil;
        uint8_t b = (uint8_t)byte;
        [data appendBytes:&b length:1];
    }
    return data;
}

// One device's air, as its file says; nil when unreadable.
@interface SZFriendsAirEntry : NSObject
@property(nonatomic, nullable) NSData *presence;
@property(nonatomic, nullable) NSData *publicValue;
@property(nonatomic) NSDictionary<NSNumber *, NSNumber *> *channels; // psm -> port
@end

@implementation SZFriendsAirEntry
@end

static SZFriendsAirEntry *ReadAir(NSString *directory, NSString *peripheralID) {
    NSString *path = [directory stringByAppendingPathComponent:[peripheralID stringByAppendingString:kSuffix]];
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    NSDictionary *value = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL] : nil;
    if (![value isKindOfClass:[NSDictionary class]] || ![value[@"channels"] isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSMutableDictionary<NSNumber *, NSNumber *> *channels = [NSMutableDictionary dictionary];
    for (NSString *psm in value[@"channels"]) {
        NSNumber *port = value[@"channels"][psm];
        if (![port isKindOfClass:[NSNumber class]] || psm.intValue <= 0 || psm.intValue > UINT16_MAX) return nil;
        channels[@(psm.intValue)] = port;
    }
    SZFriendsAirEntry *entry = [SZFriendsAirEntry new];
    entry.presence = FromHex(value[@"presence"]);
    entry.publicValue = FromHex(value[@"public"]);
    entry.channels = channels;
    return entry;
}

static void Configure(int fd) {
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    int flags = fcntl(fd, F_GETFL);
    if (flags >= 0) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
}

// A connected TCP socket as the stream an L2CAP channel would give; the streams close the socket.
static id<SZFriendsByteStream> StreamOverSocket(int fd) {
    Configure(fd);
    CFReadStreamRef input = NULL;
    CFWriteStreamRef output = NULL;
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, fd, &input, &output);
    if (input == NULL || output == NULL) {
        if (input) CFRelease(input);
        if (output) CFRelease(output);
        close(fd);
        return nil;
    }
    CFReadStreamSetProperty(input, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFWriteStreamSetProperty(output, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    return [[SZFriendsRunLoopByteStream alloc] initWithInputStream:(__bridge_transfer NSInputStream *)input
                                                      outputStream:(__bridge_transfer NSOutputStream *)output
                                                             owner:nil
                                                preferredWriteSize:SZFriendsL2CAPPreferredWriteSize];
}

static struct sockaddr_in Loopback(uint16_t port) {
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return address;
}

@interface SZFriendsTestAirRadio : NSObject <SZFriendsBluetoothRadio>
- (instancetype)initWithQueue:(dispatch_queue_t)queue directory:(NSString *)directory power:(NSString *)power;
@end

@implementation SZFriendsTestAirRadio {
    dispatch_queue_t _queue;
    NSString *_directory;
    NSString *_power;
    NSString *_id; // nil while powered down
    NSData *_presence, *_publicValue;
    NSMutableDictionary<NSNumber *, NSNumber *> *_ports;            // psm -> port, as the file says
    NSMutableDictionary<NSNumber *, dispatch_source_t> *_listeners; // psm -> accepting source
    dispatch_source_t _scan;
    NSMutableDictionary<NSString *, NSNumber *> *_reported; // this scan: id -> public flag reported
    uint16_t _nextPSM;
    NSUInteger _writes;
}

@synthesize delegate = _delegate;

- (instancetype)initWithQueue:(dispatch_queue_t)queue directory:(NSString *)directory power:(NSString *)power {
    if ((self = [super init])) {
        _queue = queue;
        _directory = [directory copy];
        _power = [power copy] ?: @"";
        _ports = [NSMutableDictionary dictionary];
        _listeners = [NSMutableDictionary dictionary];
        _nextPSM = kFirstPSM;
    }
    return self;
}

- (void)dealloc {
    for (dispatch_source_t source in _listeners.allValues) dispatch_source_cancel(source);
    if (_scan) dispatch_source_cancel(_scan);
    if (_id) [[NSFileManager defaultManager] removeItemAtPath:[self ownPath] error:NULL];
}

- (SZFriendsPermission)permissionWithoutPrompting {
    if ([_power isEqualToString:@"denied"]) return SZFriendsPermissionDenied;
    if ([_power isEqualToString:@"ask"]) return SZFriendsPermissionNotDetermined;
    return SZFriendsPermissionAllowed;
}

- (NSString *)ownPath {
    return [_directory stringByAppendingPathComponent:[_id stringByAppendingString:kSuffix]];
}

- (void)write {
    if (_id == nil) return;
    NSMutableDictionary<NSString *, NSNumber *> *channels = [NSMutableDictionary dictionary];
    for (NSNumber *psm in _ports) channels[psm.stringValue] = _ports[psm];
    NSDictionary *value = @{
        @"presence" : _presence ? Hex(_presence) : [NSNull null],
        @"public" : _publicValue ? Hex(_publicValue) : [NSNull null],
        @"channels" : channels,
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    // Written beside and renamed over, so a scanner never reads half a file; the dot keeps it out of scans.
    NSString *name = [NSString stringWithFormat:@".%@%@.%d.%lu.tmp", _id, kSuffix, getpid(), (unsigned long)++_writes];
    NSString *temporary = [_directory stringByAppendingPathComponent:name];
    if (![json writeToFile:temporary atomically:NO]) return;
    if (rename(temporary.fileSystemRepresentation, [self ownPath].fileSystemRepresentation) != 0) {
        unlink(temporary.fileSystemRepresentation);
    }
}

#pragma mark - Power

- (void)powerUp {
    if (_id) return;
    uint8_t bytes[6];
    arc4random_buf(bytes, sizeof(bytes));
    _id = Hex([NSData dataWithBytes:bytes length:sizeof(bytes)]);
    SZFriendsRadioPower power = SZFriendsRadioPowerOn;
    if ([_power isEqualToString:@"off"]) power = SZFriendsRadioPowerOff;
    else if ([_power isEqualToString:@"denied"]) power = SZFriendsRadioPowerUnauthorized;
    else if ([_power isEqualToString:@"unsupported"]) power = SZFriendsRadioPowerUnsupported;
    NSString *powered = _id;
    // Later, as a manager's first state update arrives.
    dispatch_async(_queue, ^{
        if (![self->_id isEqualToString:powered]) return;
        [self.delegate radioDidUpdatePower:power];
    });
}

- (void)powerDown {
    if (_id == nil) return;
    [self stopScanning];
    for (dispatch_source_t source in _listeners.allValues) dispatch_source_cancel(source);
    [_listeners removeAllObjects];
    [_ports removeAllObjects];
    [[NSFileManager defaultManager] removeItemAtPath:[self ownPath] error:NULL];
    _id = nil;
    _presence = _publicValue = nil;
}

#pragma mark - Scanning

- (void)startScanning {
    if (_id == nil) return;
    [self stopScanning];
    _reported = [NSMutableDictionary dictionary];
    _scan = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_scan, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(kPoll * NSEC_PER_SEC),
                              (uint64_t)(0.02 * NSEC_PER_SEC));
    __weak SZFriendsTestAirRadio *weakSelf = self;
    dispatch_source_set_event_handler(_scan, ^{ [weakSelf scanOnce]; });
    dispatch_resume(_scan);
}

- (void)stopScanning {
    if (_scan) dispatch_source_cancel(_scan);
    _scan = nil;
}

- (void)scanOnce {
    if (_scan == nil || _id == nil) return;
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory error:NULL];
    for (NSString *name in names) {
        if (![name hasSuffix:kSuffix] || [name hasPrefix:@"."]) continue;
        NSString *peripheralID = [name substringToIndex:name.length - kSuffix.length];
        if ([peripheralID isEqualToString:_id]) continue;
        SZFriendsAirEntry *air = ReadAir(_directory, peripheralID);
        if (air.presence == nil) continue;
        BOOL publicEntry = air.publicValue != nil;
        NSNumber *reported = _reported[peripheralID];
        if (reported != nil && reported.boolValue == publicEntry) continue;
        _reported[peripheralID] = @(publicEntry);
        [self.delegate radioDidDiscoverPeripheral:peripheralID publicEntry:publicEntry];
        if (_scan == nil) return; // the delegate stopped scanning
    }
}

#pragma mark - Advertising

- (void)advertisePresenceValue:(NSData *)presenceValue publicValue:(NSData *)publicValue {
    _presence = [presenceValue copy];
    _publicValue = [publicValue copy];
    [self write];
}

- (void)stopAdvertising {
    _presence = _publicValue = nil;
    [self write];
}

#pragma mark - Channels

- (uint16_t)takePSM {
    uint16_t psm = _nextPSM;
    _nextPSM = psm >= 0x00FD ? kFirstPSM : (uint16_t)(psm + 2);
    return psm;
}

- (void)publishChannelForPublicEntry:(BOOL)publicEntry {
    if (_id == nil) return;
    NSString *powered = _id;
    uint16_t psm = 0, port = 0;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = Loopback(0);
    socklen_t length = sizeof(address);
    if (fd >= 0 && bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(fd, 16) == 0 &&
        getsockname(fd, (struct sockaddr *)&address, &length) == 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0) {
        port = ntohs(address.sin_port);
        psm = [self takePSM];
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
        __weak SZFriendsTestAirRadio *weakSelf = self;
        dispatch_source_set_event_handler(source, ^{ [weakSelf acceptOn:fd publicEntry:publicEntry]; });
        dispatch_source_set_cancel_handler(source, ^{ close(fd); });
        dispatch_resume(source);
        _listeners[@(psm)] = source;
        _ports[@(psm)] = @(port);
        [self write];
    } else if (fd >= 0) {
        close(fd);
    }
    dispatch_async(_queue, ^{
        if (![self->_id isEqualToString:powered]) return;
        [self.delegate radioDidPublishChannelWithPSM:psm publicEntry:publicEntry];
    });
}

- (void)acceptOn:(int)listener publicEntry:(BOOL)publicEntry {
    for (;;) {
        struct sockaddr_in from = {0};
        socklen_t length = sizeof(from);
        int fd = accept(listener, (struct sockaddr *)&from, &length);
        if (fd < 0) return;
        id<SZFriendsByteStream> stream = StreamOverSocket(fd);
        if (stream == nil) continue;
        char text[INET_ADDRSTRLEN] = "";
        inet_ntop(AF_INET, &from.sin_addr, text, sizeof(text));
        [self.delegate radioDidAcceptChannel:stream publicEntry:publicEntry peerID:@(text)];
    }
}

- (void)unpublishChannelWithPSM:(uint16_t)psm {
    dispatch_source_t source = _listeners[@(psm)];
    if (source) dispatch_source_cancel(source);
    [_listeners removeObjectForKey:@(psm)];
    [_ports removeObjectForKey:@(psm)];
    [self write];
}

#pragma mark - Central

- (void)readPresenceFromPeripheral:(NSString *)peripheralID publicEntry:(BOOL)publicEntry {
    if (_id == nil) return;
    NSString *directory = _directory, *powered = _id;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SZFriendsAirEntry *air = ReadAir(directory, peripheralID);
        dispatch_async(self->_queue, ^{
            if (![self->_id isEqualToString:powered]) return;
            [self.delegate radioDidReadPresence:air.presence
                                    publicValue:publicEntry ? air.publicValue : nil
                                 fromPeripheral:peripheralID];
        });
    });
}

- (void)openChannelToPeripheral:(NSString *)peripheralID
                            psm:(uint16_t)psm
                     completion:(void (^)(id<SZFriendsByteStream> stream, NSError *error))completion {
    NSString *directory = _directory;
    dispatch_queue_t queue = _queue;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSNumber *port = ReadAir(directory, peripheralID).channels[@(psm)];
        id<SZFriendsByteStream> stream = nil;
        if (port != nil) {
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in address = Loopback(port.unsignedShortValue);
            if (fd >= 0 && connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) {
                stream = StreamOverSocket(fd);
            } else if (fd >= 0) {
                close(fd);
            }
        }
        NSError *error = stream ? nil
                                : SZFriendsDiscoveryMakeError(port ? SZFriendsDiscoveryErrorTimedOut
                                                                   : SZFriendsDiscoveryErrorNoChannel,
                                                              @"the test air's channel did not answer");
        dispatch_async(queue, ^{ completion(stream, error); });
    });
}

@end

id<SZFriendsBluetoothRadio> SZFriendsMakeTestAirRadio(dispatch_queue_t queue, NSString *directory,
                                                       NSString *power) {
    return [[SZFriendsTestAirRadio alloc] initWithQueue:queue directory:directory power:power ?: @""];
}
