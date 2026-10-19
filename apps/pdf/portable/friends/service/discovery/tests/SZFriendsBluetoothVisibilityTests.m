// Bluetooth while visible (review finding "presence linkability", wave 3). One characteristic value used to carry the
// hidden tag, the hidden PSM and the public PSM together, and the public channel was published once for the whole 5
// minutes, so a reader during a window boundary saw the same public PSM beside the old tag and then the new one. Now
// the public entry has its own value, its own channel per window, and nothing of a new window is served beside a
// channel of the old one.

#import "SZFriendsBluetoothTestRadio.h"

static SZFriendsBluetoothPresence *Parse(id value) {
    return [value isKindOfClass:[NSData class]] ? [SZFriendsBluetoothPresence presenceFromValue:value] : nil;
}

// A running adapter over a powered radio, visible with `tag`, its first hidden and public channels published.
static id<SZFriendsDiscoveryAdapter> VisibleAdapter(dispatch_queue_t queue, SZFTestRadio *radio, NSData *tag,
                                                    uint16_t hiddenPSM, uint16_t publicPSM) {
    SZFriendsBluetoothAdapterOptions *options = [SZFriendsBluetoothAdapterOptions new];
    options.channelOverlap = 0.05;
    id<SZFriendsDiscoveryAdapter> adapter = SZFriendsMakeBluetoothAdapterWithRadio(queue, radio, options);
    dispatch_sync(queue, ^{
        [adapter advertisePresenceTag:tag callbackTags:@[] publicEntry:YES];
        [adapter start];
        [radio.delegate radioDidUpdatePower:SZFriendsRadioPowerOn];
        [radio.delegate radioDidPublishChannelWithPSM:hiddenPSM publicEntry:NO];
        [radio.delegate radioDidPublishChannelWithPSM:publicPSM publicEntry:YES];
    });
    return adapter;
}

static void TestPublicChannelPerWindow(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.bt.visible", DISPATCH_QUEUE_SERIAL);
    SZFTestRadio *radio = [SZFTestRadio new];
    NSData *tagA = SZFTestData(@"a1a1a1a1a1a1a1a1"), *tagB = SZFTestData(@"b2b2b2b2b2b2b2b2");
    id<SZFriendsDiscoveryAdapter> adapter = VisibleAdapter(queue, radio, tagA, 0x81, 0xc1);
    __block NSUInteger stopsBefore = 0;
    dispatch_sync(queue, ^{
        CHECK(radio.advertisedPublic && Parse(radio.advertisedPublicValue).publicPSM == 0xc1);
        stopsBefore = radio.advertisingStops;
        // The window turns while visible: a new hidden channel and a new public channel, both.
        [adapter advertisePresenceTag:tagB callbackTags:@[] publicEntry:YES];
        CHECK([radio.publishRequests isEqual:(@[ @NO, @YES, @NO, @YES ])], "%@", radio.publishRequests);
        [radio.delegate radioDidPublishChannelWithPSM:0x82 publicEntry:NO];
        SZFriendsBluetoothPresence *held = Parse(radio.advertisedValue);
        CHECK([held.presenceTag isEqual:tagA] && held.hiddenPSM == 0x81 &&
                  Parse(radio.advertisedPublicValue).publicPSM == 0xc1,
              "the old window is served whole until both channels are new");
        [radio.delegate radioDidPublishChannelWithPSM:0xc2 publicEntry:YES];
        SZFriendsBluetoothPresence *next = Parse(radio.advertisedValue);
        CHECK([next.presenceTag isEqual:tagB] && next.hiddenPSM == 0x82 &&
                  Parse(radio.advertisedPublicValue).publicPSM == 0xc2,
              "then everything changes together");
        CHECK(radio.advertisingStops == stopsBefore + 1, "advertising restarts at the boundary");
        CHECK(radio.unpublished.count == 0, "the old channels stay for their overlap");
    });
    CHECK(SZFTestWait(queue, 2, ^BOOL {
        return [radio.unpublished containsObject:@0x81] && [radio.unpublished containsObject:@0xc1];
    }), "then both go: %@", radio.unpublished);
    dispatch_sync(queue, ^{
        CHECK(![radio.unpublished containsObject:@0xc2], "the new public channel stays");
        for (NSArray *pair in radio.advertisedPairs) {
            SZFriendsBluetoothPresence *hidden = Parse(pair[0]), *visible = Parse(pair[1]);
            CHECK(hidden.publicPSM == 0, "the hidden value never names the public channel");
            CHECK(visible == nil || (visible.presenceTag == nil && visible.hiddenPSM == 0 &&
                                     visible.callbackTags.count == 0),
                  "the public value carries nothing of the hidden entry");
            BOOL oldChannel = hidden.hiddenPSM == 0x81 || visible.publicPSM == 0xc1;
            BOOL newChannel = hidden.hiddenPSM == 0x82 || visible.publicPSM == 0xc2;
            BOOL mixed = ([hidden.presenceTag isEqual:tagB] && oldChannel) ||
                         ([hidden.presenceTag isEqual:tagA] && newChannel);
            CHECK(!mixed, "an advertisement mixed two windows: tag %@ hidden %u public %u", hidden.presenceTag,
                  hidden.hiddenPSM, visible.publicPSM);
        }
        [adapter stop];
    });
}

// The deadline right after a boundary: the current public channel and the one replaced at the boundary both go at
// once, rather than the old one lingering for its overlap.
static void TestDeadlineTakesEveryPublicChannel(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.bt.deadline", DISPATCH_QUEUE_SERIAL);
    SZFTestRadio *radio = [SZFTestRadio new];
    NSData *tagA = SZFTestData(@"a1a1a1a1a1a1a1a1"), *tagB = SZFTestData(@"b2b2b2b2b2b2b2b2");
    id<SZFriendsDiscoveryAdapter> adapter = VisibleAdapter(queue, radio, tagA, 0x81, 0xc1);
    dispatch_sync(queue, ^{
        [adapter advertisePresenceTag:tagB callbackTags:@[] publicEntry:YES];
        [radio.delegate radioDidPublishChannelWithPSM:0x82 publicEntry:NO];
        [radio.delegate radioDidPublishChannelWithPSM:0xc2 publicEntry:YES];
        [adapter advertisePresenceTag:tagB callbackTags:@[] publicEntry:NO];
        CHECK([radio.unpublished containsObject:@0xc1] && [radio.unpublished containsObject:@0xc2] &&
                  ![radio.unpublished containsObject:@0x81],
              "both public channels at the deadline, the hidden one only after its overlap: %@", radio.unpublished);
        CHECK(!radio.advertisedPublic && radio.advertisedPublicValue == nil);
    });
    usleep(150000);
    dispatch_sync(queue, ^{
        NSUInteger publicWithdrawals = 0;
        for (NSNumber *psm in radio.unpublished) publicWithdrawals += psm.unsignedIntValue == 0xc1;
        CHECK(publicWithdrawals == 1, "and the overlap timer does not withdraw it again");
        [adapter stop];
    });
}

// The public UUID goes on the air with a channel to dial, never before (a reader would cache the empty answer), and
// a failed publish at a boundary serves the new window without a public entry rather than with the old channel.
static void TestPublicEntryOnlyWithItsChannel(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.bt.public", DISPATCH_QUEUE_SERIAL);
    SZFTestRadio *radio = [SZFTestRadio new];
    NSData *tagA = SZFTestData(@"a1a1a1a1a1a1a1a1"), *tagB = SZFTestData(@"b2b2b2b2b2b2b2b2");
    SZFriendsBluetoothAdapterOptions *options = [SZFriendsBluetoothAdapterOptions new];
    options.channelOverlap = 0.05;
    id<SZFriendsDiscoveryAdapter> adapter = SZFriendsMakeBluetoothAdapterWithRadio(queue, radio, options);
    dispatch_sync(queue, ^{
        [adapter advertisePresenceTag:tagA callbackTags:@[] publicEntry:NO];
        [adapter start];
        [radio.delegate radioDidUpdatePower:SZFriendsRadioPowerOn];
        [radio.delegate radioDidPublishChannelWithPSM:0x81 publicEntry:NO];
        // Visible in the middle of a window.
        [adapter advertisePresenceTag:tagA callbackTags:@[] publicEntry:YES];
        CHECK([radio.publishRequests.lastObject isEqual:@YES] && !radio.advertisedPublic, "not before the channel");
        [radio.delegate radioDidPublishChannelWithPSM:0xc1 publicEntry:YES];
        CHECK(radio.advertisedPublic && Parse(radio.advertisedPublicValue).publicPSM == 0xc1 &&
                  [Parse(radio.advertisedValue).presenceTag isEqual:tagA],
              "the window goes on; the public entry joins it");
        [adapter advertisePresenceTag:tagB callbackTags:@[] publicEntry:YES];
        [radio.delegate radioDidPublishChannelWithPSM:0x82 publicEntry:NO];
        [radio.delegate radioDidPublishChannelWithPSM:0 publicEntry:YES];
        CHECK([Parse(radio.advertisedValue).presenceTag isEqual:tagB] && !radio.advertisedPublic,
              "the new window without a public entry, never beside the old public channel");
        [adapter advertisePresenceTag:tagB callbackTags:@[] publicEntry:YES];
        CHECK([radio.publishRequests.lastObject isEqual:@YES], "and the next advertisement tries again");
        [radio.delegate radioDidPublishChannelWithPSM:0xc3 publicEntry:YES];
        CHECK(radio.advertisedPublic && Parse(radio.advertisedPublicValue).publicPSM == 0xc3);
    });
    CHECK(SZFTestWait(queue, 2, ^BOOL {
        return [radio.unpublished containsObject:@0xc1];
    }), "the old window's public channel still goes after its overlap");
    dispatch_sync(queue, ^{
        [adapter stop];
    });
}

void SZFriendsRunBluetoothVisibilityTests(void) {
    TestPublicChannelPerWindow();
    TestDeadlineTakesEveryPublicChannel();
    TestPublicEntryOnlyWithItsChannel();
}
