// SZFriendsClientTransport: the C client library driven from the main run loop.
//
// The library never calls back from a thread of its own (client/szfriends_client.h, threading), so this watches
// its descriptor with a dispatch source on the main queue and runs its timers with an NSTimer. The descriptor
// changes on every reconnect, so both are re-armed after every call into the library.

#import "mac/SZFriendsLinkTransport.h"
#import "mac/SZFriendsHost.h"

#include "client/szfriends_client.h"

// The library's own clock. WHY not CLOCK_UPTIME_RAW: it stops during sleep while the library's CLOCK_MONOTONIC
// does not, so after any sleep every retry deadline sat hours in the future until the library noticed the skew,
// and a dropped helper took over ten seconds to reconnect (SZFriendsViewsSessionTests, reconnect).
static uint64_t SZFNowMs(void) {
    return szfriends_monotonic_ms();
}

static SZFriendsLinkState SZFLinkStateFromClient(szfriends_connection_state state) {
    switch (state) {
    case SZFRIENDS_CONNECTION_IDLE: return SZFriendsLinkStateIdle;
    case SZFRIENDS_CONNECTION_CONNECTING:
    case SZFRIENDS_CONNECTION_HANDSHAKING: return SZFriendsLinkStateConnecting;
    case SZFRIENDS_CONNECTION_READY: return SZFriendsLinkStateReady;
    case SZFRIENDS_CONNECTION_WAITING: return SZFriendsLinkStateWaiting;
    case SZFRIENDS_CONNECTION_INCOMPATIBLE: return SZFriendsLinkStateIncompatible;
    }
    return SZFriendsLinkStateWaiting;
}

void SZFriendsSpawnHelperInBackground(id<SZFriendsHost> host) {
    // Read on the calling (main) thread: the host is main-thread only. The block does the one blocking-free
    // connect-or-spawn the brief allows on the launch path and nothing else.
    NSString *path = host.friendsHelperPath;
    if (!path.length) return;
    NSString *helper = [path copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        pid_t pid = 0;
        szfriends_spawn_helper(helper.fileSystemRepresentation, NULL, &pid);
    });
}

// What the C callbacks' context points at. WHY a box: forming a weak reference to an object in the middle of
// dealloc aborts the process, and freeing the client from -dealloc may still deliver a final callback. The box
// outlives the client; its weak `transport` is simply nil by then.
@interface SZFClientCallbackBox : NSObject
@property(nonatomic, weak) SZFriendsClientTransport *transport;
@end
@implementation SZFClientCallbackBox
@end

@implementation SZFriendsClientTransport {
    SZFClientCallbackBox *_box;
    __weak id<SZFriendsHost> _host;
    szfriends_client *_client;
    dispatch_source_t _readSource;
    int _watchedFD;
    NSTimer *_tickTimer;
}

@synthesize delegate = _delegate;

+ (NSArray<NSString *> *)capabilitiesForHost:(id<SZFriendsHost>)host {
    // `mentions`: these views offer `@`, send chips as mentions and act on mention links (SZFriendsMentionViews.h); a
    // helper then sends mentions as links rather than as plain "@Name".
    NSMutableArray *capabilities = [NSMutableArray arrayWithObjects:@"attach.items", @"drop.files", @"mentions", nil];
    if (host.friendsExtraPasteboardTypes.count) [capabilities addObject:@"drop.tabs"];
    if ([host respondsToSelector:@selector(friendsAssistant)] && host.friendsAssistant)
        [capabilities addObject:@"assistant.drafts"];
    if ([host respondsToSelector:@selector(friendsAssistantReadsChats)] && host.friendsAssistantReadsChats)
        [capabilities addObject:@"assistant.chats"];
    if ([host respondsToSelector:@selector(friendsServicesDidBecomeAvailable:)])
        [capabilities addObject:@"search.export"];
    return capabilities;
}

- (instancetype)initWithHost:(id<SZFriendsHost>)host {
    if (!(self = [super init])) return nil;
    _host = host;
    _watchedFD = -1;
    _box = [SZFClientCallbackBox new];
    _box.transport = self;
    return self;
}

- (void)dealloc {
    [self teardown];
}

// Both callbacks run inside a library call (on_readable, tick, start). They hand over on the next turn of the main
// queue, in order, so the link's reactions (re-subscribing on Ready, intents sent from a snapshot handler) never
// call back into the library while it is still dispatching.
static void SZFOnFrame(void *context, const char *json, size_t length) {
    SZFClientCallbackBox *box = (__bridge SZFClientCallbackBox *)context;
    NSData *data = [NSData dataWithBytes:json length:length];
    id frame = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![frame isKindOfClass:NSDictionary.class]) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [box.transport.delegate transportDidReceiveFrame:frame]; });
}

static void SZFOnState(void *context, szfriends_connection_state state) {
    SZFClientCallbackBox *box = (__bridge SZFClientCallbackBox *)context;
    const char *text = szfriends_connection_state_text(state);
    NSString *statusText = text ? @(text) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [box.transport.delegate transportDidChangeState:SZFLinkStateFromClient(state) statusText:statusText];
    });
}

// The embedded helper's version and build number, from the bundle around friendsHelperPath, so an older running
// helper knows to hand over (PROTOCOL.md § Handshake). Missing: version "0", build 0, which never wins a handover.
static NSDictionary *SZFHelperBundleInfo(NSString *helperPath) {
    NSString *path = helperPath;
    while (path.length > 1 && ![path.pathExtension isEqualToString:@"app"])
        path = path.stringByDeletingLastPathComponent;
    NSDictionary *info = path.length > 1 ? [NSBundle bundleWithPath:path].infoDictionary : nil;
    return info ?: @{};
}

- (void)start {
    if (_client) return;
    id<SZFriendsHost> host = _host;
    if (!host) return;
    @autoreleasepool {
        NSArray<NSString *> *capabilities = [SZFriendsClientTransport capabilitiesForHost:host];
        NSArray<NSString *> *formats = host.friendsFormatsOpenedInPlace.allObjects;
        const char *capabilityStrings[16] = {0};
        NSUInteger capabilityCount = MIN(capabilities.count, (NSUInteger)16);
        for (NSUInteger i = 0; i < capabilityCount; i++) capabilityStrings[i] = capabilities[i].UTF8String;
        NSMutableData *formatStorage = [NSMutableData dataWithLength:sizeof(char *) * MAX(formats.count, 1u)];
        const char **formatStrings = (const char **)formatStorage.mutableBytes;
        for (NSUInteger i = 0; i < formats.count; i++) formatStrings[i] = formats[i].lowercaseString.UTF8String;
        NSDictionary *info = SZFHelperBundleInfo(host.friendsHelperPath);
        NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class]
                                ? info[@"CFBundleShortVersionString"] : @"0";
        NSString *build = [info[@"CFBundleVersion"] isKindOfClass:NSString.class] ? info[@"CFBundleVersion"] : @"0";
        NSString *locale = [[NSLocale.currentLocale.localeIdentifier componentsSeparatedByString:@"@"].firstObject
            stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
        szfriends_client_config config = {0};
        config.state_dir = NULL;
        config.helper_path = host.friendsHelperPath.length ? host.friendsHelperPath.fileSystemRepresentation : NULL;
        config.helper_version = version.UTF8String;
        config.helper_build_number = strtoull(build.UTF8String, NULL, 10);
        config.helper_protocol_major = SZFRIENDS_PROTOCOL_MAJOR;
        config.helper_protocol_minor = SZFRIENDS_PROTOCOL_MINOR;
        config.app_id = host.friendsAppID.UTF8String;
        config.app_name = host.friendsAppName.UTF8String;
        config.app_version = host.friendsAppVersion.UTF8String;
        config.toolkit = "appkit";
        config.reveal_in = host.friendsRevealInName.UTF8String;
        config.locale = locale.UTF8String;
        config.capabilities = capabilityStrings;
        config.capability_count = capabilityCount;
        config.open_formats = formatStrings;
        config.open_format_count = formats.count;
        config.on_frame = SZFOnFrame;
        config.on_state = SZFOnState;
        config.context = (__bridge void *)_box;
        _client = szfriends_client_new(&config); // copies every string it keeps
    }
    if (!_client) return;
    szfriends_client_start(_client);
    [self rearm:YES];
}

- (void)stopDisablingFriends:(BOOL)disabling {
    if (!_client) return;
    szfriends_client_stop(_client, disabling);
    [self teardown];
    // Said at once, not on the next turn: anything the views send from here on must fail as not_ready.
    [self.delegate transportDidChangeState:SZFriendsLinkStateIdle statusText:nil];
}

- (void)teardown {
    if (_readSource) dispatch_source_cancel(_readSource);
    _readSource = nil;
    _watchedFD = -1;
    [_tickTimer invalidate];
    _tickTimer = nil;
    if (_client) szfriends_client_free(_client);
    _client = NULL;
}

- (NSString *)sendIntent:(NSString *)type fields:(NSDictionary *)fields errorCode:(NSString **)errorCode {
    if (!_client) {
        *errorCode = @"not_ready";
        return nil;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:fields ?: @{} options:0 error:nil];
    NSString *text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
    if (!text) {
        *errorCode = @"internal";
        return nil;
    }
    char frameID[32] = {0};
    szfriends_status status = szfriends_client_send(_client, type.UTF8String, text.UTF8String, frameID, sizeof frameID);
    [self rearm:NO];
    if (status == SZFRIENDS_OK) return @(frameID);
    *errorCode = status == SZFRIENDS_ERR_NOT_READY ? @"not_ready"
                 : status == SZFRIENDS_ERR_FRAME_TOO_LARGE ? @"frame_too_large" : @"internal";
    return nil;
}

// Re-points the read source at the current descriptor and schedules the next tick. `force` recreates the source
// even when the number is unchanged: a closed and reopened socket can reuse the number, and a kqueue watch on
// the old one never fires again.
- (void)rearm:(BOOL)force {
    if (!_client) return;
    int fd = szfriends_client_fd(_client);
    if (force || fd != _watchedFD) {
        if (_readSource) dispatch_source_cancel(_readSource);
        _readSource = nil;
        _watchedFD = fd;
        if (fd >= 0) {
            dispatch_queue_t main = dispatch_get_main_queue();
            _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, main);
            __weak SZFriendsClientTransport *weakSelf = self;
            dispatch_source_set_event_handler(_readSource, ^{ [weakSelf readable]; });
            dispatch_resume(_readSource);
        }
    }
    [_tickTimer invalidate];
    _tickTimer = nil;
    int64_t wait = szfriends_client_next_tick_ms(_client, SZFNowMs());
    if (wait < 0) return;
    __weak SZFriendsClientTransport *weakSelf = self;
    _tickTimer = [NSTimer timerWithTimeInterval:MAX(wait, 1) / 1000.0 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf tick];
    }];
    [NSRunLoop.mainRunLoop addTimer:_tickTimer forMode:NSRunLoopCommonModes];
}

- (void)readable {
    if (!_client) return;
    int before = szfriends_client_fd(_client);
    szfriends_client_on_readable(_client);
    if (_client) [self rearm:szfriends_client_fd(_client) != before];
}

- (void)tick {
    if (!_client) return;
    int before = szfriends_client_fd(_client);
    szfriends_client_tick(_client, SZFNowMs());
    if (_client) [self rearm:szfriends_client_fd(_client) != before];
}

@end
