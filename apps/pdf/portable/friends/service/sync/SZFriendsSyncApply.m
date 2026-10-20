// The merge rules (SZFriendsSync.h): what each kind of event changes, so that any order of arrival leaves every device
// with the same store. Each rule is a function of the set of events it has seen:
//   - items: present unless some deletion covers one of the events that carried them;
//   - read markers: the latest (received time, id) wins;
//   - people's field groups, the profile and settings: the latest (Lamport clock, author key) wins;
//   - outbox entries: delivered wins, then the latest; file records: delivered or received wins, then the latest;
//   - who holds a file's bytes: the union.

#import "avatars/SZFriendsAvatars.h"
#import "service/sync/SZFriendsSyncInternal.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SZFriendsSyncEngine (Apply)

- (SZFriendsSyncApplyResult)applyEvent:(SZFriendsSyncEvent *)event {
    if (event.body == nil) return [self applyBodiless:event];
    SZFriendsSyncFields *fields = [SZFriendsSyncFields fieldsWithData:event.body];
    if (fields == nil) return SZFriendsSyncApplyDone; // signed by one of ours but unreadable here: nothing to do
    switch (event.kind) {
    case SZFriendsSyncKindChain: return [self applyChain:event fields:fields];
    case SZFriendsSyncKindProfile: return [self applyProfile:event fields:fields];
    case SZFriendsSyncKindSetting: return [self applySetting:event fields:fields];
    case SZFriendsSyncKindPerson: return [self applyPerson:event fields:fields];
    case SZFriendsSyncKindItem: return [self applyItem:event fields:fields];
    case SZFriendsSyncKindRead: return [self applyRead:event fields:fields];
    case SZFriendsSyncKindOutbox: return [self applyOutbox:event fields:fields];
    case SZFriendsSyncKindFile: return [self applyFile:event fields:fields];
    case SZFriendsSyncKindFileHeld:
        return [self applyFileHeld:event released:[fields uint64ForTag:SZFSTagReleased] == 1];
    case SZFriendsSyncKindTombstone:
        return [self applyTombstone:event] ? SZFriendsSyncApplyDone : SZFriendsSyncApplyFailed;
    case SZFriendsSyncKindRevocation: return [self applyRevocation:event];
    }
    return SZFriendsSyncApplyDone;
}

// A deletion dropped this body on the device we had it from: an item in it is deleted here too.
- (SZFriendsSyncApplyResult)applyBodiless:(SZFriendsSyncEvent *)event {
    if (event.kind != SZFriendsSyncKindItem) return SZFriendsSyncApplyDone;
    NSString *conversation = [self conversationForScope:event.scope authorConversation:nil];
    if (conversation == nil) return SZFriendsSyncApplyWait;
    BOOL ok = [self.store markSyncDeletedItem:event.subject inConversation:conversation fileKind:SZFriendsSyncKindFile
                                   outboxKind:SZFriendsSyncKindOutbox error:NULL];
    [self noteChangedConversation:conversation];
    return ok ? SZFriendsSyncApplyDone : SZFriendsSyncApplyFailed;
}

#pragma mark - Profile-wide

- (SZFriendsSyncApplyResult)applyChain:(SZFriendsSyncEvent *)event fields:(SZFriendsSyncFields *)fields {
    NSData *root = [self ownRootKey], *data = [fields dataForTag:2];
    SZFriendsDeviceChain *chain = root && data ? [SZFriendsDeviceChain chainWithData:data expectedRootKey:root
                                                                               error:NULL]
                                               : nil;
    if (chain == nil) return SZFriendsSyncApplyDone; // not a chain of ours: nothing to merge
    SZFriendsChainMergeResult result = [self.store mergeOwnDeviceChain:chain error:NULL];
    if (result == SZFriendsChainMergeRefused) return SZFriendsSyncApplyDone;
    if (result == SZFriendsChainMergeChanged) [self noteChangedConversation:nil];
    // What we hold now, so the next capture sends a chain only when it grew here.
    return [self setRegister:@"chain" event:event value:[self ownChainFingerprint]];
}

- (SZFriendsSyncApplyResult)applyProfile:(SZFriendsSyncEvent *)event fields:(SZFriendsSyncFields *)fields {
    SZFriendsStore *store = self.store;
    if (!SZFriendsSyncIsLater(event.lamport, event.author, [store syncRegisterForKey:@"profile"])) {
        return SZFriendsSyncApplyDone;
    }
    store.profileName = [fields stringForTag:2];
    store.profilePicture = [self pictureFromFields:fields base:5];
    [self noteChangedConversation:nil]; // the name and picture every view shows of the person
    return [self setRegister:@"profile" event:event value:SZFriendsSyncProfileBody(store, NO)];
}

- (SZFriendsPicture *)pictureFromFields:(SZFriendsSyncFields *)fields base:(uint8_t)base {
    uint64_t kind = [fields uint64ForTag:base];
    if (kind == SZFriendsPictureKindAnimal) {
        return [SZFriendsPicture animalWithSet:(NSInteger)MIN([fields uint64ForTag:base + 1], (uint64_t)INT32_MAX)
                                         index:(NSInteger)MIN([fields uint64ForTag:base + 2], (uint64_t)INT32_MAX)];
    }
    NSData *photo = [fields dataForTag:base + 4];
    if (kind == SZFriendsPictureKindImage && photo.length > 0 && self.storePicture) {
        return self.storePicture(photo) ?: [SZFriendsPicture placeholder];
    }
    return [SZFriendsPicture placeholder];
}

- (SZFriendsSyncApplyResult)applySetting:(SZFriendsSyncEvent *)event fields:(SZFriendsSyncFields *)fields {
    NSString *key = [@"s/" stringByAppendingString:event.subject];
    if (!SZFriendsSyncIsLater(event.lamport, event.author, [self.store syncRegisterForKey:key])) {
        return SZFriendsSyncApplyDone;
    }
    NSData *value = [fields dataForTag:2];
    if (value.length != 32) return SZFriendsSyncApplyDone;
    if ([event.subject isEqualToString:SZFriendsSyncSettingPresence]) {
        // Another device's draw beat the one this device told friends: they hear the winner from here too.
        id drawn = [self.store syncStateForKey:SZFriendsSyncStatePresenceDrawn];
        if ([drawn isKindOfClass:[NSData class]] && ![drawn isEqualToData:value]) {
            [self.store setSyncState:nil forKey:SZFriendsSyncStatePresenceDrawn error:NULL];
            [self.store setSyncState:@YES forKey:SZFriendsSyncStatePresenceRetell error:NULL];
        }
        self.store.ownPresenceSecret = value;
    } else if ([event.subject isEqualToString:SZFriendsSyncSettingDevices] ||
               [event.subject isEqualToString:SZFriendsSyncSettingRenewed]) {
        BOOL devices = [event.subject isEqualToString:SZFriendsSyncSettingDevices];
        BOOL stored = devices ? [self replaceOwnDevicesSecret:value]
                              : [self.store setSyncState:value forKey:SZFriendsSyncStateRenewed error:NULL];
        if (!stored) return SZFriendsSyncApplyFailed;
    } else {
        return SZFriendsSyncApplyDone; // a setting this version does not know
    }
    [self noteChangedConversation:nil];
    return [self setRegister:key event:event value:fields.encodedData];
}

- (SZFriendsSyncApplyResult)setRegister:(NSString *)key event:(SZFriendsSyncEvent *)event value:(NSData *)value {
    SZFriendsSyncRegister *entry = [[SZFriendsSyncRegister alloc] init];
    entry.lamport = event.lamport;
    entry.author = event.author;
    entry.value = value;
    return [self.store setSyncRegister:entry forKey:key error:NULL] ? SZFriendsSyncApplyDone : SZFriendsSyncApplyFailed;
}

#pragma mark - People

- (SZFriendsSyncApplyResult)applyPerson:(SZFriendsSyncEvent *)event fields:(SZFriendsSyncFields *)fields {
    NSString *group = event.subject;
    if (![SZFriendsSyncPersonGroups() containsObject:group]) return SZFriendsSyncApplyDone;
    NSString *named = [fields stringForTag:SZFSTagConversation];
    NSString *conversation = [self conversationForScope:event.scope authorConversation:named];
    SZFriendsStore *store = self.store;
    SZFriendsPersonRecord *person = conversation ? [store syncPersonWithConversationID:conversation] : nil;
    BOOL created = person == nil;
    if (person == nil) {
        // Someone this device has not met yet: their relation brings them in; anything else waits for it.
        if (![group isEqualToString:SZFriendsSyncGroupRelation]) return SZFriendsSyncApplyWait;
        person = [[SZFriendsPersonRecord alloc] init];
        BOOL free = named.length > 0 && [store syncPersonWithConversationID:named] == nil &&
                    ![named isEqualToString:SZFriendsYouConversationID];
        person.conversationID = free ? named : @"";
        if ([event.scope hasPrefix:@"k:"]) {
            person.identityKey = SZFriendsSyncBytesFromHex([event.scope substringFromIndex:2]);
        }
        person.picture = [SZFriendsPicture placeholder];
        person.lastInteractionAt = event.date;
    } else if (!SZFriendsSyncIsLater(event.lamport, event.author,
                                     [store syncRegisterForKey:SZFriendsSyncPersonKey(person.conversationID, group)])) {
        return SZFriendsSyncApplyDone;
    }
    NSData *photo = nil;
    if (!SZFriendsSyncApplyPersonGroup(fields, group, person, &photo)) return SZFriendsSyncApplyDone;
    if (photo != nil && self.storePicture) person.picture = self.storePicture(photo) ?: [SZFriendsPicture placeholder];
    NSError *error = nil;
    if (![store savePerson:person error:&error]) {
        // Refused for good (a key held by someone else, a malformed value): nothing this event can change.
        return [error.domain isEqualToString:SZFriendsStoreErrorDomain] && error.code == SZFriendsStoreErrorDatabase
                   ? SZFriendsSyncApplyFailed
                   : SZFriendsSyncApplyDone;
    }
    SZFriendsPersonRecord *stored = [store syncPersonWithConversationID:person.conversationID] ?: person;
    [self noteChangedConversation:stored.conversationID];
    if (created) {
        // The groups no event has filled yet hold what a new person has, at clock 0: not a change of ours to send,
        // and any event about them is later.
        for (NSString *other in SZFriendsSyncPersonGroups()) {
            if ([other isEqualToString:group]) continue;
            SZFriendsSyncRegister *empty = [[SZFriendsSyncRegister alloc] init];
            empty.lamport = 0;
            empty.author = [NSData data];
            empty.value = SZFriendsSyncPersonGroupBody(stored, other, NO);
            [store setSyncRegister:empty forKey:SZFriendsSyncPersonKey(stored.conversationID, other) error:NULL];
        }
    }
    return [self setRegister:SZFriendsSyncPersonKey(stored.conversationID, group) event:event
                       value:SZFriendsSyncPersonGroupBody(stored, group, NO)];
}

#pragma mark - History

- (SZFriendsSyncApplyResult)applyItem:(SZFriendsSyncEvent *)event fields:(SZFriendsSyncFields *)fields {
    NSString *conversation = [self conversationForScope:event.scope
                                     authorConversation:[fields stringForTag:SZFSTagConversation]];
    if (conversation == nil) return SZFriendsSyncApplyWait;
    SZFriendsStore *store = self.store;
    [self noteChangedConversation:conversation];
    if ([self tombstoneCovers:event conversation:conversation]) {
        BOOL ok = [store markSyncDeletedItem:event.subject inConversation:conversation fileKind:SZFriendsSyncKindFile
                                  outboxKind:SZFriendsSyncKindOutbox error:NULL] &&
                  [store dropBodyOfSyncEvent:event.author seq:event.seq error:NULL];
        return ok ? SZFriendsSyncApplyDone : SZFriendsSyncApplyFailed;
    }
    if ([store isSyncDeletedItem:event.subject inConversation:conversation]) {
        // Another copy of something already erased: its text goes from this log too.
        return [store dropBodyOfSyncEvent:event.author seq:event.seq error:NULL] ? SZFriendsSyncApplyDone
                                                                                : SZFriendsSyncApplyFailed;
    }
    SZFriendsItemRecord *item = SZFriendsSyncItemFromBody(fields, event.subject);
    if (item == nil) return SZFriendsSyncApplyDone;
    item.conversationID = conversation;
    return [store mergeSyncedItem:item author:event.author seq:event.seq error:NULL] ? SZFriendsSyncApplyDone
                                                                                    : SZFriendsSyncApplyFailed;
}

- (SZFriendsSyncApplyResult)applyRead:(SZFriendsSyncEvent *)event fields:(SZFriendsSyncFields *)fields {
    NSString *conversation = [self conversationForScope:event.scope
                                     authorConversation:[fields stringForTag:SZFSTagConversation]];
    if (conversation == nil) return SZFriendsSyncApplyWait;
    NSDate *receivedAt = [fields dateForTag:2];
    NSString *itemID = [fields stringForTag:3];
    if (receivedAt == nil || itemID.length == 0) return SZFriendsSyncApplyDone;
    NSString *key = SZFriendsSyncReadKey(conversation);
    SZFriendsSyncRegister *current = [self.store syncRegisterForKey:key];
    SZFriendsSyncFields *held = current.value ? [SZFriendsSyncFields fieldsWithData:current.value] : nil;
    NSDate *heldAt = [held dateForTag:2];
    NSString *heldID = [held stringForTag:3] ?: @"";
    // The maximum: a marker never moves back, whichever device read first.
    if (heldAt != nil) {
        NSComparisonResult order = [receivedAt compare:heldAt];
        if (order == NSOrderedAscending || (order == NSOrderedSame && [itemID compare:heldID] != NSOrderedDescending)) {
            return SZFriendsSyncApplyDone;
        }
    }
    [self noteChangedConversation:conversation];
    return [self setRegister:key event:event value:SZFriendsSyncReadBody(conversation, receivedAt, itemID)];
}

- (void)recountUnreadInConversation:(NSString *)conversationID {
    SZFriendsSyncRegister *marker = [self.store syncRegisterForKey:SZFriendsSyncReadKey(conversationID)];
    SZFriendsSyncFields *fields = marker.value ? [SZFriendsSyncFields fieldsWithData:marker.value] : nil;
    [self.store recountUnreadInConversation:conversationID readThroughDate:[fields dateForTag:2]
                                     itemID:[fields stringForTag:3] error:NULL];
}

#pragma mark - Outbox and files

- (SZFriendsSyncApplyResult)applyOutbox:(SZFriendsSyncEvent *)event fields:(SZFriendsSyncFields *)fields {
    NSString *conversation = [self conversationForScope:event.scope
                                     authorConversation:[fields stringForTag:SZFSTagConversation]];
    if (conversation == nil) return SZFriendsSyncApplyWait;
    SZFriendsOutboxEntry *entry = SZFriendsSyncOutboxFromBody(fields, event.subject);
    if (entry == nil) return SZFriendsSyncApplyDone;
    entry.conversationID = conversation;
    SZFriendsStore *store = self.store;
    if (entry.itemID != nil) {
        if ([store isSyncDeletedItem:entry.itemID inConversation:conversation]) return SZFriendsSyncApplyDone;
        // The message it delivers comes first: a sibling builds the frame from it.
        if ([store itemWithID:entry.itemID inConversation:conversation] == nil) return SZFriendsSyncApplyWait;
    }
    NSString *key = [@"o/" stringByAppendingString:event.subject];
    SZFriendsSyncRegister *current = [store syncRegisterForKey:key];
    SZFriendsSyncFields *held = current.value ? [SZFriendsSyncFields fieldsWithData:current.value] : nil;
    BOOL heldDelivered = held != nil && [held uint64ForTag:3] == SZFriendsOutboxStateDelivered;
    BOOL delivered = entry.state == SZFriendsOutboxStateDelivered;
    // Delivered is final: whoever delivered it, every device shows it delivered and none sends it again.
    BOOL later = SZFriendsSyncIsLater(event.lamport, event.author, current);
    BOOL wins = delivered ? !heldDelivered : (!heldDelivered && later);
    if (!wins) return SZFriendsSyncApplyDone;
    if (![store mergeSyncedOutboxEntry:entry error:NULL]) return SZFriendsSyncApplyWait;
    [self noteChangedConversation:conversation];
    return [self setRegister:key event:event value:SZFriendsSyncOutboxBody(entry)];
}

- (SZFriendsSyncApplyResult)applyFile:(SZFriendsSyncEvent *)event fields:(SZFriendsSyncFields *)fields {
    NSString *conversation = [self conversationForScope:event.scope
                                     authorConversation:[fields stringForTag:SZFSTagConversation]];
    if (conversation == nil) return SZFriendsSyncApplyWait;
    SZFriendsSyncFileRecord *file = SZFriendsSyncFileFromBody(fields, event.subject);
    if (file == nil) return SZFriendsSyncApplyDone;
    file.conversationID = conversation;
    SZFriendsStore *store = self.store;
    if (file.itemID != nil && [store isSyncDeletedItem:file.itemID inConversation:conversation]) {
        return [store dropBodyOfSyncEvent:event.author seq:event.seq error:NULL] ? SZFriendsSyncApplyDone
                                                                                : SZFriendsSyncApplyFailed;
    }
    NSString *key = [@"f/" stringByAppendingString:event.subject];
    SZFriendsSyncRegister *current = [store syncRegisterForKey:key];
    SZFriendsSyncFields *held = current.value ? [SZFriendsSyncFields fieldsWithData:current.value] : nil;
    BOOL heldFinal = held != nil && SZFriendsSyncFileStateIsFinal((SZFriendsTransferState)[held uint64ForTag:4]);
    BOOL final = SZFriendsSyncFileStateIsFinal(file.state);
    BOOL wins = final != heldFinal ? final : SZFriendsSyncIsLater(event.lamport, event.author, current);
    if (held != nil && !wins) return SZFriendsSyncApplyDone;
    file.holders = [store syncFileWithID:file.transferID].holders ?: @[];
    if (![store saveSyncFile:file error:NULL]) return SZFriendsSyncApplyFailed;
    // A copy of a file another of our devices is sending follows that device's record (delivered, cancelled...).
    [store setState:file.state ofCopiedTransfer:file.transferID error:NULL];
    [self noteChangedConversation:conversation];
    return [self setRegister:key event:event value:SZFriendsSyncFileBody(file)];
}

// Each author's FILE HELD events apply in its order, so its last one decides whether it is listed (ADR 0016).
- (SZFriendsSyncApplyResult)applyFileHeld:(SZFriendsSyncEvent *)event released:(BOOL)released {
    SZFriendsSyncFileRecord *file = [self.store syncFileWithID:event.subject];
    if (file == nil) {
        // Deleted with its item, or its record has not arrived yet.
        BOOL deleted = [self.store hasBodilessSyncEventOfKind:SZFriendsSyncKindFile subject:event.subject];
        return deleted ? SZFriendsSyncApplyDone : SZFriendsSyncApplyWait;
    }
    BOOL listed = [file.holders containsObject:event.author];
    if (listed != released) return SZFriendsSyncApplyDone;
    NSMutableArray<NSData *> *holders = [file.holders mutableCopy];
    if (released) [holders removeObject:event.author];
    else [holders addObject:event.author];
    file.holders = holders;
    if (![self.store saveSyncFile:file error:NULL]) return SZFriendsSyncApplyFailed;
    [self noteChangedConversation:file.conversationID];
    return SZFriendsSyncApplyDone;
}

#pragma mark - Deletions

- (NSArray<NSArray *> *)loadedTombstones {
    if (self.tombstones != nil) return self.tombstones;
    NSMutableArray<NSArray *> *tombstones = [NSMutableArray array];
    for (SZFriendsSyncLogEvent *log in [self.store syncEventsOfKind:SZFriendsSyncKindTombstone]) {
        SZFriendsSyncFields *fields = log.body ? [SZFriendsSyncFields fieldsWithData:log.body] : nil;
        NSData *encoded = [fields dataForTag:2];
        SZFriendsSyncVector *vector = encoded ? SZFriendsSyncDecodeVector(encoded, NULL) : nil;
        if (vector == nil) continue;
        [tombstones addObject:@[ log.scope, [fields stringForTag:SZFSTagConversation] ?: @"", vector, @(log.lamport) ]];
    }
    self.tombstones = tombstones;
    return tombstones;
}

- (BOOL)tombstoneCovers:(SZFriendsSyncEvent *)event conversation:(NSString *)conversationID {
    for (NSArray *tombstone in [self loadedTombstones]) {
        SZFriendsSyncVector *vector = tombstone[2];
        // Only what its device could have seen: events older than the tombstone by clock.
        if (!SZFriendsSyncVectorCovers(vector, event.author, event.seq) ||
            event.lamport >= [tombstone[3] unsignedLongLongValue]) {
            continue;
        }
        NSString *scope = tombstone[0];
        if (scope.length == 0) return YES; // all history
        NSString *named = [tombstone[1] length] > 0 ? tombstone[1] : nil;
        if ([[self conversationForScope:scope authorConversation:named] isEqualToString:conversationID]) return YES;
    }
    return NO;
}

// What a tombstone may take of the events held here: for each author, the events it names that are older than the
// tombstone by clock, which its device could have seen. A vector naming more (a device's future messages) is cut back;
// events arriving later are judged one by one (-tombstoneCovers:conversation:).
- (SZFriendsSyncVector *)vectorSeenBy:(SZFriendsSyncEvent *)tombstone claimed:(SZFriendsSyncVector *)claimed {
    SZFriendsSyncVector *held = [self.store syncVector];
    NSMutableDictionary<NSData *, NSNumber *> *seen = [NSMutableDictionary dictionary];
    for (NSData *author in claimed) {
        // An author's clocks rise with its sequence numbers, so the events seen are a prefix: the longest one whose
        // last event is older than the tombstone.
        uint64_t low = 0, high = MIN([claimed[author] unsignedLongLongValue], [held[author] unsignedLongLongValue]);
        while (low < high) {
            uint64_t middle = low + (high - low + 1) / 2;
            SZFriendsSyncLogEvent *log = [self.store syncEventWithAuthor:author seq:middle];
            if (log != nil && log.lamport < tombstone.lamport) low = middle;
            else high = middle - 1;
        }
        if (low > 0) seen[author] = @(low);
    }
    return seen;
}

- (BOOL)applyTombstone:(SZFriendsSyncEvent *)event {
    self.tombstones = nil;
    SZFriendsSyncFields *fields = event.body ? [SZFriendsSyncFields fieldsWithData:event.body] : nil;
    NSData *encoded = [fields dataForTag:2];
    SZFriendsSyncVector *vector = encoded ? SZFriendsSyncDecodeVector(encoded, NULL) : nil;
    if (vector == nil) return YES; // nothing it could cover
    vector = [self vectorSeenBy:event claimed:vector];
    NSString *conversation = nil;
    if (event.scope.length > 0) {
        conversation = [self conversationForScope:event.scope
                               authorConversation:[fields stringForTag:SZFSTagConversation]];
        // Nobody here to delete from yet: whatever of theirs arrives later is checked against it.
        if (conversation == nil) return YES;
    }
    NSArray<NSString *> *touched = [self.store deleteSyncedItemsInConversation:conversation
                                                                     coveredBy:vector
                                                                      fileKind:SZFriendsSyncKindFile
                                                                    outboxKind:SZFriendsSyncKindOutbox
                                                                         error:NULL];
    if (touched == nil) return NO;
    for (NSString *conversationID in touched) {
        [self noteChangedConversation:conversationID];
        [self recountUnreadInConversation:conversationID];
    }
    if (conversation != nil) [self noteChangedConversation:conversation];
    return YES;
}

@end

NS_ASSUME_NONNULL_END
