// How someone nearby was found (client capability nearby.found): Nearby's rows and a friend's list row carry `found`,
// the methods that see the person and their names joined, and their spoken labels end "Found over ...".
//
// nearby-found.json: both methods working, nobody visible, four people as SZPNearbyVisibleBluetoothOff has them, found
// over: Kenji (friend) the local network and Bluetooth, Lena (stranger) Bluetooth, Tomás (request sent) the local
// network, coral-lagoon (stranger, no name) direct Wi-Fi, the local network and Bluetooth (listed lan, p2p_wifi,
// bluetooth whatever order the facts give). list-found.json: the list's people, Mei found over the local network and
// Bluetooth, Kenji over Bluetooth, and Lena (a request, not a friend) over the local network, which her row never says.

#import "SZFriendsPresentationWorld.h"

static SZFriendsAudience *FoundAudience(void) {
    SZFriendsAudience *audience = SZPAudience();
    audience.capabilities = [audience.capabilities setByAddingObject:@"nearby.found"];
    return audience;
}

static SZFriendsNearbyPersonFacts *Seen(NSString *nearbyID, NSString *conversationID, NSString *name,
                                        NSString *friendsID, NSInteger animal, BOOL stranger,
                                        SZFriendsPersonRelation relation, NSArray<NSNumber *> *found) {
    SZFriendsNearbyPersonFacts *person = [[SZFriendsNearbyPersonFacts alloc] init];
    person.nearbyID = nearbyID;
    person.conversationID = conversationID;
    person.name = name;
    person.friendsID = friendsID;
    person.picture = [SZFriendsPicture animalWithSet:1 index:animal];
    person.isStranger = stranger;
    person.relation = relation;
    person.routeMethod = (SZFriendsRouteMethod)[found.firstObject integerValue];
    person.foundMethods = found;
    return person;
}

static SZFriendsNearbyFacts *FoundNearby(void) {
    NSNumber *lan = @(SZFriendsRouteMethodLAN), *p2p = @(SZFriendsRouteMethodPeerToPeerWiFi),
             *bluetooth = @(SZFriendsRouteMethodBluetooth);
    SZFriendsNearbyFacts *nearby = [[SZFriendsNearbyFacts alloc] init];
    nearby.networkState = SZFriendsAdapterStateWorking;
    nearby.bluetoothState = SZFriendsAdapterStateWorking;
    nearby.workingSince = SZPHongKong(@"2026-10-12 14:40:10");
    nearby.people = @[
        Seen(nil, @"c_kenji", @"Kenji Sato", @"cedar-lantern", 1, NO, SZFriendsPersonRelationFriend, @[ lan, bluetooth ]),
        Seen(@"n_7c1e", nil, @"Lena Weber", @"amber-falcon", 3, YES, SZFriendsPersonRelationFriend, @[ bluetooth ]),
        Seen(@"n_2b90", @"c_tomas", @"Tomás Rivera", @"juniper-spring", 4, YES, SZFriendsPersonRelationOutgoingRequest,
             @[ lan ]),
        Seen(@"n_9d44", nil, nil, @"coral-lagoon", 10, YES, SZFriendsPersonRelationFriend, @[ bluetooth, lan, p2p ]),
    ];
    return nearby;
}

static NSArray<SZFriendsPersonFacts *> *FoundPeople(void) {
    NSDictionary<NSString *, SZFriendsPersonFacts *> *people = SZPPeople();
    people[@"c_mei"].foundMethods = @[ @(SZFriendsRouteMethodLAN), @(SZFriendsRouteMethodBluetooth) ];
    people[@"c_kenji"].foundMethods = @[ @(SZFriendsRouteMethodBluetooth) ];
    people[@"c_lena"].foundMethods = @[ @(SZFriendsRouteMethodLAN) ];
    return people.allValues;
}

static NSDictionary *Row(NSArray *rows, NSString *key, NSString *value) {
    for (NSDictionary *row in rows)
        if ([row[key] isEqual:value]) return row;
    return nil;
}

static void TestFoundFixtures(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(FoundAudience());
    NSDictionary *nearby = [builder nearbyWithFacts:FoundNearby() profile:SZPProfileRaph() query:@"" now:SZPNow()];
    SZPExpectFixture(nearby, @"nearby-found.json", @"nearby");
    NSDictionary *kenji = Row(nearby[@"people"], @"conversation_id", @"c_kenji");
    SZPExpect([kenji[@"found"] isEqual:(@{@"methods" : @[ @"lan", @"bluetooth" ],
                                          @"label" : @"Local network and Bluetooth"})] &&
                  [kenji[@"accessibility_label"] hasSuffix:@", Found over Local network and Bluetooth"],
              @"%@", kenji);
    NSDictionary *coral = Row(nearby[@"people"], @"nearby_id", @"n_9d44");
    SZPExpect([coral[@"found"][@"methods"] isEqual:(@[ @"lan", @"p2p_wifi", @"bluetooth" ])] &&
                  [coral[@"found"][@"label"] isEqual:@"Local network, Direct Wi-Fi and Bluetooth"],
              @"three, in their order: %@", coral[@"found"]);
    NSDictionary *list = [builder listWithPeople:FoundPeople() previewItems:SZPPreviewItems() profile:SZPProfileRaph()
                                           query:@"" now:SZPNow()];
    SZPExpectFixture(list, @"list-found.json", @"list");
    SZPExpect([Row(list[@"rows"], @"conversation_id", @"c_kenji")[@"found"][@"label"] isEqual:@"Bluetooth"],
              @"a friend nearby");
    SZPExpect(Row(list[@"rows"], @"conversation_id", @"c_lena")[@"found"] == NSNull.null &&
                  Row(list[@"rows"], @"conversation_id", @"c_priya")[@"found"] == NSNull.null,
              @"a request's row never says, nor a friend's who is not nearby");
}

// Without nearby.found, nothing changes: no key, the spoken labels as they were.
static void TestWithoutFound(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSDictionary *nearby = [builder nearbyWithFacts:FoundNearby() profile:SZPProfileRaph() query:@"" now:SZPNow()];
    for (NSDictionary *person in nearby[@"people"])
        SZPExpect(person[@"found"] == nil && ![person[@"accessibility_label"] containsString:@"Found over"], @"%@",
                  person);
    NSDictionary *list = [builder listWithPeople:FoundPeople() previewItems:SZPPreviewItems() profile:SZPProfileRaph()
                                           query:@"" now:SZPNow()];
    for (NSDictionary *row in list[@"rows"]) SZPExpect(row[@"found"] == nil, @"%@", row);
    SZFriendsNearbyFacts *facts = FoundNearby();
    for (SZFriendsNearbyPersonFacts *person in facts.people) person.foundMethods = nil;
    nearby = [SZPBuilder(FoundAudience()) nearbyWithFacts:facts profile:SZPProfileRaph() query:@"" now:SZPNow()];
    for (NSDictionary *person in nearby[@"people"]) SZPExpect(person[@"found"] == NSNull.null, @"%@", person);
}

void SZPRunFoundTests(void) {
    TestFoundFixtures();
    TestWithoutFound();
}
