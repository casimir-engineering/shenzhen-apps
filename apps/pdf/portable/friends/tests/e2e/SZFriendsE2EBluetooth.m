// The harness's scripted Bluetooth adapter (SZFriendsE2EBluetooth.h): adverts as files, channels as Unix sockets.

#import "SZFriendsE2EBluetooth.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

#import "SZFriendsE2ESocketStream.h"

const double SZFriendsE2EBluetoothBytesPerSecond = 200 * 1000;

// Like a scan restarting: what others advertise is read this often, and an unchanged sighting is repeated now and
// then so it never ages out of the merger (90 s for Bluetooth).
static const NSTimeInterval SZFE2EPollInterval = 0.25;
static const NSTimeInterval SZFE2EResight = 10;
// Adverts carry a heartbeat: a helper killed with -9 leaves its file behind, and a silent one is out of range.
static const NSTimeInterval SZFE2EHeartbeat = 1;
static const NSTimeInterval SZFE2EAdvertLife = 4;

static NSString *SZFE2EHex(NSData *data) {
    NSMutableString *hex = [NSMutableString string];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static NSData *SZFE2EData(id hex) {
    if (![hex isKindOfClass:[NSString class]] || [hex length] % 2 != 0) return nil;
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < [hex length]; i += 2) {
        unsigned value = 0;
        if (sscanf([[hex substringWithRange:NSMakeRange(i, 2)] UTF8String], "%2x", &value) != 1) return nil;
        uint8_t byte = (uint8_t)value;
        [data appendBytes:&byte length:1];
    }
    return data;
}

@interface SZFE2EScriptedBluetooth : NSObject <SZFriendsDiscoveryAdapter>
- (instancetype)initWithQueue:(dispatch_queue_t)queue directory:(NSString *)directory;
@end

@implementation SZFE2EScriptedBluetooth {
    dispatch_queue_t _queue;
    NSString *_directory;
    NSString *_name;
    BOOL _running;
    int _listeners[2];
    dispatch_source_t _listenerSources[2];
    dispatch_source_t _pollTimer;
    NSData *_tag;
    NSArray<NSData *> *_callbackTags;
    BOOL _publicEntry;
    NSMutableDictionary<NSString *, NSString *> *_seen;      // endpoint -> what it advertised
    NSMutableDictionary<NSString *, NSDate *> *_seenAt;      // endpoint -> last reported
    NSDate *_advertisedAt;
}

@synthesize delegate = _delegate;
@synthesize state = _state;

- (instancetype)initWithQueue:(dispatch_queue_t)queue directory:(NSString *)directory {
    if ((self = [super init])) {
        _queue = queue;
        _directory = [directory copy];
        _name = [NSString stringWithFormat:@"%08x", arc4random()];
        _listeners[0] = _listeners[1] = -1;
        _callbackTags = @[];
        _seen = [NSMutableDictionary dictionary];
        _seenAt = [NSMutableDictionary dictionary];
    }
    return self;
}

- (SZFriendsDiscoveryMethod)method {
    return SZFriendsDiscoveryMethodBluetooth;
}

- (SZFriendsPermission)permissionWithoutPrompting {
    return SZFriendsPermissionAllowed;
}

- (void)setState:(SZFriendsAdapterState)state {
    if (_state == state) return;
    _state = state;
    [self.delegate adapter:self didChangeState:state];
}

- (NSString *)pathFor:(NSString *)name suffix:(NSString *)suffix {
    return [_directory stringByAppendingPathComponent:[name stringByAppendingString:suffix]];
}

#pragma mark - Lifecycle

- (void)start {
    if (_running) return;
    _running = YES;
    self.state = SZFriendsAdapterStateStarting;
    [self openListener:0];
    [self updateAdvert];
    _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    __weak SZFE2EScriptedBluetooth *weakSelf = self;
    dispatch_source_set_event_handler(_pollTimer, ^{ [weakSelf poll]; });
    dispatch_source_set_timer(_pollTimer, DISPATCH_TIME_NOW, (uint64_t)(SZFE2EPollInterval * NSEC_PER_SEC),
                              NSEC_PER_SEC / 50);
    dispatch_resume(_pollTimer);
    self.state = SZFriendsAdapterStateWorking;
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    if (_pollTimer != nil) dispatch_source_cancel(_pollTimer);
    _pollTimer = nil;
    [self closeListener:0];
    [self closeListener:1];
    [[NSFileManager defaultManager] removeItemAtPath:[self pathFor:_name suffix:@".adv"] error:NULL];
    for (NSString *endpoint in _seen.allKeys) [self.delegate adapter:self didLoseEndpoint:endpoint];
    [_seen removeAllObjects];
    [_seenAt removeAllObjects];
    self.state = SZFriendsAdapterStateNotAsked;
}

- (void)advertisePresenceTag:(NSData *)tag
                callbackTags:(NSArray<NSData *> *)callbackTags
                 publicEntry:(BOOL)publicEntry {
    _tag = [tag copy];
    _callbackTags = [callbackTags copy];
    _publicEntry = publicEntry;
    if (_running) [self updateAdvert];
}

- (void)updateAdvert {
    if (_publicEntry && _listeners[1] < 0) [self openListener:1];
    if (!_publicEntry && _listeners[1] >= 0) [self closeListener:1];
    NSMutableArray *callbacks = [NSMutableArray array];
    for (NSData *callback in _callbackTags) [callbacks addObject:SZFE2EHex(callback)];
    NSDictionary *advert = @{@"t" : _tag ? SZFE2EHex(_tag) : [NSNull null], @"c" : callbacks, @"p" : @(_publicEntry),
                             @"at" : @([NSDate date].timeIntervalSince1970)};
    NSData *json = [NSJSONSerialization dataWithJSONObject:advert options:0 error:NULL];
    [json writeToFile:[self pathFor:_name suffix:@".adv"] atomically:YES];
    _advertisedAt = [NSDate date];
}

#pragma mark - Channels

- (void)openListener:(int)which {
    NSString *path = [self pathFor:_name suffix:which == 0 ? @".h" : @".p"];
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    size_t length = strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path));
    if (length >= sizeof(address.sun_path)) {
        self.state = SZFriendsAdapterStateUnavailable;
        return;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    unlink(path.fileSystemRepresentation);
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, (socklen_t)SUN_LEN(&address)) != 0 || listen(fd, 16) != 0) {
        if (fd >= 0) close(fd);
        self.state = SZFriendsAdapterStateUnavailable;
        return;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    _listeners[which] = fd;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    __weak SZFE2EScriptedBluetooth *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{ [weakSelf acceptOn:fd publicEntry:which == 1]; });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    dispatch_resume(source);
    _listenerSources[which] = source;
}

- (void)closeListener:(int)which {
    if (_listeners[which] < 0) return;
    unlink([self pathFor:_name suffix:which == 0 ? @".h" : @".p"].fileSystemRepresentation);
    dispatch_source_cancel(_listenerSources[which]);
    _listenerSources[which] = nil;
    _listeners[which] = -1;
}

- (void)acceptOn:(int)listener publicEntry:(BOOL)publicEntry {
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) return;
    SZFE2ESocketStream *stream = [[SZFE2ESocketStream alloc] initWithDescriptor:fd
                                                                 bytesPerSecond:SZFriendsE2EBluetoothBytesPerSecond
                                                                          queue:_queue];
    id<SZFriendsDiscoveryAdapterDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(adapter:didAcceptStream:route:publicEntry:)]) {
        [delegate adapter:self didAcceptStream:stream route:SZFriendsRouteMethodBluetooth publicEntry:publicEntry];
    } else {
        [delegate adapter:self didAcceptStream:stream route:SZFriendsRouteMethodBluetooth];
    }
}

- (void)openStreamToEndpoint:(NSString *)endpointID
                  completion:(void (^)(id<SZFriendsByteStream> _Nullable, NSError *_Nullable))completion {
    NSArray<NSString *> *parts = [endpointID componentsSeparatedByString:@":"];
    NSString *path = parts.count >= 2 ? [self pathFor:parts[1] suffix:parts.count == 3 ? @".p" : @".h"] : nil;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    int fd = -1;
    if (_running && path != nil && _seen[endpointID] != nil &&
        strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path)) < sizeof(address.sun_path)) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd >= 0 && connect(fd, (struct sockaddr *)&address, (socklen_t)SUN_LEN(&address)) != 0) {
            close(fd);
            fd = -1;
        }
    }
    SZFE2ESocketStream *stream =
        fd >= 0 ? [[SZFE2ESocketStream alloc] initWithDescriptor:fd bytesPerSecond:SZFriendsE2EBluetoothBytesPerSecond
                                                           queue:_queue]
                : nil;
    NSError *error = stream ? nil : [NSError errorWithDomain:NSPOSIXErrorDomain code:ECONNREFUSED userInfo:nil];
    dispatch_async(_queue, ^{ completion(stream, error); });
}

#pragma mark - Scanning

- (void)poll {
    if (!_running) return;
    if (-_advertisedAt.timeIntervalSinceNow >= SZFE2EHeartbeat) [self updateAdvert];
    NSTimeInterval wall = [NSDate date].timeIntervalSince1970;
    NSMutableDictionary<NSString *, NSString *> *now = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, SZFriendsSighting *> *sightings = [NSMutableDictionary dictionary];
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory error:NULL]) {
        if (![file hasSuffix:@".adv"]) continue;
        NSString *name = [file stringByDeletingPathExtension];
        if ([name isEqualToString:_name]) continue; // a device never sees itself
        NSData *json = [NSData dataWithContentsOfFile:[_directory stringByAppendingPathComponent:file]];
        NSDictionary *advert = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL] : nil;
        if (![advert isKindOfClass:[NSDictionary class]]) continue;
        if (wall - [advert[@"at"] doubleValue] > SZFE2EAdvertLife) continue;
        NSMutableArray<NSData *> *callbacks = [NSMutableArray array];
        for (id hex in [advert[@"c"] isKindOfClass:[NSArray class]] ? advert[@"c"] : @[]) {
            NSData *tag = SZFE2EData(hex);
            if (tag.length == 8) [callbacks addObject:tag];
        }
        NSString *hidden = [@"bt:" stringByAppendingString:name];
        sightings[hidden] = [[SZFriendsSighting alloc] initWithMethod:SZFriendsDiscoveryMethodBluetooth
                                                                route:SZFriendsRouteMethodBluetooth
                                                           endpointID:hidden
                                                          presenceTag:SZFE2EData(advert[@"t"])
                                                         callbackTags:callbacks
                                                             isPublic:NO
                                                               seenAt:[NSDate date]];
        now[hidden] = [NSString stringWithFormat:@"%@|%@|%@", advert[@"t"], advert[@"c"], advert[@"p"]];
        if ([advert[@"p"] boolValue]) {
            NSString *public = [hidden stringByAppendingString:@":public"];
            sightings[public] = [[SZFriendsSighting alloc] initWithMethod:SZFriendsDiscoveryMethodBluetooth
                                                                    route:SZFriendsRouteMethodBluetooth
                                                               endpointID:public
                                                              presenceTag:nil
                                                             callbackTags:@[]
                                                                 isPublic:YES
                                                                   seenAt:[NSDate date]];
            now[public] = @"public";
        }
    }
    for (NSString *endpoint in _seen.allKeys) {
        if (now[endpoint] != nil) continue;
        [_seen removeObjectForKey:endpoint];
        [_seenAt removeObjectForKey:endpoint];
        [self.delegate adapter:self didLoseEndpoint:endpoint];
    }
    for (NSString *endpoint in sightings) {
        BOOL changed = ![_seen[endpoint] isEqualToString:now[endpoint]];
        BOOL stale = _seenAt[endpoint] == nil || -_seenAt[endpoint].timeIntervalSinceNow >= SZFE2EResight;
        if (!changed && !stale) continue;
        _seen[endpoint] = now[endpoint];
        _seenAt[endpoint] = [NSDate date];
        [self.delegate adapter:self didSight:sightings[endpoint]];
    }
}

@end

id<SZFriendsDiscoveryAdapter> SZFriendsE2EMakeScriptedBluetoothAdapter(dispatch_queue_t queue, NSString *directory) {
    return [[SZFE2EScriptedBluetooth alloc] initWithQueue:queue directory:directory];
}
