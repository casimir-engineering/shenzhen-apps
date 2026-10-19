// friends-discovery-check, Network.framework part: two real adapters on the loopback interface only find each
// other over Bonjour, open TCP streams through both entries, rotate names and drop the public entry.
//
// Loopback only (SZFriendsMakeLoopbackNetworkAdapter): nothing reaches the network, so no Local Network prompt.
// A random service type per run keeps these instances away from any real helper on this Mac. If mDNS cannot
// answer on loopback within 8 s, the test says so and skips rather than hanging or failing on the machine.

#import "SZFriendsDiscoveryTestSupport.h"

static const NSTimeInterval kStepTimeout = 8;

@interface SZFTestNetworkDelegate : NSObject <SZFriendsDiscoveryAdapterDelegate>
@property(nonatomic) NSMutableDictionary<NSString *, SZFriendsSighting *> *sighted; // endpoint -> latest
@property(nonatomic) NSMutableArray<NSString *> *lost;
@property(nonatomic) NSMutableArray<id<SZFriendsByteStream>> *accepted;
@property(nonatomic) NSMutableArray<NSNumber *> *acceptedPublic;
@property(nonatomic) SZFriendsAdapterState state;
@end

@implementation SZFTestNetworkDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _sighted = [NSMutableDictionary dictionary];
        _lost = [NSMutableArray array];
        _accepted = [NSMutableArray array];
        _acceptedPublic = [NSMutableArray array];
    }
    return self;
}
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didChangeState:(SZFriendsAdapterState)state {
    (void)adapter;
    self.state = state;
}
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didSight:(SZFriendsSighting *)sighting {
    (void)adapter;
    self.sighted[sighting.endpointID] = sighting;
}
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didLoseEndpoint:(NSString *)endpointID {
    (void)adapter;
    [self.lost addObject:endpointID];
    [self.sighted removeObjectForKey:endpointID];
}
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter
    didAcceptStream:(id<SZFriendsByteStream>)stream
              route:(SZFriendsRouteMethod)route {
    [self adapter:adapter didAcceptStream:stream route:route publicEntry:NO];
}
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter
    didAcceptStream:(id<SZFriendsByteStream>)stream
              route:(SZFriendsRouteMethod)route
        publicEntry:(BOOL)publicEntry {
    (void)adapter;
    if (route != SZFriendsRouteMethodLAN) return; // lo0 is classified as the LAN
    [self.accepted addObject:stream];
    [self.acceptedPublic addObject:@(publicEntry)];
}
- (SZFriendsSighting *)sightingWithTag:(NSData *)tag {
    for (SZFriendsSighting *sighting in self.sighted.allValues) {
        if ([sighting.presenceTag isEqual:tag]) return sighting;
    }
    return nil;
}
- (SZFriendsSighting *)publicSighting {
    for (SZFriendsSighting *sighting in self.sighted.allValues) {
        if (sighting.isPublic) return sighting;
    }
    return nil;
}

@end

static int Skip(NSString *why) {
    printf("SZFriendsNetworkAdapterTests skipped: %s\n", why.UTF8String);
    return 0;
}

int main(void) {
    @autoreleasepool {
        dispatch_queue_t queue = dispatch_queue_create("test.network", DISPATCH_QUEUE_SERIAL);
        NSString *serviceType = [NSString stringWithFormat:@"_szft%08x._tcp", arc4random()];
        id<SZFriendsDiscoveryAdapter> a = SZFriendsMakeLoopbackNetworkAdapter(queue, serviceType);
        // B rotates its hidden listener at each new tag: a short overlap so the test sees the old one go.
        SZFriendsNetworkAdapterOptions *optionsB = [SZFriendsNetworkAdapterOptions new];
        optionsB.loopbackOnly = YES;
        optionsB.serviceType = serviceType;
        optionsB.listenerOverlap = 0.5;
        id<SZFriendsDiscoveryAdapter> b = SZFriendsMakeNetworkAdapterWithOptions(queue, optionsB);
        SZFTestNetworkDelegate *atA = [SZFTestNetworkDelegate new], *atB = [SZFTestNetworkDelegate new];
        NSData *tagA = SZFTestData(@"a1a1a1a1a1a1a1a1"), *tagB = SZFTestData(@"b1b1b1b1b1b1b1b1");
        NSData *tagB2 = SZFTestData(@"b2b2b2b2b2b2b2b2"), *callbackA = SZFTestData(@"c1c1c1c1c1c1c1c1");
        dispatch_sync(queue, ^{
            a.delegate = atA;
            b.delegate = atB;
            [a advertisePresenceTag:tagA callbackTags:@[ callbackA ] publicEntry:NO];
            [b advertisePresenceTag:tagB callbackTags:@[] publicEntry:YES];
            [a start];
            [b start];
        });

        BOOL found = SZFTestWait(queue, kStepTimeout, ^BOOL {
            return [atA sightingWithTag:tagB] && atA.publicSighting && [atB sightingWithTag:tagA];
        });
        if (!found) {
            __block SZFriendsAdapterState stateA, stateB;
            dispatch_sync(queue, ^{
                stateA = a.state;
                stateB = b.state;
                [a stop];
                [b stop];
            });
            return Skip([NSString stringWithFormat:@"mDNS did not answer on loopback within %.0f s (states %ld/%ld)",
                                                   kStepTimeout, (long)stateA, (long)stateB]);
        }
        __block SZFriendsSighting *hiddenB, *publicB, *seenA;
        dispatch_sync(queue, ^{
            hiddenB = [atA sightingWithTag:tagB];
            publicB = atA.publicSighting;
            seenA = [atB sightingWithTag:tagA];
            CHECK(a.state == SZFriendsAdapterStateWorking && b.state == SZFriendsAdapterStateWorking);
            CHECK(hiddenB.method == SZFriendsDiscoveryMethodNetwork && hiddenB.route == SZFriendsRouteMethodLAN);
            CHECK(!hiddenB.isPublic && publicB.presenceTag == nil && ![publicB.endpointID isEqual:hiddenB.endpointID]);
            CHECK([seenA.callbackTags containsObject:callbackA] && seenA.callbackTags.count == SZFriendsCallbackTagsMax,
                  "TXT c carries the callback tags in exactly 4 slots");
            CHECK(![atA sightingWithTag:tagA] && ![atB sightingWithTag:tagB], "an adapter never sights itself");
            CHECK(![hiddenB.endpointID containsString:@"b1b1"], "instance names are not the tag");
        });

        // Hidden entry: a stream both ways, then a clean close.
        __block id<SZFriendsByteStream> outgoing = nil;
        __block NSError *openError = nil;
        dispatch_sync(queue, ^{
            [a openStreamToEndpoint:hiddenB.endpointID
                         completion:^(id<SZFriendsByteStream> stream, NSError *error) {
                             outgoing = stream;
                             openError = error;
                         }];
        });
        CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
            return (outgoing || openError) && atB.accepted.count == 1;
        }), "open: %@", openError);
        if (outgoing && atB.accepted.count == 1) {
            id<SZFriendsByteStream> incoming = atB.accepted[0];
            NSMutableData *atIncoming = [NSMutableData data], *atOutgoing = [NSMutableData data];
            __block BOOL incomingClosed = NO;
            __block NSError *closeError = [NSError errorWithDomain:@"unset" code:0 userInfo:nil];
            dispatch_sync(queue, ^{
                CHECK([atB.acceptedPublic[0] isEqual:@NO], "the hidden listener");
                incoming.onData = ^(NSData *data) {
                    [atIncoming appendData:data];
                };
                incoming.onClose = ^(NSError *error) {
                    incomingClosed = YES;
                    closeError = error;
                };
                outgoing.onData = ^(NSData *data) {
                    [atOutgoing appendData:data];
                };
                [incoming startWithQueue:queue];
                [outgoing startWithQueue:queue];
                [outgoing writeData:[@"ping" dataUsingEncoding:NSUTF8StringEncoding] completion:nil];
                [incoming writeData:[@"pong!" dataUsingEncoding:NSUTF8StringEncoding] completion:nil];
            });
            CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
                return atIncoming.length == 4 && atOutgoing.length == 5;
            }));
            dispatch_sync(queue, ^{
                [outgoing writeData:[@"bye" dataUsingEncoding:NSUTF8StringEncoding] completion:nil];
                [outgoing close];
            });
            CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
                return incomingClosed;
            }));
            dispatch_sync(queue, ^{
                CHECK(closeError == nil && [atIncoming isEqual:[@"pingbye" dataUsingEncoding:NSUTF8StringEncoding]],
                      "bytes written before close arrive, then a clean end");
                [incoming close];
            });
        }

        // Public entry: its own listener, so the stream says where it came from.
        __block id<SZFriendsByteStream> toPublic = nil;
        dispatch_sync(queue, ^{
            [a openStreamToEndpoint:publicB.endpointID
                         completion:^(id<SZFriendsByteStream> stream, NSError *error) {
                             (void)error;
                             toPublic = stream;
                         }];
        });
        CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
            return toPublic && atB.acceptedPublic.count == 2;
        }));
        dispatch_sync(queue, ^{
            CHECK(atB.acceptedPublic.count == 2 && [atB.acceptedPublic[1] isEqual:@YES], "the public listener");
            [toPublic close];
            if (atB.accepted.count == 2) [atB.accepted[1] close];
        });

        // Places on the real accept path (review finding "admission lockout"): B's hidden listener holds 4
        // connections whose sessions never authenticate (a cap of 4 here, since loopback may arrive over IPv4 or IPv6
        // and so split the per-address count; the default caps are SZFriendsAdmissionTests' and the Bluetooth
        // tests'). A fifth is not dropped: the oldest of the four is closed to make room, and its session is told.
        SZFriendsAdmissionLimits *four = [SZFriendsAdmissionLimits defaultLimits];
        four.pendingPerListener = 4;
        four.pendingPerAddress = 0;
        four.firstMessageTimeout = 0; // checked on its own below
        dispatch_sync(queue, ^{
            [b setAdmissionLimits:four];
        });
        NSUInteger acceptedBefore = atB.accepted.count;
        NSMutableArray<id<SZFriendsByteStream>> *silent = [NSMutableArray array];
        void (^openSilent)(void) = ^{
            [a openStreamToEndpoint:hiddenB.endpointID
                         completion:^(id<SZFriendsByteStream> stream, NSError *error) {
                             (void)error;
                             if (stream) [silent addObject:stream];
                         }];
        };
        for (int i = 0; i < 4; i++) dispatch_sync(queue, openSilent);
        CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
            return atB.accepted.count == acceptedBefore + 4;
        }), "four admitted");
        NSMutableArray<NSError *> *closes = [NSMutableArray array];
        dispatch_sync(queue, ^{
            for (NSUInteger i = acceptedBefore; i < atB.accepted.count; i++) {
                atB.accepted[i].onClose = ^(NSError *error) {
                    [closes addObject:error ?: [NSError errorWithDomain:@"clean" code:0 userInfo:nil]];
                };
                [atB.accepted[i] startWithQueue:queue];
            }
            openSilent();
        });
        CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
            return atB.accepted.count == acceptedBefore + 5 && closes.count == 1;
        }), "the fifth is admitted and one of the four makes way");
        usleep(300000);
        dispatch_sync(queue, ^{
            CHECK(closes.count == 1 && closes[0].code == SZFriendsDiscoveryErrorEvicted, "exactly one, told why: %@",
                  closes);
            for (id<SZFriendsByteStream> stream in silent) [stream close];
            for (NSUInteger i = acceptedBefore; i < atB.accepted.count; i++) [atB.accepted[i] close];
        });

        // A connection that sends nothing loses its place after the first-message deadline.
        SZFriendsAdmissionLimits *quick = [SZFriendsAdmissionLimits defaultLimits];
        quick.firstMessageTimeout = 0.3;
        __block NSError *silentClose = nil;
        NSUInteger beforeQuiet = atB.accepted.count;
        dispatch_sync(queue, ^{
            [b setAdmissionLimits:quick];
            openSilent();
        });
        CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
            return atB.accepted.count == beforeQuiet + 1;
        }));
        dispatch_sync(queue, ^{
            if (atB.accepted.count != beforeQuiet + 1) return;
            atB.accepted[beforeQuiet].onClose = ^(NSError *error) {
                silentClose = error;
            };
            [atB.accepted[beforeQuiet] startWithQueue:queue];
        });
        CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
            return silentClose != nil;
        }), "closed for silence");
        dispatch_sync(queue, ^{
            CHECK(silentClose.code == SZFriendsDiscoveryErrorEvicted);
            for (id<SZFriendsByteStream> stream in silent) [stream close];
            [b setAdmissionLimits:[SZFriendsAdmissionLimits defaultLimits]];
        });

        // A new window: a new tag under a new name and on a new port, the old name lost; the old port keeps
        // accepting for its overlap, then goes. Then the deadline drops the public entry.
        __block NSArray<NSNumber *> *portsBefore = nil;
        dispatch_sync(queue, ^{
            portsBefore = SZFriendsNetworkAdapterHiddenPorts(b);
            [b advertisePresenceTag:tagB2 callbackTags:@[] publicEntry:YES];
        });
        CHECK(portsBefore.count == 1 && portsBefore[0].unsignedIntValue != 0, "one hidden listener: %@", portsBefore);
        CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
            NSArray<NSNumber *> *ports = SZFriendsNetworkAdapterHiddenPorts(b);
            return ports.count == 2 && ports[0].unsignedIntValue != 0;
        }), "a new listener while the old one overlaps");
        dispatch_sync(queue, ^{
            NSArray<NSNumber *> *ports = SZFriendsNetworkAdapterHiddenPorts(b);
            CHECK(ports.count == 2 && ![ports[0] isEqual:portsBefore[0]] && [ports[1] isEqual:portsBefore[0]],
                  "the new window listens on a new port: %@ then %@", portsBefore, ports);
        });
        CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
            return SZFriendsNetworkAdapterHiddenPorts(b).count == 1;
        }), "the old listener goes after its overlap");
        CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
            return [atA sightingWithTag:tagB2] && ![atA sightingWithTag:tagB];
        }), "rotation");
        dispatch_sync(queue, ^{
            SZFriendsSighting *rotated = [atA sightingWithTag:tagB2];
            CHECK(rotated && ![rotated.endpointID isEqual:hiddenB.endpointID], "a new tag never keeps the old name");
            CHECK([atA.lost containsObject:hiddenB.endpointID]);
            [b advertisePresenceTag:tagB2 callbackTags:@[] publicEntry:NO];
        });
        CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
            return atA.publicSighting == nil && [atA.lost containsObject:publicB.endpointID];
        }), "public entry withdrawn");

        // Unknown endpoints fail; a stopped adapter disappears from the other's browser.
        __block NSError *unknown = nil;
        dispatch_sync(queue, ^{
            [a openStreamToEndpoint:@"bonjour:nobody"
                         completion:^(id<SZFriendsByteStream> stream, NSError *error) {
                             (void)stream;
                             unknown = error;
                         }];
            [b stop];
        });
        CHECK(SZFTestWait(queue, kStepTimeout, ^BOOL {
            return unknown != nil && [atA sightingWithTag:tagB2] == nil;
        }));
        dispatch_sync(queue, ^{
            CHECK(unknown.code == SZFriendsDiscoveryErrorUnknownEndpoint && b.state == SZFriendsAdapterStateNotAsked);
            [a stop];
        });

        if (SZFTestFailures) {
            fprintf(stderr, "SZFriendsNetworkAdapterTests: %d failure(s)\n", SZFTestFailures);
            return 1;
        }
        printf("SZFriendsNetworkAdapterTests passed\n");
        return 0;
    }
}
