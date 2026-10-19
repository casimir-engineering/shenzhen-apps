// Capture: what changed in the store since the last look becomes events of ours (SZFriendsSync.h). Each kind of value
// is compared with the register sync keeps for it, so a value another device's event wrote is not sent back, and a
// change made while sync was off (or before a crash) is found the next time. History items are found by having no
// origin yet, oldest first, in batches.

#import <sodium.h>

#import "avatars/SZFriendsAvatars.h"
#import "service/sync/SZFriendsSyncInternal.h"

NS_ASSUME_NONNULL_BEGIN

// History items turned into events per transaction.
static const NSUInteger SZFriendsSyncCaptureBatch = 400;

// One event to record, the register it updates and the item it is an origin of.
@interface SZFriendsSyncPendingEvent : NSObject
@property(nonatomic) SZFriendsSyncKind kind;
@property(nonatomic, copy) NSString *scope;
@property(nonatomic, copy) NSString *subject;
@property(nonatomic, copy) NSData *body;
@property(nonatomic, copy, nullable) NSString *registerKey;
@property(nonatomic, copy, nullable) NSData *registerValue;
@property(nonatomic, copy, nullable) NSString *originConversation;
@property(nonatomic, copy, nullable) SZFriendsSyncFileRecord *file; // saved with the event (holders included)
@end

@implementation SZFriendsSyncPendingEvent
@end

static SZFriendsSyncPendingEvent *SZFriendsSyncPending(SZFriendsSyncKind kind, NSString *scope, NSString *subject,
                                                       NSData *body) {
    SZFriendsSyncPendingEvent *pending = [[SZFriendsSyncPendingEvent alloc] init];
    pending.kind = kind;
    pending.scope = scope;
    pending.subject = subject;
    pending.body = body;
    return pending;
}

static BOOL SZFriendsSyncSameValue(SZFriendsSyncRegister *_Nullable current, NSData *value) {
    return current.value != nil && [current.value isEqualToData:value];
}

@implementation SZFriendsSyncEngine (Capture)

- (NSUInteger)captureChanges {
    NSUInteger count = [self commitPending:[self pendingProfileWide]];
    NSMutableDictionary<NSString *, SZFriendsPersonRecord *> *people = [NSMutableDictionary dictionary];
    NSMutableArray<SZFriendsSyncPendingEvent *> *pending = [NSMutableArray array];
    // One read per kind of register, not one per value.
    NSDictionary<NSString *, SZFriendsSyncRegister *> *registers = [self.store syncRegistersWithPrefix:@"p/"];
    for (SZFriendsPersonRecord *person in [self.store peopleByLatestInteraction]) {
        people[person.conversationID] = person;
        if ([person.conversationID isEqualToString:SZFriendsYouConversationID]) continue;
        [self addPersonChanges:person registers:registers to:pending];
    }
    count += [self commitPending:pending];
    count += [self captureItemsWithPeople:people];
    pending = [NSMutableArray array];
    [self addFileChangesWithPeople:people to:pending];
    [self addOutboxChangesWithPeople:people to:pending];
    [self addReadChangesWithPeople:people to:pending];
    count += [self commitPending:pending];
    return count;
}

#pragma mark - Recording

- (NSUInteger)commitPending:(NSArray<SZFriendsSyncPendingEvent *> *)pending {
    // A value too large for one event (an outbox entry's payload past SZFriendsSyncBodyMax) stays on this device
    // rather than holding back everything recorded with it.
    NSMutableArray<SZFriendsSyncPendingEvent *> *fitting = [NSMutableArray array];
    for (SZFriendsSyncPendingEvent *item in pending) {
        if (item.body.length <= SZFriendsSyncBodyMax) [fitting addObject:item];
    }
    pending = fitting;
    if (pending.count == 0) return 0;
    BOOL ok = [self.store performSyncTransaction:^BOOL(NSError **error) {
        for (SZFriendsSyncPendingEvent *item in pending) {
            SZFriendsSyncEvent *event = [self recordKind:item.kind scope:item.scope subject:item.subject body:item.body
                                                   error:error];
            if (event == nil) return NO;
            if (item.registerKey != nil) {
                SZFriendsSyncRegister *value = [[SZFriendsSyncRegister alloc] init];
                value.lamport = event.lamport;
                value.author = event.author;
                value.value = item.registerValue;
                if (![self.store setSyncRegister:value forKey:item.registerKey error:error]) return NO;
            }
            if (item.originConversation != nil &&
                ![self.store addSyncOriginForItem:item.subject inConversation:item.originConversation
                                           author:event.author seq:event.seq error:error]) {
                return NO;
            }
            if (item.file != nil && ![self.store saveSyncFile:item.file error:error]) return NO;
        }
        return YES;
    } error:NULL];
    if (!ok) {
        [self resetCounters]; // a rolled-back batch leaves the counters ahead of the log
        return 0;
    }
    return pending.count;
}

#pragma mark - Profile, settings, chain

- (NSArray<SZFriendsSyncPendingEvent *> *)pendingProfileWide {
    NSMutableArray<SZFriendsSyncPendingEvent *> *pending = [NSMutableArray array];
    SZFriendsStore *store = self.store;
    // The chain is read and checked only when the device index says it changed since the last one we recorded.
    NSData *fingerprint = [self ownChainFingerprint];
    if (!SZFriendsSyncSameValue([store syncRegisterForKey:@"chain"], fingerprint)) {
        NSData *encodedChain = store.ownDeviceChain.encodedData;
        if (encodedChain != nil && encodedChain.length + 3 <= SZFriendsSyncBodyMax) {
            SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
            [fields setData:encodedChain forTag:2];
            SZFriendsSyncPendingEvent *event =
                SZFriendsSyncPending(SZFriendsSyncKindChain, @"", @"", fields.encodedData);
            event.registerKey = @"chain";
            event.registerValue = fingerprint;
            [pending addObject:event];
        }
    }
    NSData *profile = SZFriendsSyncProfileBody(store, NO);
    SZFriendsSyncRegister *heldProfile = [store syncRegisterForKey:@"profile"];
    // A device that just joined has an empty profile until the profile's own reaches it, and one whose only writer
    // was a removed computer's late event is empty again: neither is a change.
    BOOL empty = store.profileName == nil && store.profilePicture.kind == SZFriendsPictureKindPlaceholder;
    if (!SZFriendsSyncSameValue(heldProfile, profile) && !(heldProfile.value == nil && empty)) {
        SZFriendsSyncPendingEvent *event =
            SZFriendsSyncPending(SZFriendsSyncKindProfile, @"", @"", SZFriendsSyncProfileBody(store, YES));
        event.registerKey = @"profile";
        event.registerValue = profile;
        [pending addObject:event];
    }
    [self ensureOwnDevicesSecret];
    NSDictionary<NSString *, NSData *> *settings = @{
        SZFriendsSyncSettingPresence : store.ownPresenceSecret ?: [NSData data],
        SZFriendsSyncSettingDevices : [self ownDevicesSecret] ?: [NSData data],
        SZFriendsSyncSettingRenewed : [store syncStateForKey:SZFriendsSyncStateRenewed] ?: [NSData data],
    };
    for (NSString *name in [settings.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (settings[name].length != 32) continue;
        SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
        [fields setData:settings[name] forTag:2];
        NSString *key = [@"s/" stringByAppendingString:name];
        if (SZFriendsSyncSameValue([store syncRegisterForKey:key], fields.encodedData)) continue;
        SZFriendsSyncPendingEvent *event =
            SZFriendsSyncPending(SZFriendsSyncKindSetting, @"", name, fields.encodedData);
        event.registerKey = key;
        event.registerValue = fields.encodedData;
        [pending addObject:event];
    }
    return pending;
}

#pragma mark - People

- (void)addPersonChanges:(SZFriendsPersonRecord *)person
                registers:(NSDictionary<NSString *, SZFriendsSyncRegister *> *)registers
                       to:(NSMutableArray<SZFriendsSyncPendingEvent *> *)pending {
    NSString *scope = SZFriendsSyncRefForPerson(person);
    for (NSString *group in SZFriendsSyncPersonGroups()) {
        NSString *key = SZFriendsSyncPersonKey(person.conversationID, group);
        NSData *value = SZFriendsSyncPersonGroupBody(person, group, NO);
        if (SZFriendsSyncSameValue(registers[key], value)) continue;
        NSData *body = SZFriendsSyncPersonGroupBody(person, group, YES);
        SZFriendsSyncPendingEvent *event = SZFriendsSyncPending(SZFriendsSyncKindPerson, scope, group, body);
        event.registerKey = key;
        event.registerValue = value;
        [pending addObject:event];
    }
}

#pragma mark - History

- (NSUInteger)captureItemsWithPeople:(NSDictionary<NSString *, SZFriendsPersonRecord *> *)people {
    NSUInteger count = 0;
    int64_t row = [[self.store syncStateForKey:SZFriendsSyncCaptureRowKey] longLongValue];
    while (YES) {
        int64_t last = row;
        NSArray<SZFriendsItemRecord *> *items = [self.store itemsWithoutSyncOriginAfterRow:row
                                                                                    limit:SZFriendsSyncCaptureBatch
                                                                                  lastRow:&last];
        if (items.count == 0) break;
        NSMutableArray<SZFriendsSyncPendingEvent *> *pending = [NSMutableArray array];
        for (SZFriendsItemRecord *item in items) {
            SZFriendsPersonRecord *person = people[item.conversationID];
            if (person == nil) continue;
            SZFriendsSyncPendingEvent *event = SZFriendsSyncPending(
                SZFriendsSyncKindItem, SZFriendsSyncRefForPerson(person), item.itemID, SZFriendsSyncItemBody(item));
            event.originConversation = item.conversationID;
            [pending addObject:event];
        }
        NSUInteger recorded = [self commitPending:pending];
        if (recorded == 0 && pending.count > 0) break; // the store refused; the next capture tries again
        count += recorded;
        row = last;
        [self.store setSyncState:@(row) forKey:SZFriendsSyncCaptureRowKey error:NULL];
    }
    return count;
}

- (void)addReadChangesWithPeople:(NSDictionary<NSString *, SZFriendsPersonRecord *> *)people
                              to:(NSMutableArray<SZFriendsSyncPendingEvent *> *)pending {
    NSDictionary<NSString *, SZFriendsSyncRegister *> *registers = [self.store syncRegistersWithPrefix:@"r/"];
    for (SZFriendsPersonRecord *person in people.allValues) {
        // What is read here: everything up to the item with exactly `unread` incoming ones after it. (Reading resets
        // the count and each arrival adds one, so this holds even when something arrived before this capture ran.)
        if (person.unreadCount < 0) continue;
        SZFriendsItemRecord *newest = [self.store incomingItemInConversation:person.conversationID
                                                                 newerCount:(NSUInteger)person.unreadCount];
        if (newest == nil) continue;
        NSString *key = SZFriendsSyncReadKey(person.conversationID);
        SZFriendsSyncFields *held = nil;
        SZFriendsSyncRegister *current = registers[key];
        if (current.value) held = [SZFriendsSyncFields fieldsWithData:current.value];
        NSDate *heldAt = [held dateForTag:2];
        if (heldAt != nil) {
            NSComparisonResult order = [newest.receivedAt compare:heldAt];
            if (order == NSOrderedAscending ||
                (order == NSOrderedSame &&
                 [newest.itemID compare:[held stringForTag:3] ?: @""] != NSOrderedDescending)) {
                continue;
            }
        }
        NSData *body = SZFriendsSyncReadBody(person.conversationID, newest.receivedAt, newest.itemID);
        SZFriendsSyncPendingEvent *event =
            SZFriendsSyncPending(SZFriendsSyncKindRead, SZFriendsSyncRefForPerson(person), @"", body);
        event.registerKey = key;
        event.registerValue = body;
        [pending addObject:event];
    }
}

#pragma mark - Outbox and files

- (void)addOutboxChangesWithPeople:(NSDictionary<NSString *, SZFriendsPersonRecord *> *)people
                                to:(NSMutableArray<SZFriendsSyncPendingEvent *> *)pending {
    NSDictionary<NSString *, SZFriendsSyncRegister *> *registers = [self.store syncRegistersWithPrefix:@"o/"];
    for (SZFriendsOutboxEntry *entry in [self.store syncableOutboxEntries]) {
        SZFriendsPersonRecord *person = people[entry.conversationID];
        if (person == nil || [entry.conversationID isEqualToString:SZFriendsYouConversationID]) continue;
        NSString *key = [@"o/" stringByAppendingString:entry.entryID];
        NSData *value = SZFriendsSyncOutboxBody(entry);
        SZFriendsSyncRegister *current = registers[key];
        if (SZFriendsSyncSameValue(current, value)) continue;
        SZFriendsSyncFields *held = current.value ? [SZFriendsSyncFields fieldsWithData:current.value] : nil;
        // Delivered elsewhere is final: a local Queued copy must not say otherwise (it is about to hear it).
        if (held != nil && [held uint64ForTag:3] == SZFriendsOutboxStateDelivered &&
            entry.state != SZFriendsOutboxStateDelivered) {
            continue;
        }
        SZFriendsSyncPendingEvent *event =
            SZFriendsSyncPending(SZFriendsSyncKindOutbox, SZFriendsSyncRefForPerson(person), entry.entryID, value);
        event.registerKey = key;
        event.registerValue = value;
        [pending addObject:event];
    }
}

- (void)addFileChangesWithPeople:(NSDictionary<NSString *, SZFriendsPersonRecord *> *)people
                              to:(NSMutableArray<SZFriendsSyncPendingEvent *> *)pending {
    SZFriendsStore *store = self.store;
    NSMutableSet<NSString *> *withBytes = [NSMutableSet set];
    for (SZFriendsTransferRecord *transfer in [store transfersWithLocalBytes]) {
        [withBytes addObject:transfer.transferID];
    }
    NSData *me = self.identity.publicKey;
    NSDictionary<NSString *, SZFriendsSyncRegister *> *registers = [store syncRegistersWithPrefix:@"f/"];
    NSMutableDictionary<NSString *, SZFriendsSyncFileRecord *> *records = [NSMutableDictionary dictionary];
    for (SZFriendsSyncFileRecord *record in [store syncFiles]) records[record.transferID] = record;
    for (SZFriendsTransferRecord *transfer in [store allTransferRecords]) {
        SZFriendsPersonRecord *person = people[transfer.conversationID];
        if (person == nil) continue;
        NSString *scope = SZFriendsSyncRefForPerson(person);
        SZFriendsSyncFileRecord *known = records[transfer.transferID];
        NSString *itemID = known.itemID ?: [store itemIDForTransfer:transfer.transferID
                                                     inConversation:transfer.conversationID];
        SZFriendsSyncFileRecord *file = SZFriendsSyncFileFromTransfer(transfer, itemID);
        file.holders = known.holders ?: @[];
        NSString *key = [@"f/" stringByAppendingString:transfer.transferID];
        NSData *value = SZFriendsSyncFileBody(file);
        SZFriendsSyncRegister *current = registers[key];
        SZFriendsSyncFields *held = current.value ? [SZFriendsSyncFields fieldsWithData:current.value] : nil;
        BOOL heldFinal = held != nil && SZFriendsSyncFileStateIsFinal((SZFriendsTransferState)[held uint64ForTag:4]);
        BOOL regresses = heldFinal && !SZFriendsSyncFileStateIsFinal(file.state);
        BOOL changed = !SZFriendsSyncSameValue(current, value) && !regresses;
        BOOL holds = [withBytes containsObject:transfer.transferID] && ![file.holders containsObject:me];
        if (holds) file.holders = [file.holders arrayByAddingObject:me];
        if (changed) {
            SZFriendsSyncPendingEvent *event = SZFriendsSyncPending(SZFriendsSyncKindFile, scope, transfer.transferID,
                                                                    value);
            event.registerKey = key;
            event.registerValue = value;
            event.file = file;
            [pending addObject:event];
        }
        if (holds) {
            SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
            [fields setString:transfer.conversationID forTag:SZFSTagConversation];
            SZFriendsSyncPendingEvent *event = SZFriendsSyncPending(SZFriendsSyncKindFileHeld, scope,
                                                                    transfer.transferID, fields.encodedData);
            event.file = file;
            [pending addObject:event];
        }
    }
}

@end

NS_ASSUME_NONNULL_END
