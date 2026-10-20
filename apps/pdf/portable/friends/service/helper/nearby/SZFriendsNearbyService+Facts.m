// What Nearby and the routes in every view show, read from live discovery and sessions (SZFriendsNearbyService.h).

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

static SZFriendsPersonRelation SZFriendsFactsRelation(SZFriendsRelation relation) {
    switch (relation) {
    case SZFriendsRelationIncomingRequest: return SZFriendsPersonRelationIncomingRequest;
    case SZFriendsRelationOutgoingRequest: return SZFriendsPersonRelationOutgoingRequest;
    case SZFriendsRelationFriend: return SZFriendsPersonRelationFriend;
    case SZFriendsRelationRemoved: return SZFriendsPersonRelationRemoved;
    case SZFriendsRelationBlocked: return SZFriendsPersonRelationBlocked;
    }
    return SZFriendsPersonRelationRemoved;
}

// The discovery methods behind these sightings, each once, in the order views list them: LAN, peer-to-peer Wi-Fi,
// Bluetooth.
static NSArray<NSNumber *> *SZFriendsFoundMethods(NSArray<SZFriendsSighting *> *sightings) {
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (SZFriendsSighting *sighting in sightings) [seen addObject:@(sighting.route)];
    NSMutableArray<NSNumber *> *methods = [NSMutableArray array];
    for (NSNumber *route in @[ @(SZFriendsRouteMethodLAN), @(SZFriendsRouteMethodPeerToPeerWiFi),
                               @(SZFriendsRouteMethodBluetooth) ]) {
        if ([seen containsObject:route]) [methods addObject:route];
    }
    return methods;
}

@implementation SZFriendsNearbyService (Facts)

- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)foundMethodsByConversation {
    if (self.coordinator == nil) return @{};
    NSMutableDictionary<NSString *, NSMutableArray<SZFriendsSighting *> *> *sightings = [NSMutableDictionary dictionary];
    for (SZFriendsCandidate *candidate in self.coordinator.merger.identifiedCandidates) {
        // A friend's other device is the friend (+FriendDevices).
        NSString *conversationID =
            SZFriendsNearbyFriendDeviceConversation(candidate.conversationID, NULL) ?: candidate.conversationID;
        if (conversationID == nil) continue;
        if (sightings[conversationID] == nil) sightings[conversationID] = [NSMutableArray array];
        [sightings[conversationID] addObjectsFromArray:candidate.sightings];
    }
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *found = [NSMutableDictionary dictionary];
    for (NSString *conversationID in sightings) found[conversationID] = SZFriendsFoundMethods(sightings[conversationID]);
    return found;
}

- (BOOL)hasAdapterForMethod:(SZFriendsDiscoveryMethod)method {
    for (id<SZFriendsDiscoveryAdapter> adapter in self.adapters) {
        if (adapter.method == method) return YES;
    }
    return NO;
}

- (SZFriendsAdapterState)stateOfMethod:(SZFriendsDiscoveryMethod)method {
    // A method this helper has no adapter for (only under SZFRIENDS_STATE_DIR) cannot find anyone; saying so is
    // truer than "not asked", which promises a search once Friends is opened.
    if (![self hasAdapterForMethod:method]) return SZFriendsAdapterStateUnavailable;
    return [self.coordinator stateOfMethod:method];
}

- (SZFriendsRouteMethod)liveRouteForConversation:(NSString *)conversationID {
    SZFriendsPeerLink *link = [self liveLinkForConversation:conversationID];
    return link != nil ? link.raceRoute : SZFriendsRouteMethodNone;
}

// A stranger's picture from their public profile: their animal by set and index, otherwise the placeholder (which
// the views draw as initials). Photo bytes a public entry serves are never decoded: anyone nearby can serve them
// and the helper would parse them with no one asking (review: stranger pictures). A request from them brings their
// PROFILE, whose photo then goes through the avatars pipeline like any friend's (-updatePerson:withProfile:).
- (SZFriendsPicture *)publicPictureForKey:(NSString *)keyHex fields:(NSDictionary<NSNumber *, NSData *> *)fields {
    SZFriendsPicture *cached = self.publicPictures[keyHex];
    if (cached != nil) return cached;
    SZFriendsFrame *profile = [SZFriendsFrame frameWithType:SZFriendsFrameTypeProfile fields:fields];
    uint64_t set = 0, index = 0;
    BOOL animal = [profile getUInt64:&set forTag:SZFriendsFieldPictureSet] &&
                  [profile getUInt64:&index forTag:SZFriendsFieldPictureIndex];
    SZFriendsPicture *picture = animal ? [SZFriendsPicture animalWithSet:(NSInteger)set index:(NSInteger)index]
                                       : [SZFriendsPicture placeholder];
    self.publicPictures[keyHex] = picture;
    return picture;
}

- (NSArray<SZFriendsNearbyPersonFacts *> *)nearbyPeople {
    SZFriendsStore *store = self.services.store;
    if (self.coordinator == nil || store == nil) return @[];
    NSMutableArray<SZFriendsNearbyPersonFacts *> *people = [NSMutableArray array];
    for (SZFriendsCandidate *candidate in self.coordinator.merger.identifiedCandidates) {
        SZFriendsPersonRecord *person = nil;
        // A friend's other device is the friend (+FriendDevices).
        NSString *conversationID =
            SZFriendsNearbyFriendDeviceConversation(candidate.conversationID, NULL) ?: candidate.conversationID;
        if (conversationID != nil) person = [store personWithConversationID:conversationID];
        else if (candidate.identityKey != nil) person = [store personWithIdentityKey:candidate.identityKey];
        if (person.relation == SZFriendsRelationBlocked) continue; // blocked people never appear
        SZFriendsNearbyPersonFacts *facts = [[SZFriendsNearbyPersonFacts alloc] init];
        facts.routeMethod = candidate.sightings.firstObject.route;
        facts.foundMethods = SZFriendsFoundMethods(candidate.sightings);
        BOOL known = person != nil && person.relation != SZFriendsRelationRemoved;
        if (known) {
            facts.conversationID = person.conversationID;
            facts.name = person.name;
            facts.friendsID = person.friendsID;
            facts.picture = person.picture ?: [SZFriendsPicture placeholder];
            facts.relation = SZFriendsFactsRelation(person.relation);
            facts.isStranger = person.relation != SZFriendsRelationFriend;
        } else {
            if (candidate.identityKey == nil) continue;
            // Someone visible for their 5 minutes, described by what their public entry served. A removed person
            // looks the same: either side may ask again.
            NSString *keyHex = SZFriendsLinkHex(candidate.identityKey);
            NSDictionary<NSNumber *, NSData *> *fields = self.publicProfiles[keyHex] ?: @{};
            // Name and ID cleaned the way a friend's profile is; the picture separately, once per key.
            NSMutableDictionary<NSNumber *, NSData *> *text = [NSMutableDictionary dictionary];
            text[@(SZFriendsFieldName)] = fields[@(SZFriendsFieldName)];
            text[@(SZFriendsFieldFriendsID)] = fields[@(SZFriendsFieldFriendsID)];
            SZFriendsPersonRecord *described = [[SZFriendsPersonRecord alloc] init];
            [self updatePerson:described withProfile:text];
            facts.nearbyID = candidate.candidateID;
            facts.conversationID = person.conversationID;
            facts.name = described.name;
            facts.friendsID = described.friendsID;
            facts.picture = [self publicPictureForKey:keyHex fields:fields];
            facts.relation = SZFriendsPersonRelationRemoved; // no relation: Nearby offers Request
            facts.isStranger = YES;
        }
        [people addObject:facts];
    }
    return people;
}

- (nullable SZFriendsNearbyStranger *)strangerWithNearbyID:(NSString *)nearbyID {
    SZFriendsCandidate *candidate = [self.coordinator.merger candidateWithID:nearbyID];
    NSData *key = candidate.identityKey;
    if (candidate == nil || !candidate.isIdentified || key.length != 32) return nil;
    NSString *keyHex = SZFriendsLinkHex(key);
    NSDictionary<NSNumber *, NSData *> *fields = self.publicProfiles[keyHex] ?: @{};
    SZFriendsPersonRecord *described = [[SZFriendsPersonRecord alloc] init];
    NSMutableDictionary<NSNumber *, NSData *> *text = [NSMutableDictionary dictionary];
    text[@(SZFriendsFieldName)] = fields[@(SZFriendsFieldName)];
    text[@(SZFriendsFieldFriendsID)] = fields[@(SZFriendsFieldFriendsID)];
    [self updatePerson:described withProfile:text];
    SZFriendsNearbyStranger *stranger = [[SZFriendsNearbyStranger alloc] init];
    stranger.nearbyID = nearbyID;
    stranger.identityKey = key;
    stranger.staticKey = self.publicStaticKeys[keyHex];
    stranger.name = described.name;
    stranger.friendsID = described.friendsID;
    stranger.picture = [self publicPictureForKey:keyHex fields:fields];
    return stranger;
}

- (BOOL)liveTransfer:(NSString *)transferID state:(SZFriendsLiveTransfer *)state {
    for (SZFriendsPeerLink *link in self.links) {
        if (link.closed || link.superseded) continue;
        SZFriendsChunkReceiver *receiver = link.receivers[transferID];
        SZFriendsChunkSender *sender = link.senders[transferID];
        if (receiver == nil && sender == nil) continue;
        // Outgoing progress is what the recipient made durable, never what we merely wrote to the link.
        uint64_t bytes = receiver != nil ? receiver.receivedOffset : sender.durableOffset;
        double rate = 0;
        NSArray *start = link.rateStart[transferID];
        if (start.count == 2) {
            NSTimeInterval elapsed = -[(NSDate *)start[1] timeIntervalSinceNow];
            uint64_t from = [start[0] unsignedLongLongValue];
            if (elapsed >= 1 && bytes > from) rate = (double)(bytes - from) / elapsed;
        }
        if (state != NULL) *state = (SZFriendsLiveTransfer){.bytes = bytes, .bytesPerSecond = rate,
                                                            .route = link.raceRoute};
        return YES;
    }
    return NO;
}

@end
