// Who this computer is to Nearby and what it advertises (SZFriendsNearbyParts.h): the discovery window, our key, the
// advertisement and tag matcher, and the PROFILE fields friends see. Moved from SZFriendsNearbyService.m as it was.

#import "service/helper/nearby/SZFriendsNearbyDevices.h"
#import "service/helper/nearby/SZFriendsNearbyJoin.h"
#import "service/helper/nearby/SZFriendsWakeMonitor.h"

@implementation SZFriendsNearbyService (Advertising)

- (int64_t)currentWindow {
    return SZFriendsPresenceWindowIndex([NSDate date]);
}

- (NSData *)localIdentityKey {
    return self.services.identity.publicKey ?: [NSData data];
}

- (void)refreshAdvertisement {
    if (self.coordinator == nil || ![self ready]) return;
    SZFriendsStore *store = self.services.store;
    NSDate *now = [NSDate date];
    NSData *secret = store.ownPresenceSecret;
    NSData *tag = secret != nil ? SZFriendsPresenceTag(secret, SZFriendsPresenceWindowIndex(now)) : nil;
    // One of several devices of this profile, not the first: friends find it by a tag of its own (+FriendDevices).
    tag = [self ownFriendPresenceTagAtDate:now] ?: tag;
    NSArray<SZFriendsPendingCallback *> *pending = [self advertisedCallbacksAtDate:now];
    BOOL publicEntry = [self.visibility isVisibleAt:SZFriendsInstantNow()];
    // Our other devices find this one by a tag only they can match (+Sync); it takes the first of the callback slots.
    NSMutableArray<NSData *> *slots = [NSMutableArray array];
    NSData *ownDeviceTag = [self ownDeviceTagAtDate:now];
    if (ownDeviceTag != nil) [slots addObject:ownDeviceTag];
    for (NSData *callback in SZFriendsCallbackTagsToAdvertise(pending, now)) {
        if (slots.count < SZFriendsCallbackTagsMax) [slots addObject:callback];
    }
    [self.coordinator advertisePresenceTag:tag callbackTags:slots publicEntry:publicEntry];
}

- (void)rebuildTagMatcher {
    if (self.coordinator == nil || self.services.store == nil) return;
    NSMutableDictionary<NSString *, NSArray<NSData *> *> *secrets = [NSMutableDictionary dictionary];
    for (SZFriendsPersonRecord *person in [self.services.store peopleByLatestInteraction]) {
        // Never blocked or removed people: recognising them would mean reconnecting to them.
        if (person.relation == SZFriendsRelationBlocked || person.relation == SZFriendsRelationRemoved) continue;
        NSMutableArray<NSData *> *list = [NSMutableArray array];
        if (person.relation == SZFriendsRelationFriend && person.presenceSecret != nil) {
            [list addObject:person.presenceSecret];
        }
        // An Add by ID requester's callback tags: how we find them to call back after Accept (ADR 0004 step 4).
        if (person.callbackSecret != nil) [list addObject:person.callbackSecret];
        if (list.count > 0) secrets[person.conversationID] = list;
    }
    [secrets addEntriesFromDictionary:[self ownDeviceTagSecrets]]; // our other devices, as "dev-<key>" (+Sync)
    [secrets addEntriesFromDictionary:[self friendDeviceTagSecrets]]; // friends' other devices (+FriendDevices)
    self.coordinator.merger.tagMatcher = SZFriendsMakeTagMatcher(secrets, [NSDate date]);
    [self scheduleReconsider];
    [self changed];
}

- (NSDictionary<NSNumber *, NSData *> *)profileFields {
    SZFriendsStore *store = self.services.store;
    NSMutableDictionary<NSNumber *, NSData *> *fields = [NSMutableDictionary dictionary];
    // No name yet: friends see the Friends ID (brief § Product contract), so the field is left out.
    NSData *name = [store.profileName dataUsingEncoding:NSUTF8StringEncoding];
    if (name.length > 0 && name.length <= 1024) fields[@(SZFriendsFieldName)] = name;
    NSData *friendsID = [store.friendsID dataUsingEncoding:NSUTF8StringEncoding];
    if (friendsID.length > 0 && friendsID.length <= 64) fields[@(SZFriendsFieldFriendsID)] = friendsID;
    SZFriendsPicture *picture = store.profilePicture;
    if (picture.kind == SZFriendsPictureKindAnimal) {
        NSData *set = [SZFriendsFrame fieldWithUInt64:(uint64_t)picture.animalSet tag:SZFriendsFieldPictureSet];
        NSData *index = [SZFriendsFrame fieldWithUInt64:(uint64_t)picture.animalIndex tag:SZFriendsFieldPictureIndex];
        if (set != nil && index != nil) {
            fields[@(SZFriendsFieldPictureSet)] = set;
            fields[@(SZFriendsFieldPictureIndex)] = index;
        }
    } else if (picture.kind == SZFriendsPictureKindImage && picture.imagePath != nil) {
        // Our own picture was normalised by the avatars pipeline when it was chosen: a 256 px JPEG of 48 KiB at
        // most, so it fits one frame. Anything larger on disk is not ours to send.
        NSData *jpeg = [NSData dataWithContentsOfFile:picture.imagePath];
        if (jpeg.length > 0 && jpeg.length <= SZFriendsFramePictureMax) fields[@(SZFriendsFieldData)] = jpeg;
    }
    return fields;
}

@end
