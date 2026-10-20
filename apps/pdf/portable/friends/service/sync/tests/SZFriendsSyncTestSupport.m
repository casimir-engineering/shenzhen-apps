// friends-sync-check: helpers and the suite's entry point.

#import "SZFriendsSyncTestSupport.h"

#import "avatars/SZFriendsAvatars.h"

int SZFSFailures = 0;
static NSString *SZFSRoot = nil;

NSString *SZFSTemporaryDirectory(NSString *label) {
    if (SZFSRoot == nil) {
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfriends-sync-tests.XXXXXX"];
        char *template = strdup(pattern.fileSystemRepresentation);
        char *made = template ? mkdtemp(template) : NULL;
        if (made == NULL) abort();
        SZFSRoot = [NSString stringWithUTF8String:made];
        free(template);
    }
    NSString *path = [SZFSRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", label,
                                                                      NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    return path;
}

void SZFSRemoveTemporaryRoot(void) {
    if (SZFSRoot) [NSFileManager.defaultManager removeItemAtPath:SZFSRoot error:NULL];
}

SZFriendsIdentity *SZFSIdentity(uint8_t seed) {
    NSMutableData *signing = [NSMutableData dataWithLength:32], *key = [NSMutableData dataWithLength:32];
    memset(signing.mutableBytes, seed, 32);
    memset(key.mutableBytes, seed ^ 0x5a, 32);
    return [SZFriendsIdentity identityWithSigningSeed:signing staticPrivateKey:key];
}

@implementation SZFSDevice
@end

static SZFSDevice *SZFSMakeDevice(NSString *label, NSString *name, uint8_t seed) {
    SZFSDevice *device = [[SZFSDevice alloc] init];
    device.name = name;
    device.identity = SZFSIdentity(seed);
    device.directory = SZFSTemporaryDirectory([NSString stringWithFormat:@"%@-%@", label, name]);
    device.store = [SZFriendsStore storeInDirectory:device.directory error:NULL];
    if (device.store == nil) abort();
    device.engine = [[SZFriendsSyncEngine alloc]
        initWithStore:device.store
             identity:device.identity
    receivedDirectory:[device.directory stringByAppendingPathComponent:@"received"]];
    // Tests stamp events with a fixed clock: nothing may depend on it but the order of renames.
    device.engine.clock = ^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1760400000]; };
    return device;
}

SZFSDevice *SZFSLoneDevice(NSString *label, uint8_t seed) {
    SZFSDevice *device = SZFSMakeDevice(label, @"lone", seed);
    [device.store ownDeviceChainCreatingGenesisWithIdentity:device.identity error:NULL];
    return device;
}

NSArray<SZFSDevice *> *SZFSDevices(NSString *label, NSUInteger count) {
    NSArray<NSString *> *names = @[ @"A", @"B", @"C" ];
    NSMutableArray<SZFSDevice *> *devices = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) [devices addObject:SZFSMakeDevice(label, names[i], (uint8_t)(0x41 + i))];
    SZFSDevice *first = devices[0];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1760400000];
    SZFriendsDeviceChain *chain = [first.store ownDeviceChainCreatingGenesisWithIdentity:first.identity error:NULL];
    for (NSUInteger i = 1; i < count; i++) {
        SZFriendsIdentity *joining = devices[i].identity;
        chain = [chain chainByAddingDeviceKey:joining.publicKey
                                    staticKey:joining.staticPublicKey
                                      consent:SZFriendsDeviceConsent(joining, chain.rootKey)
                                         name:[NSString stringWithFormat:@"Mac %@", names[i]]
                                       system:@"macOS 26.1"
                                     signedBy:first.identity
                                         date:date
                                        error:NULL];
    }
    if (chain == nil || [first.store mergeOwnDeviceChain:chain error:NULL] == SZFriendsChainMergeRefused) abort();
    for (NSUInteger i = 1; i < count; i++) {
        if (![devices[i].store adoptOwnDeviceChain:chain localDeviceKey:devices[i].identity.publicKey error:NULL]) {
            abort();
        }
    }
    return devices;
}

BOOL SZFSDeliverSome(SZFSDevice *from, SZFSDevice *to, NSUInteger limit) {
    NSArray<SZFriendsSyncEvent *> *events = [from.engine eventsMissingFrom:[to.engine vector] limit:limit];
    if (events.count == 0) return YES;
    NSError *error = nil;
    BOOL ok = [to.engine receiveEvents:events error:&error];
    if (!ok) fprintf(stderr, "delivery %s -> %s: %s\n", from.name.UTF8String, to.name.UTF8String,
                     error.localizedDescription.UTF8String);
    return ok;
}

BOOL SZFSDeliver(SZFSDevice *from, SZFSDevice *to) {
    return SZFSDeliverSome(from, to, NSUIntegerMax);
}

void SZFSSyncAll(NSArray<SZFSDevice *> *devices) {
    for (int round = 0; round < 6; round++) {
        for (SZFSDevice *device in devices) [device.engine captureLocalChanges];
        for (SZFSDevice *from in devices) {
            for (SZFSDevice *to in devices) {
                if (from != to) SZFSDeliver(from, to);
            }
        }
    }
}

SZFriendsPersonRecord *SZFSAddFriend(SZFSDevice *device, uint8_t keyByte, NSString *_Nullable conversationID) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = conversationID ?: @"";
    NSMutableData *key = [NSMutableData dataWithLength:32], *staticKey = [NSMutableData dataWithLength:32];
    memset(key.mutableBytes, keyByte, 32);
    memset(staticKey.mutableBytes, keyByte ^ 0x33, 32);
    person.identityKey = key;
    person.staticKey = staticKey;
    person.name = [NSString stringWithFormat:@"Friend %d", keyByte];
    person.picture = [SZFriendsPicture animalWithSet:1 index:keyByte % 20];
    person.relation = SZFriendsRelationFriend;
    person.lastInteractionAt = [NSDate dateWithTimeIntervalSince1970:1760000000];
    if (![device.store savePerson:person error:NULL]) abort();
    return person;
}

SZFriendsItemRecord *SZFSInsertMessage(SZFSDevice *device, NSString *conversationID, NSString *itemID, NSString *text,
                                       SZFriendsDirection direction, NSTimeInterval at) {
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = itemID;
    item.conversationID = conversationID;
    item.kind = SZFriendsItemKindMessage;
    item.direction = direction;
    item.text = text;
    item.sentAt = [NSDate dateWithTimeIntervalSince1970:at];
    item.receivedAt = [NSDate dateWithTimeIntervalSince1970:at + 0.25];
    if (![device.store insertItem:item error:NULL]) abort();
    return item;
}

NSString *_Nullable SZFSConversation(SZFSDevice *device, uint8_t keyByte) {
    NSMutableData *key = [NSMutableData dataWithLength:32];
    memset(key.mutableBytes, keyByte, 32);
    return [device.store syncPersonWithIdentityKey:key].conversationID;
}

static NSString *SZFSHexOrDash(NSData *_Nullable data) {
    return data ? SZFriendsSyncHex(data) : @"-";
}

NSString *SZFSDump(SZFSDevice *device) {
    SZFriendsStore *store = device.store;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    SZFriendsPicture *own = store.profilePicture;
    [lines addObject:[NSString stringWithFormat:@"profile %@ %@ %ld pic %ld/%ld/%ld presence %@ devices %@",
                                                store.profileName ?: @"-", store.friendsID ?: @"-",
                                                (long)store.friendsIDState, (long)own.kind, (long)own.animalSet,
                                                (long)own.animalIndex, SZFSHexOrDash(store.ownPresenceSecret),
                                                SZFSHexOrDash([device.engine ownDevicesSecret])]];
    NSMutableDictionary<NSString *, NSString *> *refs = [NSMutableDictionary dictionary];
    for (SZFriendsPersonRecord *person in [store peopleByLatestInteraction]) {
        NSString *ref = SZFriendsSyncRefForPerson(person);
        refs[person.conversationID] = ref;
        [lines addObject:[NSString stringWithFormat:
            @"person %@ rel %ld name %@ id %@ pic %ld/%ld/%ld static %@ presence %@ verified %d code %@ auto %d "
            @"unread %ld left %.3f", ref, (long)person.relation, person.name ?: @"-", person.friendsID ?: @"-",
            (long)person.picture.kind, (long)person.picture.animalSet, (long)person.picture.animalIndex,
            SZFSHexOrDash(person.staticKey), SZFSHexOrDash(person.presenceSecret), person.verified,
            person.comparisonCode ?: @"-", person.autoAccept, (long)person.unreadCount,
            person.leftListAt.timeIntervalSince1970]];
        for (SZFriendsItemRecord *item in [store itemsInConversation:person.conversationID beforeItemID:nil
                                                                limit:100000 hasEarlier:NULL]) {
            [lines addObject:[NSString stringWithFormat:@"item %@ %@ kind %ld dir %ld sent %.6f recv %.6f %@ %@ %@",
                                                        ref, item.itemID, (long)item.kind, (long)item.direction,
                                                        item.sentAt.timeIntervalSince1970,
                                                        item.receivedAt.timeIntervalSince1970, item.text ?: @"-",
                                                        item.transferID ?: @"-", item.eventKind ?: @"-"]];
        }
    }
    for (SZFriendsOutboxEntry *entry in [store syncableOutboxEntries]) {
        [lines addObject:[NSString stringWithFormat:@"outbox %@ %@ kind %ld state %ld item %@ %@", entry.entryID,
                                                    refs[entry.conversationID] ?: @"?", (long)entry.kind,
                                                    (long)SZFriendsSyncOutboxFoldedState(entry.state),
                                                    entry.itemID ?: @"-", entry.failureReason ?: @"-"]];
    }
    for (SZFriendsSyncFileRecord *file in [store syncFiles]) {
        NSMutableArray<NSString *> *holders = [NSMutableArray array];
        for (NSData *holder in file.holders) [holders addObject:[SZFriendsSyncHex(holder) substringToIndex:8]];
        [lines addObject:[NSString stringWithFormat:@"file %@ %@ item %@ state %ld %@ %llu holders %@",
                                                    file.transferID, refs[file.conversationID] ?: @"?",
                                                    file.itemID ?: @"-", (long)file.state, file.fileName,
                                                    file.size, [holders componentsJoinedByString:@","]]];
    }
    [lines sortUsingSelector:@selector(compare:)];
    return [lines componentsJoinedByString:@"\n"];
}

int main(void) {
    @autoreleasepool {
        SZFSRunCodecTests();
        SZFSRunEngineTests();
        SZFSRunDeletionTests();
        SZFSRunOutboxFileTests();
        SZFSRunExchangeTests();
        SZFSRunRevocationTests();
        SZFSRunReleaseTests();
        SZFSRunPropertyTests();
        SZFSRemoveTemporaryRoot();
        if (SZFSFailures > 0) {
            fprintf(stderr, "SZFriendsSyncTests: %d failure(s)\n", SZFSFailures);
            return 1;
        }
        printf("SZFriendsSyncTests passed\n");
    }
    return 0;
}
