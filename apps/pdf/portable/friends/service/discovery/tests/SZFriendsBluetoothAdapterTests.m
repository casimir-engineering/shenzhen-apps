// The CoreBluetooth adapter's logic over a scripted radio. No CBCentralManager or CBPeripheralManager is ever
// created here: that would ask the person for Bluetooth access. hardware-matrix.md lists what real radios check.

#import "SZFriendsBluetoothTestRadio.h"

static NSDate *gClock;

static NSData *Payload(NSString *tagHex, uint16_t hiddenPSM, uint16_t publicPSM, NSArray<NSData *> *callbacks) {
    return SZFTestPresence(tagHex, hiddenPSM, publicPSM, callbacks);
}

static void TestPayloadAndPermissions(void) {
    NSData *callback = SZFTestData(@"0505050505050505");
    NSData *value = Payload(@"0102030405060708", 0x0081, 0x00c5, @[ callback ]);
    // version, flags, tag, hidden PSM, public PSM, count, callback tag
    CHECK([value isEqual:SZFTestData(@"01" @"01" @"0102030405060708" @"0081" @"00c5" @"01" @"0505050505050505")], "%@",
          SZFriendsHexFromData(value));
    SZFriendsBluetoothPresence *parsed = [SZFriendsBluetoothPresence presenceFromValue:value];
    CHECK([parsed.presenceTag isEqual:SZFTestData(@"0102030405060708")] && parsed.hiddenPSM == 0x81 &&
          parsed.publicPSM == 0xc5 && [parsed.callbackTags isEqual:@[ callback ]]);
    CHECK([SZFriendsBluetoothPresence presenceFromValue:Payload(nil, 1, 0, @[])].presenceTag == nil);
    NSMutableData *longer = [value mutableCopy];
    [longer appendBytes:"future" length:6];
    CHECK([SZFriendsBluetoothPresence presenceFromValue:longer] != nil, "version 1 may grow at the end");
    CHECK([SZFriendsBluetoothPresence presenceFromValue:[value subdataWithRange:NSMakeRange(0, 20)]] == nil,
          "truncated");
    CHECK([SZFriendsBluetoothPresence presenceFromValue:[NSData data]] == nil);
    NSMutableData *otherVersion = [value mutableCopy];
    ((uint8_t *)otherVersion.mutableBytes)[0] = 2;
    CHECK([SZFriendsBluetoothPresence presenceFromValue:otherVersion] == nil);
    NSMutableData *tooMany = [Payload(@"0102030405060708", 1, 0, @[]) mutableCopy];
    ((uint8_t *)tooMany.mutableBytes)[14] = 5;
    [tooMany appendData:[NSMutableData dataWithLength:40]];
    CHECK([SZFriendsBluetoothPresence presenceFromValue:tooMany] == nil, "more than 4 callback tags is malformed");

    CHECK(SZFriendsPermissionFromBluetoothAuthorization(CBManagerAuthorizationNotDetermined) ==
          SZFriendsPermissionNotDetermined);
    CHECK(SZFriendsPermissionFromBluetoothAuthorization(CBManagerAuthorizationAllowedAlways) ==
          SZFriendsPermissionAllowed);
    CHECK(SZFriendsPermissionFromBluetoothAuthorization(CBManagerAuthorizationDenied) == SZFriendsPermissionDenied);
    CHECK(SZFriendsPermissionFromBluetoothAuthorization(CBManagerAuthorizationRestricted) == SZFriendsPermissionDenied);
}

// ADR 0004 § Verification "Launch": creating the production adapters creates no browser, listener or manager.
static void TestFactoriesCreateNothing(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.bt", DISPATCH_QUEUE_SERIAL);
    NSUInteger managers = SZFriendsCoreBluetoothManagersCreated(), network = SZFriendsNetworkObjectsCreated();
    id<SZFriendsDiscoveryAdapter> bluetooth = SZFriendsMakeBluetoothAdapter(queue);
    id<SZFriendsDiscoveryAdapter> lan = SZFriendsMakeNetworkAdapter(queue);
    [lan advertisePresenceTag:SZFTestData(@"0101010101010101") callbackTags:@[] publicEntry:YES];
    [bluetooth advertisePresenceTag:SZFTestData(@"0101010101010101") callbackTags:@[] publicEntry:YES];
    CHECK(lan.permissionWithoutPrompting == SZFriendsPermissionUnknown);
    CHECK(bluetooth.state == SZFriendsAdapterStateNotAsked && lan.state == SZFriendsAdapterStateNotAsked);
    CHECK(SZFriendsCoreBluetoothManagersCreated() == managers && managers == 0);
    CHECK(SZFriendsNetworkObjectsCreated() == network && network == 0);
}

static void TestLifecycleAndAdvertising(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.bt", DISPATCH_QUEUE_SERIAL);
    SZFTestRadio *radio = [SZFTestRadio new];
    radio.permission = SZFriendsPermissionNotDetermined;
    SZFriendsBluetoothAdapterOptions *options = [SZFriendsBluetoothAdapterOptions new];
    options.clock = ^NSDate * {
        return gClock;
    };
    id<SZFriendsDiscoveryAdapter> adapter = SZFriendsMakeBluetoothAdapterWithRadio(queue, radio, options);
    SZFTestAdapterDelegate *delegate = [SZFTestAdapterDelegate new];
    adapter.delegate = delegate;
    CHECK(adapter.permissionWithoutPrompting == SZFriendsPermissionNotDetermined && radio.powerUps == 0,
          "reading permission creates nothing");
    [adapter advertisePresenceTag:SZFTestData(@"0101010101010101") callbackTags:@[] publicEntry:NO];
    CHECK(radio.powerUps == 0 && radio.advertisedValue == nil, "advertising before start waits for start");

    [adapter start];
    CHECK(radio.powerUps == 1 && adapter.state == SZFriendsAdapterStateStarting);
    [radio.delegate radioDidUpdatePower:SZFriendsRadioPowerOn];
    CHECK(adapter.state == SZFriendsAdapterStateWorking && radio.scanning);
    CHECK([radio.publishRequests isEqual:@[ @NO ]] && !radio.advertisedPublic);
    SZFriendsBluetoothPresence *advertised = [SZFriendsBluetoothPresence presenceFromValue:radio.advertisedValue];
    CHECK([advertised.presenceTag isEqual:SZFTestData(@"0101010101010101")] && advertised.hiddenPSM == 0);
    [radio.delegate radioDidPublishChannelWithPSM:0x0081 publicEntry:NO];
    CHECK([SZFriendsBluetoothPresence presenceFromValue:radio.advertisedValue].hiddenPSM == 0x81, "the PSM is served");

    CHECK(advertised.callbackTags.count == SZFriendsCallbackTagsMax, "always exactly 4 callback slots");

    // The person's 5 minutes: a public channel and the public UUID; the deadline takes both away. The new tag is a
    // new window, so a new hidden channel is published for it too, and the public UUID waits for its channel.
    NSData *callback = SZFTestData(@"0505050505050505");
    [adapter advertisePresenceTag:SZFTestData(@"0202020202020202") callbackTags:@[ callback ] publicEntry:YES];
    CHECK([radio.publishRequests isEqual:(@[ @NO, @NO, @YES ])] && !radio.advertisedPublic, "%@",
          radio.publishRequests);
    [radio.delegate radioDidPublishChannelWithPSM:0x0082 publicEntry:NO];
    CHECK(!radio.advertisedPublic, "nothing of the new window until its public channel exists too");
    [radio.delegate radioDidPublishChannelWithPSM:0x00c5 publicEntry:YES];
    advertised = [SZFriendsBluetoothPresence presenceFromValue:radio.advertisedValue];
    SZFriendsBluetoothPresence *publicEntry =
        [SZFriendsBluetoothPresence presenceFromValue:radio.advertisedPublicValue];
    CHECK(radio.advertisedPublic && publicEntry.publicPSM == 0xc5 && advertised.hiddenPSM == 0x82);
    CHECK(advertised.publicPSM == 0 && publicEntry.presenceTag == nil && publicEntry.hiddenPSM == 0 &&
              publicEntry.callbackTags.count == 0,
          "the public entry has its own value, with nothing of the hidden one");
    CHECK([advertised.callbackTags containsObject:callback] &&
          advertised.callbackTags.count == SZFriendsCallbackTagsMax);
    [adapter advertisePresenceTag:SZFTestData(@"0202020202020202") callbackTags:@[] publicEntry:NO];
    CHECK([radio.unpublished isEqual:@[ @0xc5 ]] && !radio.advertisedPublic, "%@", radio.unpublished);
    CHECK(radio.advertisedPublicValue == nil);
    [radio.delegate radioDidPublishChannelWithPSM:0x00d1 publicEntry:YES]; // a late publish after the deadline
    CHECK([radio.unpublished isEqual:(@[ @0xc5, @0xd1 ])], "a channel published after the deadline is withdrawn");

    // Each radio state is its own adapter state, and power coming back sets everything up again.
    [radio.delegate radioDidUpdatePower:SZFriendsRadioPowerOff];
    CHECK(adapter.state == SZFriendsAdapterStateRadioOff);
    [radio.delegate radioDidUpdatePower:SZFriendsRadioPowerUnauthorized];
    CHECK(adapter.state == SZFriendsAdapterStateDenied);
    [radio.delegate radioDidUpdatePower:SZFriendsRadioPowerUnsupported];
    CHECK(adapter.state == SZFriendsAdapterStateUnsupported);
    [radio.delegate radioDidUpdatePower:SZFriendsRadioPowerOn];
    CHECK(adapter.state == SZFriendsAdapterStateWorking && radio.publishRequests.count == 4, "republished on power on");
    CHECK([delegate.states containsObject:@(SZFriendsAdapterStateRadioOff)]);

    [adapter stop];
    CHECK(radio.powerDowns == 1 && adapter.state == SZFriendsAdapterStateNotAsked);
    [radio.delegate radioDidUpdatePower:SZFriendsRadioPowerOn];
    CHECK(adapter.state == SZFriendsAdapterStateNotAsked, "a stopped adapter ignores late radio news");
}

static void TestDiscoveryAndChannels(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.bt", DISPATCH_QUEUE_SERIAL);
    SZFTestRadio *radio = [SZFTestRadio new];
    SZFriendsBluetoothAdapterOptions *options = [SZFriendsBluetoothAdapterOptions new];
    options.clock = ^NSDate * {
        return gClock;
    };
    id<SZFriendsDiscoveryAdapter> adapter = SZFriendsMakeBluetoothAdapterWithRadio(queue, radio, options);
    SZFTestAdapterDelegate *delegate = [SZFTestAdapterDelegate new];
    adapter.delegate = delegate;
    gClock = SZFTestDate(1990875.0 * 900 + 10);
    [adapter start];
    [radio.delegate radioDidUpdatePower:SZFriendsRadioPowerOn];

    NSData *callback = SZFTestData(@"0505050505050505");
    [radio.delegate radioDidDiscoverPeripheral:@"P1" publicEntry:NO];
    CHECK([radio.reads isEqual:@[ @"P1" ]] && delegate.sightings.count == 0, "nothing reported before the read");
    CHECK([radio.readsAskingPublic isEqual:@[ @NO ]], "no public value asked of a device that is not visible");
    [radio.delegate radioDidReadPresence:Payload(@"0101010101010101", 0x85, 0, @[ callback ])
                             publicValue:nil
                          fromPeripheral:@"P1"];
    CHECK(delegate.sightings.count == 1);
    SZFriendsSighting *sighting = delegate.sightings[0];
    CHECK(sighting.method == SZFriendsDiscoveryMethodBluetooth && sighting.route == SZFriendsRouteMethodBluetooth &&
          !sighting.isPublic && [sighting.presenceTag isEqual:SZFTestData(@"0101010101010101")] &&
          [sighting.callbackTags isEqual:@[ callback ]] && [sighting.seenAt isEqual:gClock]);

    // Seen again in the same window: reported from the cache, no new connection.
    gClock = [gClock dateByAddingTimeInterval:60];
    [radio.delegate radioDidDiscoverPeripheral:@"P1" publicEntry:NO];
    CHECK(radio.reads.count == 1 && delegate.sightings.count == 2 && [delegate.sightings[1].seenAt isEqual:gClock]);
    // Visibility started over there: the advertisement changed, so read again, the public value too, and find the
    // public entry there. A public PSM inside the hidden value is not one: each field from its own characteristic.
    [radio.delegate radioDidDiscoverPeripheral:@"P1" publicEntry:YES];
    CHECK(radio.reads.count == 2 && [radio.readsAskingPublic.lastObject isEqual:@YES]);
    NSUInteger beforeStray = delegate.sightings.count;
    [radio.delegate radioDidReadPresence:Payload(@"0101010101010101", 0x85, 0x99, @[])
                             publicValue:nil
                          fromPeripheral:@"P1"];
    CHECK(delegate.sightings.count == beforeStray + 1 && !delegate.sightings.lastObject.isPublic,
          "no public entry from the hidden value");
    [radio.delegate radioDidDiscoverPeripheral:@"P1" publicEntry:NO]; // so the next public sighting reads again
    [radio.delegate radioDidDiscoverPeripheral:@"P1" publicEntry:YES];
    [radio.delegate radioDidReadPresence:Payload(@"0101010101010101", 0x85, 0, @[])
                             publicValue:Payload(nil, 0, 0x91, @[])
                          fromPeripheral:@"P1"];
    SZFriendsSighting *publicSighting = delegate.sightings.lastObject;
    CHECK(publicSighting.isPublic && publicSighting.presenceTag == nil && publicSighting.callbackTags.count == 0);
    NSString *publicEndpoint = publicSighting.endpointID;
    // The next window rotates tags: the cache is stale.
    gClock = SZFTestDate(1990876.0 * 900 + 1);
    [radio.delegate radioDidDiscoverPeripheral:@"P1" publicEntry:NO];
    NSUInteger readsBefore = radio.reads.count;
    [radio.delegate radioDidReadPresence:Payload(@"0202020202020202", 0x85, 0, @[])
                             publicValue:nil
                          fromPeripheral:@"P1"];
    CHECK([delegate.lost isEqual:@[ publicEndpoint ]], "visibility ended: the public endpoint is lost");

    // Reads are throttled; a failed or malformed read reports nothing and frees its slot.
    [radio.delegate radioDidDiscoverPeripheral:@"P2" publicEntry:NO];
    [radio.delegate radioDidDiscoverPeripheral:@"P3" publicEntry:NO];
    [radio.delegate radioDidDiscoverPeripheral:@"P4" publicEntry:NO];
    CHECK(radio.reads.count == readsBefore + 2 && [radio.reads.lastObject isEqual:@"P3"], "%@", radio.reads);
    NSUInteger before = delegate.sightings.count;
    [radio.delegate radioDidReadPresence:nil publicValue:nil fromPeripheral:@"P2"];
    [radio.delegate radioDidReadPresence:SZFTestData(@"02") publicValue:nil fromPeripheral:@"P3"];
    CHECK(delegate.sightings.count == before && [radio.reads.lastObject isEqual:@"P4"]);

    // Channels: the hidden endpoint dials the hidden PSM; unknown endpoints and missing channels fail.
    SZFTestStream *stream = [SZFTestStream new];
    radio.openResult = stream;
    __block id<SZFriendsByteStream> opened = nil;
    [adapter openStreamToEndpoint:sighting.endpointID
                       completion:^(id<SZFriendsByteStream> s, NSError *e) {
                           (void)e;
                           opened = s;
                       }];
    CHECK(opened == stream && [radio.opens isEqual:@[ @"P1#133" ]]);
    __block NSError *failure = nil;
    [adapter openStreamToEndpoint:publicEndpoint
                       completion:^(id<SZFriendsByteStream> s, NSError *e) {
                           (void)s;
                           failure = e;
                       }];
    [adapter openStreamToEndpoint:@"bluetooth:nobody"
                       completion:^(id<SZFriendsByteStream> s, NSError *e) {
                           (void)s;
                           (void)e;
                       }];
    CHECK(SZFTestWait(queue, 2, ^BOOL {
        return failure != nil;
    }));
    CHECK(failure.code == SZFriendsDiscoveryErrorNoChannel && radio.opens.count == 1, "no public channel any more");

    [radio.delegate radioDidAcceptChannel:[SZFTestStream new] publicEntry:YES peerID:@"C1"];
    [radio.delegate radioDidAcceptChannel:[SZFTestStream new] publicEntry:NO peerID:@"C2"];
    CHECK([delegate.acceptedPublic isEqual:(@[ @YES, @NO ])]);

    [adapter stop];
}

static void TestScanRefresh(void) {
    // Its own adapter, so the timer runs on the queue with nothing else touching the adapter meanwhile.
    dispatch_queue_t queue = dispatch_queue_create("test.bt", DISPATCH_QUEUE_SERIAL);
    SZFTestRadio *radio = [SZFTestRadio new];
    SZFriendsBluetoothAdapterOptions *options = [SZFriendsBluetoothAdapterOptions new];
    options.scanRefreshInterval = 0.05;
    id<SZFriendsDiscoveryAdapter> adapter = SZFriendsMakeBluetoothAdapterWithRadio(queue, radio, options);
    dispatch_sync(queue, ^{
        [adapter start];
        [radio.delegate radioDidUpdatePower:SZFriendsRadioPowerOn];
    });
    // Scanning restarts on its own, so duplicates-off scans keep renewing sightings.
    CHECK(SZFTestWait(queue, 2, ^BOOL {
        return radio.scanStarts >= 3 && radio.scanStops >= 2;
    }));
    dispatch_sync(queue, ^{
        [adapter stop];
    });
}

// Review finding "presence linkability": the hidden channel used to be published once, so its PSM sat beside every
// window's tag. Each new tag now gets a new channel; the new tag is never served beside the old PSM; the old channel
// goes after its overlap; advertising restarts at the boundary.
static void TestWindowRotation(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.bt.rotation", DISPATCH_QUEUE_SERIAL);
    SZFTestRadio *radio = [SZFTestRadio new];
    SZFriendsBluetoothAdapterOptions *options = [SZFriendsBluetoothAdapterOptions new];
    options.channelOverlap = 0.05;
    id<SZFriendsDiscoveryAdapter> adapter = SZFriendsMakeBluetoothAdapterWithRadio(queue, radio, options);
    NSData *tagA = SZFTestData(@"a1a1a1a1a1a1a1a1"), *tagB = SZFTestData(@"b2b2b2b2b2b2b2b2");
    NSData *tagC = SZFTestData(@"c3c3c3c3c3c3c3c3");
    __block NSUInteger stopsBefore = 0;
    dispatch_sync(queue, ^{
        [adapter advertisePresenceTag:tagA callbackTags:@[] publicEntry:NO];
        [adapter start];
        [radio.delegate radioDidUpdatePower:SZFriendsRadioPowerOn];
        [radio.delegate radioDidPublishChannelWithPSM:0x0081 publicEntry:NO];
        stopsBefore = radio.advertisingStops;
        [adapter advertisePresenceTag:tagB callbackTags:@[] publicEntry:NO];
        CHECK([radio.publishRequests isEqual:(@[ @NO, @NO ])], "a new channel for the new window");
        SZFriendsBluetoothPresence *held = [SZFriendsBluetoothPresence presenceFromValue:radio.advertisedValue];
        CHECK([held.presenceTag isEqual:tagA] && held.hiddenPSM == 0x81, "the old window is served until then");
        [radio.delegate radioDidPublishChannelWithPSM:0x0082 publicEntry:NO];
        SZFriendsBluetoothPresence *now = [SZFriendsBluetoothPresence presenceFromValue:radio.advertisedValue];
        CHECK([now.presenceTag isEqual:tagB] && now.hiddenPSM == 0x82, "tag and PSM change together");
        CHECK(radio.advertisingStops == stopsBefore + 1, "advertising restarts at the boundary");
        CHECK(radio.unpublished.count == 0, "the old channel stays for its overlap");
    });
    CHECK(SZFTestWait(queue, 2, ^BOOL {
        return [radio.unpublished isEqual:@[ @0x81 ]];
    }), "then it goes: %@", radio.unpublished);

    // Publishing fails for the next window: it is served with no channel rather than beside the old PSM.
    dispatch_sync(queue, ^{
        [adapter advertisePresenceTag:tagC callbackTags:@[] publicEntry:NO];
        [radio.delegate radioDidPublishChannelWithPSM:0 publicEntry:NO];
        SZFriendsBluetoothPresence *now = [SZFriendsBluetoothPresence presenceFromValue:radio.advertisedValue];
        CHECK([now.presenceTag isEqual:tagC] && now.hiddenPSM == 0);
        [adapter advertisePresenceTag:tagC callbackTags:@[] publicEntry:NO];
        CHECK(radio.publishRequests.count == 4, "and tries again on the next advertisement");
    });
    CHECK(SZFTestWait(queue, 2, ^BOOL {
        return [radio.unpublished containsObject:@0x82];
    }));
    dispatch_sync(queue, ^{
        for (NSData *value in radio.advertisedHistory) {
            SZFriendsBluetoothPresence *served = [SZFriendsBluetoothPresence presenceFromValue:value];
            BOOL mixed = ([served.presenceTag isEqual:tagB] && served.hiddenPSM == 0x81) ||
                         ([served.presenceTag isEqual:tagC] && served.hiddenPSM == 0x82);
            CHECK(!mixed, "a tag was served beside another window's PSM");
            CHECK(served.callbackTags.count == SZFriendsCallbackTagsMax, "4 callback slots in every value");
        }
        [adapter stop];
    });
}

// Places on the accept path (review finding "admission lockout"): 4 per central and 32 per listener by default, and
// a full one closes its oldest channel that has not authenticated instead of dropping the newcomer.
static void TestBluetoothAdmission(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.bt.admission", DISPATCH_QUEUE_SERIAL);
    SZFTestRadio *radio = [SZFTestRadio new];
    id<SZFriendsDiscoveryAdapter> adapter =
        SZFriendsMakeBluetoothAdapterWithRadio(queue, radio, [SZFriendsBluetoothAdapterOptions new]);
    SZFriendsAdmissionLimits *noDeadline = [SZFriendsAdmissionLimits defaultLimits];
    noDeadline.firstMessageTimeout = 0; // the deadline has its own check below
    [adapter setAdmissionLimits:noDeadline];
    SZFTestAdapterDelegate *delegate = [SZFTestAdapterDelegate new];
    adapter.delegate = delegate;
    [adapter start];
    [radio.delegate radioDidUpdatePower:SZFriendsRadioPowerOn];
    NSMutableArray<SZFTestStream *> *raw = [NSMutableArray array];
    for (int i = 0; i < 6; i++) {
        SZFTestStream *stream = [SZFTestStream new];
        [raw addObject:stream];
        [radio.delegate radioDidAcceptChannel:stream publicEntry:NO peerID:@"same-central"];
    }
    CHECK(delegate.accepted.count == 6 && raw[0].closed && raw[1].closed && !raw[2].closed && !raw[5].closed,
          "the fifth and sixth from one central take the places of its two oldest");
    id<SZFriendsByteStream> third = delegate.accepted[2];
    CHECK([third respondsToSelector:@selector(sessionDidAuthenticate)], "the session can report who it is");
    [third sessionDidAuthenticate];
    [radio.delegate radioDidAcceptChannel:[SZFTestStream new] publicEntry:NO peerID:@"same-central"];
    CHECK(delegate.accepted.count == 7 && !raw[2].closed && !raw[3].closed,
          "an authenticated session gave its place back, so nobody had to make way");
    NSMutableArray<SZFTestStream *> *flood = [NSMutableArray array];
    for (int i = 0; i < 40; i++) {
        SZFTestStream *stream = [SZFTestStream new];
        [flood addObject:stream];
        [radio.delegate radioDidAcceptChannel:stream
                                  publicEntry:NO
                                       peerID:[NSString stringWithFormat:@"central-%d", i]];
    }
    // Four from same-central still held places: 44 asked for 32, so the 12 oldest made way.
    CHECK(delegate.accepted.count == 7 + 40 && raw[3].closed && flood[7].closed && !flood[8].closed &&
              !raw[2].closed,
          "the listener holds 32 at most, and an authenticated session is never among those closed");
    SZFTestStream *visible = [SZFTestStream new];
    [radio.delegate radioDidAcceptChannel:visible publicEntry:YES peerID:@"central-x"];
    CHECK(delegate.accepted.count == 7 + 41 && !visible.closed && !flood[8].closed, "the public entry counts alone");

    // With the default deadline, a central that connects and sends nothing loses its place.
    SZFriendsAdmissionLimits *quick = [SZFriendsAdmissionLimits defaultLimits];
    quick.firstMessageTimeout = 0.1;
    [adapter setAdmissionLimits:quick];
    SZFTestStream *silent = [SZFTestStream new];
    dispatch_sync(queue, ^{
        [radio.delegate radioDidAcceptChannel:silent publicEntry:NO peerID:@"silent-central"];
    });
    CHECK(SZFTestWait(queue, 3, ^BOOL {
        return silent.closed;
    }), "closed after the deadline");
    [adapter stop];
}

void SZFriendsRunBluetoothAdapterTests(void) {
    TestWindowRotation();
    TestBluetoothAdmission();
    TestPayloadAndPermissions();
    TestFactoriesCreateNothing();
    TestLifecycleAndAdvertising();
    TestDiscoveryAndChannels();
    TestScanRefresh();
    SZFriendsRunBluetoothVisibilityTests();
}
