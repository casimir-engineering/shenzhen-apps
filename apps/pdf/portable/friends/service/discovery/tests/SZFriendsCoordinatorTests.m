// The coordinator with scripted adapters: launch permissions, independence of methods, wake, stop and dialing.

#import "SZFriendsDiscoveryTestSupport.h"

#import "service/discovery/SZFriendsDiscoveryCoordinator.h"

@interface SZFTestCoordinatorDelegate : NSObject <SZFriendsDiscoveryCoordinatorDelegate>
@property(nonatomic) NSUInteger candidateChanges;
@property(nonatomic) NSMutableArray<NSString *> *states; // "method:state"
@property(nonatomic) NSMutableArray<NSNumber *> *acceptedPublic;
@end

@implementation SZFTestCoordinatorDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _states = [NSMutableArray array];
        _acceptedPublic = [NSMutableArray array];
    }
    return self;
}

- (void)discoveryCoordinatorDidChangeCandidates:(SZFriendsDiscoveryCoordinator *)coordinator {
    (void)coordinator;
    self.candidateChanges++;
}

- (void)discoveryCoordinator:(SZFriendsDiscoveryCoordinator *)coordinator
              didChangeState:(SZFriendsAdapterState)state
                    ofMethod:(SZFriendsDiscoveryMethod)method {
    (void)coordinator;
    [self.states addObject:[NSString stringWithFormat:@"%ld:%ld", (long)method, (long)state]];
}

- (void)discoveryCoordinator:(SZFriendsDiscoveryCoordinator *)coordinator
             didAcceptStream:(id<SZFriendsByteStream>)stream
                       route:(SZFriendsRouteMethod)route
                 publicEntry:(BOOL)publicEntry {
    (void)coordinator;
    (void)stream;
    (void)route;
    [self.acceptedPublic addObject:@(publicEntry)];
}

@end

static NSData *MeiTag(void) { return SZFTestData(@"0101010101010101"); }

static NSDate *gNow;

static SZFriendsDiscoveryCoordinator *MakeCoordinator(SZFTestAdapter *network, SZFTestAdapter *bluetooth,
                                                       dispatch_queue_t queue, SZFTestCoordinatorDelegate *delegate) {
    SZFriendsDiscoveryMerger *merger = [[SZFriendsDiscoveryMerger alloc] initWithTagMatcher:^NSString *(NSData *tag) {
        return [tag isEqual:MeiTag()] ? @"mei" : nil;
    }];
    SZFriendsDiscoveryCoordinator *coordinator =
        [[SZFriendsDiscoveryCoordinator alloc] initWithAdapters:@[ network, bluetooth ]
                                                         merger:merger
                                                          queue:queue
                                                          clock:^NSDate * {
                                                              return gNow;
                                                          }];
    coordinator.delegate = delegate;
    return coordinator;
}

static void TestLaunch(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.discovery", DISPATCH_QUEUE_SERIAL);
    SZFTestAdapter *network = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork];
    SZFTestAdapter *bluetooth = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodBluetooth];
    network.permission = SZFriendsPermissionUnknown;
    bluetooth.permission = SZFriendsPermissionNotDetermined;
    SZFTestCoordinatorDelegate *delegate = [SZFTestCoordinatorDelegate new];
    SZFriendsDiscoveryCoordinator *coordinator = MakeCoordinator(network, bluetooth, queue, delegate);
    // Someone who never opened Friends: nothing starts, nothing prompts.
    [coordinator startAtLaunchWithNearbyPermissionsRequested:NO];
    CHECK(network.startCount == 0 && bluetooth.startCount == 0);
    CHECK([coordinator stateOfMethod:SZFriendsDiscoveryMethodNetwork] == SZFriendsAdapterStateNotAsked);
    // The first open asks; the advertisement set before reaches each adapter before it starts.
    [coordinator advertisePresenceTag:MeiTag() callbackTags:@[] publicEntry:NO];
    [coordinator activate];
    CHECK(network.startCount == 1 && bluetooth.startCount == 1);
    CHECK(network.advertisedBeforeStart && [bluetooth.advertisedTag isEqual:MeiTag()]);
    [coordinator activate];
    CHECK(network.startCount == 1, "activate twice starts once");

    // Later launches: asked before, Bluetooth allowed.
    SZFTestAdapter *network2 = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork];
    SZFTestAdapter *bluetooth2 = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodBluetooth];
    bluetooth2.permission = SZFriendsPermissionAllowed;
    SZFriendsDiscoveryCoordinator *second = MakeCoordinator(network2, bluetooth2, queue, delegate);
    [second startAtLaunchWithNearbyPermissionsRequested:YES];
    CHECK(network2.startCount == 1 && bluetooth2.startCount == 1);

    // Bluetooth denied: reported Denied, never started; the network adapter starts regardless.
    SZFTestAdapter *network3 = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork];
    SZFTestAdapter *bluetooth3 = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodBluetooth];
    bluetooth3.permission = SZFriendsPermissionDenied;
    SZFTestCoordinatorDelegate *delegate3 = [SZFTestCoordinatorDelegate new];
    SZFriendsDiscoveryCoordinator *third = MakeCoordinator(network3, bluetooth3, queue, delegate3);
    [third startAtLaunchWithNearbyPermissionsRequested:YES];
    CHECK(network3.startCount == 1 && bluetooth3.startCount == 0);
    CHECK([third stateOfMethod:SZFriendsDiscoveryMethodBluetooth] == SZFriendsAdapterStateDenied);
    CHECK([delegate3.states containsObject:@"1:3"]);
    CHECK([third stateOfMethod:SZFriendsDiscoveryMethodNetwork] == SZFriendsAdapterStateWorking);
}

// "A denied method leaves the others' time to first result unchanged" (ADR 0004 § Verification): the friend seen
// over Wi-Fi is a candidate in the same call, however the other method is doing.
static void TestIndependence(void) {
    SZFriendsAdapterState others[] = {SZFriendsAdapterStateWorking, SZFriendsAdapterStateDenied,
                                      SZFriendsAdapterStateRadioOff, SZFriendsAdapterStateStarting,
                                      SZFriendsAdapterStateUnavailable};
    for (size_t i = 0; i < sizeof others / sizeof others[0]; i++) {
        dispatch_queue_t queue = dispatch_queue_create("test.discovery", DISPATCH_QUEUE_SERIAL);
        SZFTestAdapter *network = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork];
        SZFTestAdapter *bluetooth = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodBluetooth];
        bluetooth.stateOnStart = others[i];
        SZFTestCoordinatorDelegate *delegate = [SZFTestCoordinatorDelegate new];
        SZFriendsDiscoveryCoordinator *coordinator = MakeCoordinator(network, bluetooth, queue, delegate);
        gNow = SZFTestDate(1000);
        [coordinator activate];
        [network sight:SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"lan", MeiTag(), @[],
                                       NO, gNow)];
        CHECK(coordinator.merger.identifiedCandidates.count == 1 && delegate.candidateChanges == 1,
              "Bluetooth state %ld delayed Wi-Fi", (long)others[i]);
    }

    // A method that stops working: its sightings linger then expire; the other method's are untouched.
    dispatch_queue_t queue = dispatch_queue_create("test.discovery", DISPATCH_QUEUE_SERIAL);
    SZFTestAdapter *network = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork];
    SZFTestAdapter *bluetooth = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodBluetooth];
    SZFTestCoordinatorDelegate *delegate = [SZFTestCoordinatorDelegate new];
    SZFriendsDiscoveryCoordinator *coordinator = MakeCoordinator(network, bluetooth, queue, delegate);
    gNow = SZFTestDate(1000);
    [coordinator activate];
    [network sight:SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"lan", MeiTag(), @[], NO,
                                   gNow)];
    [bluetooth sight:SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt", MeiTag(),
                                     @[], NO, gNow)];
    [network reportState:SZFriendsAdapterStateDenied];
    CHECK([delegate.states containsObject:@"0:3"]);
    CHECK(coordinator.merger.candidates.firstObject.sightings.count == 2, "lingers through the grace");
    gNow = SZFTestDate(1000 + SZFriendsBonjourRemovalGrace);
    [coordinator expireSightings];
    SZFriendsCandidate *mei = coordinator.merger.candidates.firstObject;
    CHECK(mei.sightings.count == 1 && mei.sightings[0].method == SZFriendsDiscoveryMethodBluetooth);
    // Sightings from a stopped adapter are ignored.
    [coordinator stop];
    [network sight:SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"late", MeiTag(), @[], NO,
                                   gNow)];
    CHECK(coordinator.merger.candidates.count == 0, "stop forgets, and a stopped adapter's reports are dropped");
    CHECK(network.stopCount == 1 && bluetooth.stopCount == 1);
    CHECK([coordinator stateOfMethod:SZFriendsDiscoveryMethodBluetooth] == SZFriendsAdapterStateNotAsked);
    NSUInteger notAsked = 0;
    for (NSString *state in delegate.states) notAsked += [state isEqual:@"1:0"];
    CHECK(notAsked == 1, "stopping reports Not asked once per method: %@", delegate.states);
}

static void TestWakeRefreshAndAccept(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.discovery", DISPATCH_QUEUE_SERIAL);
    SZFTestAdapter *network = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork];
    SZFTestAdapter *bluetooth = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodBluetooth];
    SZFTestCoordinatorDelegate *delegate = [SZFTestCoordinatorDelegate new];
    SZFriendsDiscoveryCoordinator *coordinator = MakeCoordinator(network, bluetooth, queue, delegate);
    gNow = SZFTestDate(2000);
    [coordinator activate];
    // Bluetooth sees Mei with no Wi-Fi sighting: one fresh browse, not one per sighting.
    [bluetooth sight:SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt", MeiTag(),
                                     @[], NO, gNow)];
    gNow = SZFTestDate(2005);
    [bluetooth sight:SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt", MeiTag(),
                                     @[], NO, gNow)];
    CHECK(network.refreshCount == 1);
    [network sight:SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"lan", MeiTag(), @[], NO,
                                   gNow)];
    gNow = SZFTestDate(2030);
    [bluetooth sight:SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt", MeiTag(),
                                     @[], NO, gNow)];
    CHECK(network.refreshCount == 1, "no browse while Wi-Fi already sees her");

    // Wake: both adapters restart; what is still there is sighted again within the grace and nothing flips.
    NSUInteger changes = delegate.candidateChanges;
    NSUInteger statesBefore = delegate.states.count;
    [coordinator restartAfterWake];
    CHECK(network.startCount == 2 && bluetooth.startCount == 2 && network.stopCount == 1);
    gNow = SZFTestDate(2031);
    [network sight:SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"lan", MeiTag(), @[], NO,
                                   gNow)];
    [bluetooth sight:SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt", MeiTag(),
                                     @[], NO, gNow)];
    gNow = SZFTestDate(2100);
    [coordinator expireSightings];
    CHECK(delegate.candidateChanges == changes && coordinator.merger.candidates.firstObject.sightings.count == 2);
    for (NSUInteger i = statesBefore; i < delegate.states.count; i++) {
        CHECK(![delegate.states[i] hasSuffix:@":0"], "a wake restart does not report Not asked");
    }

    SZFTestStream *incoming = [SZFTestStream new];
    [network acceptStream:incoming publicEntry:YES];
    [bluetooth acceptStream:incoming publicEntry:NO];
    CHECK([delegate.acceptedPublic isEqual:(@[ @YES, @NO ])]);
    [coordinator advertisePresenceTag:nil callbackTags:@[ MeiTag() ] publicEntry:YES];
    CHECK(network.advertisedPublic && bluetooth.advertisedPublic &&
          [bluetooth.advertisedCallbackTags containsObject:MeiTag()]);
    // Exactly 4 slots, the same on both radios, and stable while the window lasts, so re-advertising never shows
    // which slots are padding (review finding "callback tags": the count revealed pending requests).
    NSArray<NSData *> *slots = bluetooth.advertisedCallbackTags;
    CHECK(slots.count == SZFriendsCallbackTagsMax && [network.advertisedCallbackTags isEqual:slots]);
    [coordinator advertisePresenceTag:nil callbackTags:@[ MeiTag() ] publicEntry:NO];
    CHECK([bluetooth.advertisedCallbackTags isEqual:slots], "padding kept within the window");
    [coordinator advertisePresenceTag:nil callbackTags:@[] publicEntry:NO];
    CHECK(bluetooth.advertisedCallbackTags.count == SZFriendsCallbackTagsMax &&
              ![bluetooth.advertisedCallbackTags containsObject:MeiTag()],
          "an answered request's slot becomes padding");
    [coordinator advertisePresenceTag:SZFTestData(@"0909090909090909") callbackTags:@[] publicEntry:NO];
    NSArray<NSData *> *next = bluetooth.advertisedCallbackTags;
    for (NSData *slot in next) CHECK(![slots containsObject:slot], "a new window draws new padding");

    // Admission limits reach every adapter that takes them.
    SZFriendsAdmissionLimits *limits = [SZFriendsAdmissionLimits defaultLimits];
    CHECK(limits.pendingPerListener == 32 && limits.pendingPerAddress == 4 && limits.nnPerMinutePerListener == 0);
    limits.nnPerMinutePerListener = 60;
    coordinator.admissionLimits = limits;
    CHECK(coordinator.admissionLimits.nnPerMinutePerListener == 60 &&
          network.admissionLimits.nnPerMinutePerListener == 60);
}

static void TestDialing(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.discovery", DISPATCH_QUEUE_SERIAL);
    SZFTestAdapter *network = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork];
    SZFTestAdapter *bluetooth = [[SZFTestAdapter alloc] initWithMethod:SZFriendsDiscoveryMethodBluetooth];
    network.queue = bluetooth.queue = queue;
    SZFTestCoordinatorDelegate *delegate = [SZFTestCoordinatorDelegate new];
    SZFriendsDiscoveryCoordinator *coordinator = MakeCoordinator(network, bluetooth, queue, delegate);
    coordinator.delayScale = 0.2; // Bluetooth after 100 ms instead of 500
    gNow = SZFTestDate(3000);
    __block SZFriendsRouteMethod current = SZFriendsRouteMethodNone;
    __block NSMutableArray<SZFriendsDialAttempt *> *opened = [NSMutableArray array];
    dispatch_sync(queue, ^{
        [coordinator activate];
        [network sight:SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"lan", MeiTag(), @[],
                                       NO, gNow)];
        [bluetooth sight:SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt",
                                         MeiTag(), @[], NO, gNow)];
        network.openStreams[@"lan"] = [SZFTestStream new];
        bluetooth.openStreams[@"bt"] = [SZFTestStream new];
        [coordinator dialCandidate:coordinator.merger.candidates.firstObject
            currentRoute:^SZFriendsRouteMethod {
                return current;
            }
            onStream:^(id<SZFriendsByteStream> stream, SZFriendsDialAttempt *attempt) {
                (void)stream;
                [opened addObject:attempt];
                // The handshake on LAN completes at once in this script.
                SZFriendsRouteRacer *racer = coordinator.racer;
                if ([racer decisionForCompletedRoute:attempt.sighting.route currentRoute:current] !=
                    SZFriendsRaceDecisionClose) {
                    current = attempt.sighting.route;
                }
            }];
    });
    CHECK(SZFTestWait(queue, 2, ^BOOL {
        return opened.count == 1;
    }));
    usleep(300000); // well past the scaled Bluetooth delay
    dispatch_sync(queue, ^{
        CHECK(network.openRequests.count == 1 && bluetooth.openRequests.count == 0, "LAN won: Bluetooth never dialed");
        CHECK(current == SZFriendsRouteMethodLAN);
    });

    // LAN fails: Bluetooth is dialed after its stagger and carries the session.
    current = SZFriendsRouteMethodNone;
    [opened removeAllObjects];
    dispatch_sync(queue, ^{
        [network.openStreams removeAllObjects];
        [coordinator dialCandidate:coordinator.merger.candidates.firstObject
            currentRoute:^SZFriendsRouteMethod {
                return current;
            }
            onStream:^(id<SZFriendsByteStream> stream, SZFriendsDialAttempt *attempt) {
                (void)stream;
                [opened addObject:attempt];
                current = attempt.sighting.route;
            }];
    });
    CHECK(SZFTestWait(queue, 2, ^BOOL {
        return opened.count == 1;
    }));
    dispatch_sync(queue, ^{
        CHECK(current == SZFriendsRouteMethodBluetooth && bluetooth.openRequests.count == 1);
    });
}

void SZFriendsRunCoordinatorTests(void) {
    TestLaunch();
    TestIndependence();
    TestWakeRefreshAndAccept();
    TestDialing();
}
