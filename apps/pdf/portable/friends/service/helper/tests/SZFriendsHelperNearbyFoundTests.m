// How someone nearby was found (nearby.found): every discovery method that sees them, once each, in the order lan,
// p2p_wifi, bluetooth, on Nearby's facts and on a friend's list facts; nothing for someone no method sees, and a
// list row's facts carry it only for friends.

#import "SZFriendsHelperNearbyTests.h"

#import "service/helper/SZFriendsHelperFacts.h"

static SZFriendsSighting *SZFNFoundSighting(SZFriendsDiscoveryMethod method, SZFriendsRouteMethod route,
                                            NSString *endpoint, NSData *tag) {
    return [[SZFriendsSighting alloc] initWithMethod:method route:route endpointID:endpoint presenceTag:tag
                                        callbackTags:@[] isPublic:NO seenAt:[NSDate date]];
}

void SZFNTestFoundMethods(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"found");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[ [[SZFNRecordingAdapter alloc] init] ]);
    SZFriendsPersonRecord *mei = SZFNSavePerson(store, SZFriendsRelationFriend);
    SZFriendsPersonRecord *lena = SZFNSavePerson(store, SZFriendsRelationIncomingRequest);
    SZFriendsPersonRecord *kenji = SZFNSavePerson(store, SZFriendsRelationFriend);
    NSData *meiTag = SZFNBytes(SZFriendsPresenceTagLength), *lenaTag = SZFNBytes(SZFriendsPresenceTagLength);
    nearby.coordinator.merger.tagMatcher = ^NSString *(NSData *tag) {
        if ([tag isEqualToData:meiTag]) return mei.conversationID;
        if ([tag isEqualToData:lenaTag]) return lena.conversationID;
        return nil;
    };
    // Bluetooth first, then the network, twice over Bluetooth: listed once each, lan first.
    [nearby.coordinator.merger addSighting:SZFNFoundSighting(SZFriendsDiscoveryMethodBluetooth,
                                                             SZFriendsRouteMethodBluetooth, @"mei-ble", meiTag)];
    [nearby.coordinator.merger addSighting:SZFNFoundSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN,
                                                             @"mei-lan", meiTag)];
    [nearby.coordinator.merger addSighting:SZFNFoundSighting(SZFriendsDiscoveryMethodBluetooth,
                                                             SZFriendsRouteMethodBluetooth, @"mei-ble-2", meiTag)];
    [nearby.coordinator.merger addSighting:SZFNFoundSighting(SZFriendsDiscoveryMethodNetwork,
                                                             SZFriendsRouteMethodPeerToPeerWiFi, @"lena-p2p", lenaTag)];
    NSArray *both = @[ @(SZFriendsRouteMethodLAN), @(SZFriendsRouteMethodBluetooth) ];
    NSDictionary<NSString *, NSArray<NSNumber *> *> *found = [nearby foundMethodsByConversation];
    EXPECT([found[mei.conversationID] isEqual:both] &&
               [found[lena.conversationID] isEqual:@[ @(SZFriendsRouteMethodPeerToPeerWiFi) ]] &&
               found[kenji.conversationID] == nil,
           "by conversation: %@", found);
    for (SZFriendsNearbyPersonFacts *person in [nearby nearbyPeople]) {
        if ([person.conversationID isEqual:mei.conversationID]) EXPECT([person.foundMethods isEqual:both], "Mei");
        if ([person.conversationID isEqual:lena.conversationID])
            EXPECT([person.foundMethods isEqual:@[ @(SZFriendsRouteMethodPeerToPeerWiFi) ]], "Lena");
    }
    SZFriendsFactsPass *pass = [[SZFriendsFactsPass alloc] initWithServices:services now:[NSDate date]];
    EXPECT([[pass personWithConversationID:mei.conversationID].foundMethods isEqual:both], "a friend nearby");
    EXPECT([pass personWithConversationID:lena.conversationID].foundMethods.count == 0, "a request's row never says");
    EXPECT([pass personWithConversationID:kenji.conversationID].foundMethods.count == 0, "a friend not nearby");
    [services close];
}
