// What each event's body says, to and from the store's records (SZFriendsSyncInternal.h). Encodings are deterministic,
// so the register a device keeps for a value compares equal to the value read back from its store.

#import "avatars/SZFriendsAvatars.h"
#import "service/sync/SZFriendsSyncInternal.h"

NS_ASSUME_NONNULL_BEGIN

NSString *const SZFriendsSyncGroupRelation = @"relation";
NSString *const SZFriendsSyncGroupProfile = @"profile";
NSString *const SZFriendsSyncGroupKeys = @"keys";
NSString *const SZFriendsSyncGroupTrust = @"trust";
NSString *const SZFriendsSyncSettingPresence = @"presence";
NSString *const SZFriendsSyncSettingDevices = @"devices";
NSString *const SZFriendsSyncStateDevicesSecret = @"own_devices_secret";
NSString *const SZFriendsSyncSettingRenewed = @"renewed";
NSString *const SZFriendsSyncStateRenewed = @"revocations_renewed_digest";
NSString *const SZFriendsSyncStatePresenceDrawn = @"presence_drawn_here";
NSString *const SZFriendsSyncStatePresenceRetell = @"presence_retell";

// Largest photo a body carries: a re-encoded picture is far smaller (SZFriendsFramePictureMax is 49,152 bytes).
static const NSUInteger SZFriendsSyncPhotoMax = 49152;

NSArray<NSString *> *SZFriendsSyncPersonGroups(void) {
    return @[ SZFriendsSyncGroupRelation, SZFriendsSyncGroupKeys, SZFriendsSyncGroupProfile, SZFriendsSyncGroupTrust ];
}

NSString *SZFriendsSyncHex(NSData *data) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

NSData *_Nullable SZFriendsSyncBytesFromHex(NSString *hex) {
    if (hex.length % 2 != 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:hex.length / 2];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < hex.length / 2; i++) {
        unsigned value = 0;
        for (NSUInteger j = 0; j < 2; j++) {
            unichar c = [hex characterAtIndex:i * 2 + j];
            unsigned digit = (c >= '0' && c <= '9') ? c - '0' : (c >= 'a' && c <= 'f') ? c - 'a' + 10 : 16;
            if (digit > 15) return nil;
            value = value * 16 + digit;
        }
        bytes[i] = (uint8_t)value;
    }
    return data;
}

NSString *SZFriendsSyncRefForPerson(SZFriendsPersonRecord *person) {
    if ([person.conversationID isEqualToString:SZFriendsYouConversationID]) return SZFriendsYouConversationID;
    if (person.identityKey.length == 32) return [@"k:" stringByAppendingString:SZFriendsSyncHex(person.identityKey)];
    return [@"c:" stringByAppendingString:person.conversationID];
}

NSString *SZFriendsSyncPersonKey(NSString *conversationID, NSString *group) {
    return [NSString stringWithFormat:@"p/%@/%@", conversationID, group];
}

NSString *SZFriendsSyncReadKey(NSString *conversationID) {
    return [@"r/" stringByAppendingString:conversationID];
}

BOOL SZFriendsSyncIsLater(uint64_t lamport, NSData *author, SZFriendsSyncRegister *_Nullable current) {
    if (current == nil) return YES;
    if (lamport != current.lamport) return lamport > current.lamport;
    NSArray<NSData *> *sorted = SZFriendsSyncSortedKeys(@[ author, current.author ?: [NSData data] ]);
    return ![author isEqualToData:current.author] && sorted.lastObject == author;
}

#pragma mark - Pictures

static void SZFriendsSyncPutPicture(SZFriendsSyncFields *fields, SZFriendsPicture *picture, uint8_t base, BOOL full) {
    [fields setUInt64:(uint64_t)picture.kind forTag:base];
    if (picture.kind == SZFriendsPictureKindAnimal) {
        [fields setUInt64:(uint64_t)picture.animalSet forTag:base + 1];
        [fields setUInt64:(uint64_t)picture.animalIndex forTag:base + 2];
    } else if (picture.kind == SZFriendsPictureKindImage) {
        [fields setData:picture.imageSHA256 forTag:base + 3];
        if (full && picture.imagePath != nil) {
            NSData *bytes = [NSData dataWithContentsOfFile:picture.imagePath options:NSDataReadingMappedIfSafe
                                                     error:NULL];
            if (bytes.length <= SZFriendsSyncPhotoMax) [fields setData:bytes forTag:base + 4];
        }
    }
}

// The picture a body names; a photo comes back as its bytes in `photo` with a placeholder until the caller stores it.
static SZFriendsPicture *SZFriendsSyncGetPicture(SZFriendsSyncFields *fields, uint8_t base, NSData *_Nullable *photo) {
    switch ([fields uint64ForTag:base]) {
    case SZFriendsPictureKindAnimal:
        return [SZFriendsPicture animalWithSet:(NSInteger)MIN([fields uint64ForTag:base + 1], (uint64_t)INT32_MAX)
                                         index:(NSInteger)MIN([fields uint64ForTag:base + 2], (uint64_t)INT32_MAX)];
    case SZFriendsPictureKindImage: {
        NSData *bytes = [fields dataForTag:base + 4];
        if (photo && bytes.length > 0 && bytes.length <= SZFriendsSyncPhotoMax) *photo = bytes;
        return [SZFriendsPicture placeholder];
    }
    default: return [SZFriendsPicture placeholder];
    }
}

#pragma mark - People

NSData *SZFriendsSyncPersonGroupBody(SZFriendsPersonRecord *person, NSString *group, BOOL full) {
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setString:person.conversationID forTag:SZFSTagConversation];
    if ([group isEqualToString:SZFriendsSyncGroupRelation]) {
        [fields setUInt64:(uint64_t)person.relation forTag:2];
        [fields setDate:person.requestAt forTag:3];
        [fields setUInt64:person.requestFoundNearby forTag:4];
        // With the relation, not apart from it: the store turns it off for a blocked person, so the two must win
        // together or two devices could end with different values.
        [fields setUInt64:person.autoAccept forTag:5];
        // When the person took them off the list, with the relation it depends on. Written only when set, so the
        // body of anyone never taken off the list is what helpers before tag 6 wrote, and they ignore the tag.
        if (person.leftListAt) [fields setDate:person.leftListAt forTag:6];
    } else if ([group isEqualToString:SZFriendsSyncGroupProfile]) {
        [fields setString:person.name forTag:2];
        [fields setString:person.friendsID forTag:3];
        SZFriendsSyncPutPicture(fields, person.picture ?: [SZFriendsPicture placeholder], 4, full);
    } else if ([group isEqualToString:SZFriendsSyncGroupKeys]) {
        [fields setData:person.identityKey forTag:2];
        [fields setData:person.staticKey forTag:3];
        [fields setData:person.presenceSecret forTag:4];
        [fields setData:person.callbackToken forTag:5];
        [fields setData:person.callbackSecret forTag:6];
    } else if ([group isEqualToString:SZFriendsSyncGroupTrust]) {
        [fields setUInt64:person.verified forTag:2];
        [fields setDate:person.verifiedAt forTag:3];
        [fields setString:person.comparisonCode forTag:4];
    }
    return fields.encodedData;
}

static BOOL SZFriendsSyncKeyFits(NSData *_Nullable key, NSUInteger length) {
    return key == nil || key.length == length;
}

BOOL SZFriendsSyncApplyPersonGroup(SZFriendsSyncFields *fields, NSString *group, SZFriendsPersonRecord *person,
                                   NSData *_Nullable *_Nullable photo) {
    if ([group isEqualToString:SZFriendsSyncGroupRelation]) {
        uint64_t relation = [fields uint64ForTag:2];
        if (relation > SZFriendsRelationBlocked) return NO;
        person.relation = (SZFriendsRelation)relation;
        person.requestAt = [fields dateForTag:3];
        person.requestFoundNearby = [fields uint64ForTag:4] != 0;
        person.autoAccept = [fields uint64ForTag:5] != 0;
        person.leftListAt = [fields dateForTag:6]; // the store keeps it only for someone Removed or Blocked
    } else if ([group isEqualToString:SZFriendsSyncGroupProfile]) {
        person.name = [fields stringForTag:2];
        person.friendsID = [fields stringForTag:3];
        person.picture = SZFriendsSyncGetPicture(fields, 4, photo);
    } else if ([group isEqualToString:SZFriendsSyncGroupKeys]) {
        NSData *identity = [fields dataForTag:2], *staticKey = [fields dataForTag:3];
        NSData *presence = [fields dataForTag:4], *token = [fields dataForTag:5], *callback = [fields dataForTag:6];
        if (!SZFriendsSyncKeyFits(identity, 32) || !SZFriendsSyncKeyFits(staticKey, 32) ||
            !SZFriendsSyncKeyFits(presence, 32) || !SZFriendsSyncKeyFits(token, 16) ||
            !SZFriendsSyncKeyFits(callback, 32)) {
            return NO;
        }
        // Keys only ever arrive: a stored identity or static key changes through the reviewed path alone (ADR 0001),
        // so another device's value fills a gap and never replaces one.
        if (person.identityKey == nil) person.identityKey = identity;
        if (person.staticKey == nil) person.staticKey = staticKey;
        person.presenceSecret = presence;
        person.callbackToken = token;
        person.callbackSecret = callback;
    } else if ([group isEqualToString:SZFriendsSyncGroupTrust]) {
        person.verified = [fields uint64ForTag:2] != 0;
        person.verifiedAt = [fields dateForTag:3];
        person.comparisonCode = [fields stringForTag:4];
    } else {
        return NO;
    }
    return YES;
}

// The name and picture. Not the Friends ID (tags 3 and 4 are retired): it belongs to the person on the Friends host,
// whose welcome gives every device the ID it holds, and only the first device ever draws a new one after a collision;
// a device's own ID before it joined, or a collision seen on one device, must never travel to the others.
NSData *SZFriendsSyncProfileBody(SZFriendsStore *store, BOOL full) {
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setString:store.profileName forTag:2];
    SZFriendsSyncPutPicture(fields, store.profilePicture ?: [SZFriendsPicture placeholder], 5, full);
    return fields.encodedData;
}

#pragma mark - History

NSData *SZFriendsSyncItemBody(SZFriendsItemRecord *item) {
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setString:item.conversationID forTag:SZFSTagConversation];
    [fields setUInt64:(uint64_t)item.kind forTag:2];
    [fields setUInt64:(uint64_t)item.direction forTag:3];
    [fields setDate:item.sentAt forTag:4];
    [fields setDate:item.receivedAt forTag:5];
    [fields setString:item.text forTag:6];
    [fields setString:item.transferID forTag:7];
    [fields setString:item.eventKind forTag:8];
    if (item.eventArguments.count > 0 && [NSJSONSerialization isValidJSONObject:item.eventArguments]) {
        [fields setData:[NSJSONSerialization dataWithJSONObject:item.eventArguments options:NSJSONWritingSortedKeys
                                                          error:NULL]
                 forTag:9];
    }
    [fields setUInt64:item.viaAssistant forTag:10];
    [fields setUInt64:item.cancelled forTag:11];
    return fields.encodedData;
}

SZFriendsItemRecord *_Nullable SZFriendsSyncItemFromBody(SZFriendsSyncFields *fields, NSString *itemID) {
    uint64_t kind = [fields uint64ForTag:2], direction = [fields uint64ForTag:3];
    NSDate *sent = [fields dateForTag:4], *received = [fields dateForTag:5];
    if (kind > SZFriendsItemKindEvent || direction > SZFriendsDirectionOutgoing || sent == nil || received == nil) {
        return nil;
    }
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = itemID;
    item.kind = (SZFriendsItemKind)kind;
    item.direction = (SZFriendsDirection)direction;
    item.sentAt = sent;
    item.receivedAt = received;
    item.text = [fields stringForTag:6];
    item.transferID = [fields stringForTag:7];
    item.eventKind = [fields stringForTag:8];
    NSData *arguments = [fields dataForTag:9];
    id parsed = arguments ? [NSJSONSerialization JSONObjectWithData:arguments options:0 error:NULL] : nil;
    if ([parsed isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary<NSString *, NSString *> *strings = [NSMutableDictionary dictionary];
        [(NSDictionary *)parsed enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) strings[key] = value;
        }];
        item.eventArguments = strings;
    }
    item.viaAssistant = [fields uint64ForTag:10] != 0;
    item.cancelled = [fields uint64ForTag:11] != 0;
    item.outboxState = -1;
    return item;
}

NSData *SZFriendsSyncReadBody(NSString *conversationID, NSDate *receivedAt, NSString *itemID) {
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setString:conversationID forTag:SZFSTagConversation];
    [fields setDate:receivedAt forTag:2];
    [fields setString:itemID forTag:3];
    return fields.encodedData;
}

#pragma mark - Outbox

SZFriendsOutboxState SZFriendsSyncOutboxFoldedState(SZFriendsOutboxState state) {
    BOOL inFlight = state == SZFriendsOutboxStateConnecting || state == SZFriendsOutboxStateSending;
    return inFlight ? SZFriendsOutboxStateQueued : state;
}

NSData *SZFriendsSyncOutboxBody(SZFriendsOutboxEntry *entry) {
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setString:entry.conversationID forTag:SZFSTagConversation];
    [fields setUInt64:(uint64_t)entry.kind forTag:2];
    [fields setUInt64:(uint64_t)SZFriendsSyncOutboxFoldedState(entry.state) forTag:3];
    [fields setDate:entry.createdAt forTag:4];
    [fields setString:entry.itemID forTag:5];
    [fields setString:entry.failureReason forTag:6];
    [fields setData:entry.payload forTag:7];
    return fields.encodedData;
}

SZFriendsOutboxEntry *_Nullable SZFriendsSyncOutboxFromBody(SZFriendsSyncFields *fields, NSString *entryID) {
    uint64_t kind = [fields uint64ForTag:2], state = [fields uint64ForTag:3];
    if (kind > SZFriendsOutboxKindPresenceSecret || state > SZFriendsOutboxStateFailed) return nil;
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = entryID;
    entry.kind = (SZFriendsOutboxKind)kind;
    entry.state = (SZFriendsOutboxState)state;
    entry.createdAt = [fields dateForTag:4] ?: [NSDate dateWithTimeIntervalSince1970:0];
    entry.itemID = [fields stringForTag:5];
    entry.failureReason = [fields stringForTag:6];
    entry.payload = [fields dataForTag:7];
    return entry;
}

#pragma mark - Files

BOOL SZFriendsSyncFileStateIsFinal(SZFriendsTransferState state) {
    return state == SZFriendsTransferStateDelivered || state == SZFriendsTransferStateReceived;
}

NSData *SZFriendsSyncFileBody(SZFriendsSyncFileRecord *file) {
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setString:file.conversationID forTag:SZFSTagConversation];
    [fields setString:file.itemID forTag:2];
    [fields setUInt64:file.outgoing forTag:3];
    [fields setUInt64:(uint64_t)file.state forTag:4];
    [fields setString:file.fileName forTag:5];
    [fields setString:file.uniformType forTag:6];
    [fields setUInt64:file.size forTag:7];
    [fields setData:file.contentDigest forTag:8];
    [fields setDate:file.createdAt forTag:9];
    return fields.encodedData;
}

SZFriendsSyncFileRecord *_Nullable SZFriendsSyncFileFromBody(SZFriendsSyncFields *fields, NSString *transferID) {
    uint64_t state = [fields uint64ForTag:4];
    NSString *name = [fields stringForTag:5];
    NSData *digest = [fields dataForTag:8];
    if (state > SZFriendsTransferStateFailed || name.length == 0 || digest.length != 32) return nil;
    SZFriendsSyncFileRecord *file = [[SZFriendsSyncFileRecord alloc] init];
    file.transferID = transferID;
    file.itemID = [fields stringForTag:2];
    file.outgoing = [fields uint64ForTag:3] != 0;
    file.state = (SZFriendsTransferState)state;
    file.fileName = name;
    file.uniformType = [fields stringForTag:6];
    file.size = [fields uint64ForTag:7];
    file.contentDigest = digest;
    file.createdAt = [fields dateForTag:9] ?: [NSDate dateWithTimeIntervalSince1970:0];
    file.holders = @[];
    return file;
}

SZFriendsSyncFileRecord *SZFriendsSyncFileFromTransfer(SZFriendsTransferRecord *transfer, NSString *_Nullable itemID) {
    SZFriendsSyncFileRecord *file = [[SZFriendsSyncFileRecord alloc] init];
    file.transferID = transfer.transferID;
    file.conversationID = transfer.conversationID;
    file.itemID = itemID;
    file.outgoing = transfer.outgoing;
    file.state = transfer.state;
    file.fileName = transfer.fileName;
    file.uniformType = transfer.uniformType;
    file.size = transfer.size;
    file.contentDigest = transfer.contentDigest;
    file.createdAt = transfer.createdAt ?: [NSDate dateWithTimeIntervalSince1970:0];
    file.holders = @[];
    return file;
}

NS_ASSUME_NONNULL_END
