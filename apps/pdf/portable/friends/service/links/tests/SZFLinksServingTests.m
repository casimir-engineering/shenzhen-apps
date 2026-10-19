// The sender's service toward the host and over time: links registered whenever the host takes online messages,
// a revoke the host could not hear sent at the next connection, and a page that never asks for the file let go.

#import "SZFLinksTestSupport.h"

#import "service/host/SZFriendsHostRendezvousInternal.h"
#import "service/identity/SZFriendsIdentity.h"

// The check-in client's online side with the host replaced by a recording: what the service would send.
@interface SZFLFakeHostOnline : SZFriendsHostOnline
@property(nonatomic) BOOL up;
@property(nonatomic, readonly) NSMutableArray<NSDictionary *> *sent;
@end

@implementation SZFLFakeHostOnline

- (instancetype)initFake {
    SZFriendsIdentity *identity = [SZFriendsIdentity identityWithSigningSeed:SZFLRandom(32)
                                                            staticPrivateKey:SZFLRandom(32)];
    SZFriendsCheckInClient *none = nil;
    if ((self = [super initWithClient:none identity:identity queue:dispatch_get_main_queue()])) {
        _sent = [NSMutableArray array];
    }
    return self;
}

- (BOOL)available {
    return self.up;
}

- (NSTimeInterval)hostNow {
    return [NSDate date].timeIntervalSince1970;
}

- (BOOL)sendType:(NSString *)type fields:(NSDictionary<NSString *, id> *)fields {
    if (!self.up) return NO;
    NSMutableDictionary *message = [fields mutableCopy];
    message[@"type"] = type;
    [_sent addObject:message];
    return YES;
}

@end

// An opener that takes the channel and never asks for the file, as a page left open without pressing Download.
@interface SZFLIdleOpener : NSObject <SZFriendsLinkSetupDelegate>
@property(nonatomic, strong) id<SZFriendsByteStream> stream;
@end

@implementation SZFLIdleOpener
- (void)linkSetup:(SZFriendsLinkSetup *)setup didOpenStream:(id<SZFriendsByteStream>)stream attempt:(uint8_t)attempt {
    (void)setup, (void)attempt;
    self.stream = stream;
    stream.onData = ^(NSData *data) { (void)data; };
    [stream startWithQueue:dispatch_get_main_queue()];
}
- (void)linkSetup:(SZFriendsLinkSetup *)setup didFail:(SZFriendsLinkOutcome)outcome {
    (void)setup, (void)outcome;
}
@end

static SZFriendsLinkService *Service(NSString *label, SZFriendsStore **storeOut, NSTimeInterval startTimeout) {
    NSString *directory = SZFLTemporaryDirectory(label);
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:directory error:NULL];
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store stateDirectory:directory];
    SZFriendsIdentity *identity = [SZFriendsIdentity identityWithSigningSeed:SZFLRandom(32)
                                                            staticPrivateKey:SZFLRandom(32)];
    SZFriendsLinkService *service = [[SZFriendsLinkService alloc] initWithStore:store transfers:transfers
                                                                       identity:identity stateDirectory:directory
                                                                          queue:dispatch_get_main_queue()];
    service.linkOrigin = ^NSString * { return @"https://friends.example"; };
    service.environment = ^SZFriendsLinkEnvironment * {
        SZFriendsLinkEnvironment *environment = SZFLEnvironment(SZFLLoopbackTransport());
        environment.startTimeout = startTimeout;
        return environment;
    };
    if (storeOut) *storeOut = store;
    return service;
}

static SZFriendsDownloadLinkRecord *Make(SZFriendsLinkService *service, NSString *directory) {
    NSString *path = [directory stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [SZFLRandom(2000) writeToFile:path atomically:NO];
    __block SZFriendsDownloadLinkRecord *made = nil;
    __block BOOL done = NO;
    [service makeDownloadLinkForPath:path displayName:nil revisionSHA256:nil revisionSize:nil expiresDays:1
                          completion:^(SZFriendsDownloadLinkRecord *link, NSString *url, NSError *error) {
                              (void)url, (void)error;
                              made = link;
                              done = YES;
                          }];
    SZFLWaitUntil(10, ^BOOL { return done; });
    return made;
}

static NSArray<NSString *> *SentOfType(SZFLFakeHostOnline *host, NSString *type) {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *message in host.sent) {
        if ([message[@"type"] isEqual:type]) [ids addObject:message[@"link_id"]];
    }
    return ids;
}

static void TestTheHostHearsOfLinks(void) {
    SZFriendsStore *store = nil;
    SZFriendsLinkService *service = Service(@"host", &store, 900);
    SZFLFakeHostOnline *host = [[SZFLFakeHostOnline alloc] initFake];
    service.hostOnline = host;
    NSString *directory = SZFLTemporaryDirectory(@"host-files");
    SZFriendsDownloadLinkRecord *kept = Make(service, directory), *revoked = Make(service, directory);
    SZFL_CHECK(kept != nil && revoked != nil && host.sent.count == 0, @"nothing while the host is away");
    SZFL_CHECK([service revokeLinkID:revoked.linkID error:NULL], @"revoked while away");
    host.up = YES;
    [service hostBecameAvailable];
    NSString *keptID = SZFriendsLinkBase64URLEncode(kept.linkID);
    SZFL_CHECK([SentOfType(host, @"link_register") isEqual:@[ keptID ]], @"registers the live link: %@", host.sent);
    SZFL_CHECK([SentOfType(host, @"link_unregister") isEqual:@[ SZFriendsLinkBase64URLEncode(revoked.linkID) ]],
               @"and tells the host of the revoke it missed");
    NSDictionary *registration = host.sent.lastObject;
    long long expires = [registration[@"expires"] longLongValue];
    SZFL_CHECK(llabs(expires - (long long)kept.expiresAt.timeIntervalSince1970) <= 1, @"its expiry: %@", registration);
    [host.sent removeAllObjects];
    SZFriendsDownloadLinkRecord *fresh = Make(service, directory);
    SZFL_CHECK([SentOfType(host, @"link_register") isEqual:@[ SZFriendsLinkBase64URLEncode(fresh.linkID) ]],
               @"a link made while the host listens is registered at once");
    [service revokeLinkID:fresh.linkID error:NULL];
    SZFL_CHECK([SentOfType(host, @"link_unregister") isEqual:@[ SZFriendsLinkBase64URLEncode(fresh.linkID) ]],
               @"and unregistered at once");
}

static void TestAPageThatNeverAsksIsLetGo(void) {
    SZFriendsStore *store = nil;
    SZFriendsLinkService *service = Service(@"idle", &store, 1);
    SZFriendsDownloadLinkRecord *link = Make(service, SZFLTemporaryDirectory(@"idle-files"));
    SZFriendsLinkKeys *keys = [[SZFriendsLinkKeys alloc] initWithLinkID:link.linkID secret:link.secret];
    SZFriendsLinkEnvironment *environment = SZFLEnvironment(SZFLLoopbackTransport());
    SZFriendsLinkSetup *opener = [[SZFriendsLinkSetup alloc] initOpenerWithKeys:keys environment:environment];
    SZFLIdleOpener *page = [SZFLIdleOpener new];
    opener.delegate = page;
    [opener startWithOpen:^(NSData *hello, void (^done)(id<SZFriendsOnlineSignalChannel>, BOOL)) {
        NSArray<SZFLChannel *> *pair = [SZFLChannel pair];
        [service receiveOpenOfLinkID:link.linkID channel:pair[1] payload:hello];
        done(pair[0], YES);
    }];
    SZFL_CHECK(SZFLWaitUntil(10, ^BOOL { return page.stream != nil; }), @"the channel opens");
    SZFL_CHECK(service.servingCount == 1, @"served while the page decides");
    SZFL_CHECK(SZFLWaitUntil(5, ^BOOL { return service.servingCount == 0; }), @"let go after the wait");
    SZFL_CHECK([store downloadLinkWithID:link.linkID].downloads == 0, @"nothing counted");
    [opener close];
}

void SZFLRunServingTests(void) {
    TestTheHostHearsOfLinks();
    TestAPageThatNeverAsksIsLetGo();
}
