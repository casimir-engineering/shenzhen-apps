// The helper's glue for links (SZFriendsHelperLinks.h).

#import "service/helper/SZFriendsHelperLinks.h"

#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/host/SZFriendsHostInternal.h"
#import "service/host/SZFriendsHostRendezvous.h"
#import "service/online/driver/SZFriendsOnlineDriverPrivate.h"
#import "service/store/SZFriendsStoreLinks.h"

NSString *SZFriendsLinkOriginForList(SZFriendsHostList *list) {
    NSDictionary *payload = list ? [NSJSONSerialization JSONObjectWithData:[list payloadData] options:0 error:NULL]
                                 : nil;
    id named = [payload isKindOfClass:[NSDictionary class]] ? payload[@"links"] : nil;
    if ([named isKindOfClass:[NSString class]]) {
        NSURL *url = [NSURL URLWithString:named];
        BOOL origin = [url.scheme isEqualToString:@"https"] && url.host.length > 0 && url.path.length == 0 &&
                      url.query == nil && url.fragment == nil && url.user == nil;
        return origin ? named : nil;
    }
    for (SZFriendsHostEntry *entry in list.entries) {
        if ((entry.roles & SZFriendsHostRoleRendezvous) == 0) continue;
        NSURL *url = entry.urls.firstObject;
        NSString *scheme = [url.scheme isEqualToString:@"wss"] ? @"https" : [url.scheme isEqualToString:@"ws"] ? @"http"
                                                                                                               : nil;
        if (scheme == nil || url.host.length == 0) return nil;
        BOOL v6 = [url.host containsString:@":"];
        NSString *host = v6 ? [NSString stringWithFormat:@"[%@]", url.host] : url.host;
        return url.port ? [NSString stringWithFormat:@"%@://%@:%@", scheme, host, url.port]
                        : [NSString stringWithFormat:@"%@://%@", scheme, host];
    }
    return nil;
}

// Between the check-in client's online side and the online driver: opens via a link id go to the link service, and
// it hears when the host takes online messages; everything else reaches the driver unchanged.
@interface SZFriendsHelperLinkRouter : NSObject <SZFriendsHostOnlineDelegate>
@property(nonatomic, weak) id<SZFriendsHostOnlineDelegate> next;
@property(nonatomic, weak) SZFriendsHelperServices *services;
@property(nonatomic, weak) SZFriendsHostOnline *online;
@end

@implementation SZFriendsHelperLinkRouter

- (void)hostOnline:(SZFriendsHostOnline *)online didChangeAvailability:(BOOL)available {
    [self.next hostOnline:online didChangeAvailability:available];
    if (available) [[self.services linkService] hostBecameAvailable];
}

- (void)hostOnline:(SZFriendsHostOnline *)online
    didReceiveSignal:(SZFriendsHostSignal *)signal
             payload:(NSData *)payload {
    if (signal.via != SZFriendsHostSignalViaLink) {
        [self.next hostOnline:online didReceiveSignal:signal payload:payload];
        return;
    }
    SZFriendsLinkService *links = [self.services linkService];
    // A link this helper does not serve gets no answer at all: to the opener, exactly as if nobody were here.
    if (links == nil || signal.linkID == nil ||
        ![links receiveOpenOfLinkID:signal.linkID channel:SZFriendsOnlineChannelForSignal(signal) payload:payload]) {
        [signal close];
    }
}

@end

@implementation SZFriendsHelperServices (Links)

- (SZFriendsLinkService *)linkService {
    if (self.links != nil || self.store == nil || self.identity == nil || self.transfers == nil) return self.links;
    SZFriendsNearbyService *nearby = self.nearby;
    dispatch_queue_t queue = nearby.queue ?: dispatch_get_main_queue();
    SZFriendsLinkService *links = [[SZFriendsLinkService alloc] initWithStore:self.store
                                                                    transfers:self.transfers
                                                                     identity:self.identity
                                                               stateDirectory:self.paths.stateDirectory
                                                                        queue:queue];
    __weak SZFriendsHelperServices *weakSelf = self;
    links.linkOrigin = ^NSString * { return SZFriendsLinkOriginForList(weakSelf.hostListCache.currentList); };
    links.profileName = ^NSString * { return weakSelf.store.profileName; };
    links.onChange = ^{
        SZFriendsNearbyService *service = weakSelf.nearby;
        if (service.onChange) service.onChange();
    };
    links.environment = ^SZFriendsLinkEnvironment * {
        SZFriendsOnlineDriver *driver = weakSelf.nearby.onlineDriver;
        if (driver == nil || !driver.available) return nil;
        SZFriendsOnlineContext *context = driver.onlineContext;
        SZFriendsLinkEnvironment *environment = [[SZFriendsLinkEnvironment alloc] init];
        environment.transport = context.transport;
        environment.queue = context.queue;
        environment.stunURI = context.stunURI;
        __weak SZFriendsOnlineContext *weakContext = context;
        environment.directPathsBlocked = ^BOOL { return [weakContext directPathsBlocked]; };
        return environment;
    };
    links.hostOnline = ((SZFriendsHelperLinkRouter *)self.linkRouter).online;
    self.links = links;
    return links;
}

- (void)attachLinksToHostOnline:(SZFriendsHostOnline *)online {
    SZFriendsHelperLinkRouter *router = self.linkRouter;
    if (router == nil) {
        router = [[SZFriendsHelperLinkRouter alloc] init];
        router.services = self;
        self.linkRouter = router;
    }
    router.online = online;
    self.links.hostOnline = online;
    if (online.delegate == router) return;
    router.next = online.delegate;
    online.delegate = router;
}

@end

SZFriendsLinksFacts *SZFriendsHelperLinksFacts(SZFriendsHelperServices *services, NSDate *now) {
    SZFriendsLinkService *links = [services linkService];
    NSString *friendsID = services.store.friendsID;
    NSString *url = friendsID.length ? [links friendLinkURLWithFriendsID:friendsID name:services.store.profileName]
                                     : nil;
    if (url == nil) return nil;
    SZFriendsLinksFacts *facts = [[SZFriendsLinksFacts alloc] init];
    facts.friendURL = url;
    facts.now = now;
    NSMutableArray<SZFriendsDownloadLinkFacts *> *downloads = [NSMutableArray array];
    for (SZFriendsDownloadLinkRecord *link in [links liveLinks]) {
        SZFriendsDownloadLinkFacts *row = [[SZFriendsDownloadLinkFacts alloc] init];
        row.linkID = SZFriendsHostBase64URLEncode(link.linkID);
        row.fileName = link.fileName;
        row.downloads = link.downloads;
        row.expiresAt = link.expiresAt;
        [downloads addObject:row];
    }
    facts.downloads = downloads;
    return facts;
}
