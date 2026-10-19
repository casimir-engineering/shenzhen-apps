// friends-sync-check: property tests. Three devices of one person, apart most of the time, each changing things on its
// own (friends met separately, the same message delivered to several devices, reads, renames, blocks, profile edits,
// outbox deliveries and failures, chats erased), exchanging random prefixes of each other's logs in random orders,
// some twice. Once everyone has heard everyone, every device's store is the same, whatever the order; an erased
// message never comes back; and a second round of full exchanges changes nothing.

#import "SZFriendsSyncTestSupport.h"

#import "avatars/SZFriendsAvatars.h"

static const int SZFSPropertyRuns = 40;
static const int SZFSPropertySteps = 100;

typedef struct {
    uint64_t state;
} SZFSRandom;

static uint32_t SZFSNext(SZFSRandom *random, uint32_t bound) {
    random->state ^= random->state << 13;
    random->state ^= random->state >> 7;
    random->state ^= random->state << 17;
    return (uint32_t)(random->state % bound);
}

// One step on one device. `clock` only moves forward, as arrival times do; `erased` collects every message id a
// deletion took on the device that made it.
static void SZFSStep(NSArray<SZFSDevice *> *devices, SZFSRandom *random, NSTimeInterval *clock, int run,
                     NSMutableSet<NSString *> *erased) {
    uint32_t count = (uint32_t)devices.count;
    SZFSDevice *device = devices[SZFSNext(random, count)];
    uint8_t friendKey = (uint8_t)(0x90 + SZFSNext(random, 3));
    NSString *conversation = SZFSConversation(device, friendKey);
    SZFriendsStore *store = device.store;
    *clock += 1;
    switch (SZFSNext(random, 12)) {
    case 0:
    case 1: // meet a friend here (perhaps a second time, on another device, under another conversation id)
        if (conversation == nil) {
            SZFSAddFriend(device, friendKey, [NSString stringWithFormat:@"r%d%@%u", run, device.name,
                                                                          SZFSNext(random, 1000000)]);
        }
        break;
    case 2:
    case 3: { // the friend delivers a message here; ids repeat, as a delivery to several devices does
        if (conversation == nil) break;
        NSString *itemID = [NSString stringWithFormat:@"m%02x%u", friendKey, SZFSNext(random, 30)];
        SZFSInsertMessage(device, conversation, itemID, [@"text " stringByAppendingString:itemID],
                          SZFriendsDirectionIncoming, *clock);
        break;
    }
    case 4: { // we write one here
        if (conversation == nil) break;
        SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
        item.itemID = [NSString stringWithFormat:@"o%@%u", device.name, SZFSNext(random, 1000000)];
        item.conversationID = conversation;
        item.kind = SZFriendsItemKindMessage;
        item.direction = SZFriendsDirectionOutgoing;
        item.text = @"ours";
        item.sentAt = item.receivedAt = [NSDate dateWithTimeIntervalSince1970:*clock];
        SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
        entry.entryID = [item.itemID stringByAppendingString:@"e"];
        entry.conversationID = conversation;
        entry.kind = SZFriendsOutboxKindMessage;
        entry.itemID = item.itemID;
        entry.createdAt = item.sentAt;
        [[[SZFriendsOutbox alloc] initWithStore:store] enqueue:entry item:item error:NULL];
        break;
    }
    case 5:
        if (conversation) [store markConversationRead:conversation error:NULL];
        break;
    case 6: { // rename, block, remove, befriend again
        SZFriendsPersonRecord *person = conversation ? [store personWithConversationID:conversation] : nil;
        if (person == nil) break;
        if (SZFSNext(random, 2)) person.name = [NSString stringWithFormat:@"name %u", SZFSNext(random, 100)];
        else {
            SZFriendsRelation relations[] = {SZFriendsRelationFriend, SZFriendsRelationBlocked,
                                             SZFriendsRelationRemoved};
            person.relation = relations[SZFSNext(random, 3)];
        }
        if (SZFSNext(random, 3) == 0) person.autoAccept = !person.autoAccept;
        [store savePerson:person error:NULL];
        break;
    }
    case 7:
        store.profileName = [NSString stringWithFormat:@"me %u", SZFSNext(random, 100)];
        if (SZFSNext(random, 2)) store.profilePicture = [SZFriendsPicture animalWithSet:1 index:SZFSNext(random, 20)];
        break;
    case 8: { // erase a chat (or, rarely, everything)
        if (SZFSNext(random, 3) != 0) break;
        NSString *target = SZFSNext(random, 4) == 0 ? nil : conversation;
        if (target == nil && SZFSNext(random, 2)) break;
        [device.engine captureLocalChanges];
        for (SZFriendsPersonRecord *person in [store peopleByLatestInteraction]) {
            if (target && ![person.conversationID isEqualToString:target]) continue;
            for (SZFriendsItemRecord *item in [store itemsInConversation:person.conversationID beforeItemID:nil
                                                                    limit:100000 hasEarlier:NULL]) {
                [erased addObject:[NSString stringWithFormat:@"%@|%@", SZFriendsSyncRefForPerson(person), item.itemID]];
            }
        }
        [device.engine deleteHistoryInConversation:target error:NULL];
        break;
    }
    case 9: { // an entry delivered here, or given up on
        NSArray<SZFriendsOutboxEntry *> *entries = [store syncableOutboxEntries];
        if (entries.count == 0) break;
        SZFriendsOutboxEntry *entry = entries[SZFSNext(random, (uint32_t)entries.count)];
        SZFriendsOutboxEvent event =
            SZFSNext(random, 2) ? SZFriendsOutboxEventAcknowledged : SZFriendsOutboxEventExpired;
        [[[SZFriendsOutbox alloc] initWithStore:store] applyEvent:event toEntry:entry.entryID error:NULL];
        break;
    }
    case 10:
        [device.engine captureLocalChanges];
        break;
    default: { // some of what one device has reaches another, perhaps twice
        SZFSDevice *to = devices[SZFSNext(random, count)];
        if (to == device) break;
        [device.engine captureLocalChanges];
        NSUInteger limit = 1 + SZFSNext(random, 12);
        SZFSDeliverSome(device, to, limit);
        if (SZFSNext(random, 4) == 0) {
            [to.engine receiveEvents:[device.engine eventsMissingFrom:@{} limit:limit] error:NULL];
        }
        break;
    }
    }
}

static void TestConvergence(int run) {
    NSArray<SZFSDevice *> *devices = SZFSDevices([NSString stringWithFormat:@"prop%d", run], 3);
    SZFSRandom random = {.state = 0x9E3779B97F4A7C15ull ^ ((uint64_t)run * 0x100000001B3ull)};
    NSTimeInterval clock = 1000;
    NSMutableSet<NSString *> *erased = [NSMutableSet set];
    for (int step = 0; step < SZFSPropertySteps; step++) SZFSStep(devices, &random, &clock, run, erased);
    SZFSSyncAll(devices);
    NSString *a = SZFSDump(devices[0]), *b = SZFSDump(devices[1]), *c = SZFSDump(devices[2]);
    SZFSExpect([a isEqualToString:b] && [a isEqualToString:c], @"run %d converged:\n%@\n--- B\n%@\n--- C\n%@", run, a,
               b, c);
    for (SZFSDevice *device in devices) {
        SZFSExpect([device.store unappliedSyncEvents].count == 0, @"run %d: nothing waits on %@", run, device.name);
        for (SZFriendsPersonRecord *person in [device.store peopleByLatestInteraction]) {
            for (SZFriendsItemRecord *item in [device.store itemsInConversation:person.conversationID beforeItemID:nil
                                                                         limit:100000 hasEarlier:NULL]) {
                NSString *key = [NSString stringWithFormat:@"%@|%@", SZFriendsSyncRefForPerson(person), item.itemID];
                // Erased ids may be delivered again later by the friend only as new deliveries erased too.
                SZFSExpect(![erased containsObject:key], @"run %d: %@ came back on %@", run, key, device.name);
            }
        }
    }
    // Quiescent: more rounds move nothing.
    NSUInteger events = [devices[0].store syncEventCount];
    SZFSSyncAll(devices);
    SZFSExpect([devices[0].store syncEventCount] == events && [SZFSDump(devices[0]) isEqualToString:a],
               @"run %d: a converged store stays put", run);
}

// The same history heard in opposite orders gives the same store: the merge does not depend on which device's events
// come first. A and B make the history; two separate copies of C (in two separate worlds) hear it.
static void TestOrderIndependence(void) {
    NSArray<SZFSDevice *> *devices = SZFSDevices(@"order", 3);
    NSArray<SZFSDevice *> *makers = @[ devices[0], devices[1] ];
    SZFSRandom random = {.state = 0xC0FFEEull};
    NSTimeInterval clock = 1000;
    NSMutableSet<NSString *> *erased = [NSMutableSet set];
    for (int step = 0; step < SZFSPropertySteps; step++) SZFSStep(makers, &random, &clock, 99, erased);
    for (SZFSDevice *device in makers) [device.engine captureLocalChanges];
    SZFSDevice *forward = SZFSDevices(@"order-forward", 3)[2], *backward = SZFSDevices(@"order-backward", 3)[2];
    SZFSDeliver(devices[0], forward);
    SZFSDeliver(devices[1], forward);
    SZFSDeliver(devices[1], backward);
    SZFSDeliver(devices[0], backward);
    SZFSExpect([SZFSDump(forward) isEqualToString:SZFSDump(backward)], @"order matters:\n%@\n---\n%@",
               SZFSDump(forward), SZFSDump(backward));
}

void SZFSRunPropertyTests(void) {
    for (int run = 0; run < SZFSPropertyRuns; run++) TestConvergence(run);
    TestOrderIndependence();
}
