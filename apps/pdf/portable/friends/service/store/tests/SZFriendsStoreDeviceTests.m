// Device chains in the store (schema v8, SZFriendsStoreDevices.h): the existing profile's genesis, friends' chains
// kept only from their pinned root and only ever growing, the device index behind person lookups and revocations, and
// the own chain a joining device adopts.

#import "SZFriendsStoreTestSupport.h"

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/identity/SZFriendsIdentity.h"
#import "service/store/SZFriendsStoreDevices.h"

static SZFriendsIdentity *SZFTDevice(uint8_t seed) {
    return [SZFriendsIdentity identityWithSigningSeed:SZFTBytes(seed, 32) staticPrivateKey:SZFTBytes(seed ^ 0x55, 32)];
}

static NSDate *SZFTAt(double seconds) { return [NSDate dateWithTimeIntervalSince1970:1791800000 + seconds]; }

static SZFriendsDeviceChain *SZFTGenesis(SZFriendsIdentity *root) {
    return [SZFriendsDeviceChain genesisChainWithIdentity:root name:@"iMac" system:@"macOS 26.0" date:SZFTAt(0)
                                                    error:NULL];
}

static SZFriendsDeviceChain *SZFTAdd(SZFriendsDeviceChain *chain, SZFriendsIdentity *device, SZFriendsIdentity *by) {
    return [chain chainByAddingDeviceKey:device.publicKey staticKey:device.staticPublicKey
                                 consent:SZFriendsDeviceConsent(device, chain.rootKey) name:@"MacBook Air"
                                  system:@"macOS 26.1" signedBy:by date:SZFTAt(10) error:NULL];
}

static SZFriendsPersonRecord *SZFTFriendWithRoot(SZFriendsStore *store, NSString *conversation,
                                                 SZFriendsIdentity *root) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = conversation;
    person.identityKey = root.publicKey;
    person.staticKey = root.staticPublicKey;
    person.name = conversation;
    person.relation = SZFriendsRelationFriend;
    person.lastInteractionAt = [NSDate dateWithTimeIntervalSince1970:2000];
    NSError *error = nil;
    SZFTExpect([store savePerson:person error:&error], @"save: %@", error);
    return person;
}

static void TestExistingProfileGetsItsGenesis(void) {
    NSString *directory = SZFTTemporaryDirectory(@"devices-migrate");
    SZFriendsStoreOptions *v7 = [[SZFriendsStoreOptions alloc] init];
    v7.migrations = [SZFriendsStoreShippedMigrations() subarrayWithRange:NSMakeRange(0, 7)];
    NSError *error = nil;
    SZFriendsStore *older = SZFTOpenStoreWithOptions(directory, v7, &error);
    SZFTExpect(older.schemaVersion == 7, @"a v7 store: %@", error);
    SZFTAddPerson(older, @"mei", 1, SZFriendsRelationFriend, 1000);
    [older close];
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFTExpect(store.schemaVersion >= 8 && [store personWithConversationID:@"mei"] != nil, @"v7 to v8 keeps people");
    SZFTExpect(store.ownDeviceChain == nil, @"no chain until the helper asks for one");
    SZFriendsIdentity *me = SZFTDevice(1);
    SZFriendsDeviceChain *chain = [store ownDeviceChainCreatingGenesisWithIdentity:me error:&error];
    SZFTExpect([chain.rootKey isEqualToData:me.publicKey] && chain.links.count == 1 &&
                   [[chain deviceWithKey:me.publicKey].staticKey isEqualToData:me.staticPublicKey],
               @"the existing identity becomes the root and first device: %@", error);
    SZFriendsDeviceChain *again = [store ownDeviceChainCreatingGenesisWithIdentity:me error:NULL];
    SZFTExpect([again.encodedData isEqualToData:chain.encodedData] &&
                   [store.ownDeviceChain.encodedData isEqualToData:chain.encodedData], @"the genesis is written once");
    NSArray<SZFriendsDeviceRecord *> *devices = [store devicesOfRootKey:me.publicKey];
    SZFTExpect(devices.count == 1 && devices.firstObject.isRoot && devices.firstObject.name.length > 0 &&
                   [devices.firstObject.system hasPrefix:@"macOS "], @"this Mac, named, with its system");
    [store close];
}

static void TestFriendsChains(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"devices-friends"));
    SZFriendsIdentity *root = SZFTDevice(10), *laptop = SZFTDevice(11), *other = SZFTDevice(12);
    SZFriendsPersonRecord *mei = SZFTFriendWithRoot(store, @"mei", root);
    SZFriendsDeviceChain *two = SZFTAdd(SZFTGenesis(root), laptop, root);
    NSError *error = nil;
    SZFTExpect([store personWithIdentityKey:laptop.publicKey] == nil, @"an unknown device is nobody");
    SZFTExpect([store mergeDeviceChainData:two.encodedData forRootKey:root.publicKey error:&error] ==
                   SZFriendsChainMergeChanged, @"a friend's chain is kept: %@", error);
    SZFTExpect([store mergeDeviceChainData:two.encodedData forRootKey:root.publicKey error:NULL] ==
                   SZFriendsChainMergeUnchanged, @"the same chain again changes nothing");
    SZFTExpect([[store personWithIdentityKey:laptop.publicKey].conversationID isEqualToString:mei.conversationID] &&
                   [[store personWithIdentityKey:root.publicKey].conversationID isEqualToString:mei.conversationID],
               @"each authorized device finds the friend");
    SZFTExpect([[store rootKeyForDeviceKey:laptop.publicKey] isEqualToData:root.publicKey] &&
                   [[store staticKeyForDeviceKey:laptop.publicKey ofRootKey:root.publicKey]
                       isEqualToData:laptop.staticPublicKey], @"the device's root and static key");
    SZFriendsDeviceChain *revoked = [two chainByRevokingDeviceKey:laptop.publicKey signedBy:root date:SZFTAt(20)
                                                            error:NULL];
    SZFTExpect([store mergeDeviceChainData:revoked.encodedData forRootKey:root.publicKey error:NULL] ==
                   SZFriendsChainMergeChanged, @"the revocation is kept");
    SZFTExpect([store personWithIdentityKey:laptop.publicKey] == nil && [store isRevokedDeviceKey:laptop.publicKey] &&
                   [store rootKeyForDeviceKey:laptop.publicKey] == nil, @"a revoked device finds nobody");
    SZFTExpect([store mergeDeviceChainData:two.encodedData forRootKey:root.publicKey error:NULL] ==
                   SZFriendsChainMergeUnchanged && [store isRevokedDeviceKey:laptop.publicKey],
               @"an older chain cannot take a revocation back");
    SZFriendsDeviceChain *fork = [SZFriendsDeviceChain genesisChainWithIdentity:root name:@"Fork" system:@"macOS"
                                                                           date:SZFTAt(30) error:NULL];
    SZFTExpect([store mergeDeviceChainData:fork.encodedData forRootKey:root.publicKey error:&error] ==
                   SZFriendsChainMergeRefused && [error.domain isEqualToString:SZFriendsDeviceChainErrorDomain] &&
                   error.code == SZFriendsDeviceChainErrorWrongRoot, @"a second genesis for a pinned root: %@", error);
    SZFTExpect([store mergeDeviceChainData:SZFTGenesis(other).encodedData forRootKey:root.publicKey error:&error] ==
                   SZFriendsChainMergeRefused && error.code == SZFriendsDeviceChainErrorWrongRoot,
               @"another person's chain on this friend's session");
    SZFTExpect([store mergeDeviceChainData:SZFTGenesis(other).encodedData forRootKey:other.publicKey error:&error] ==
                   SZFriendsChainMergeRefused && error.code == SZFriendsStoreErrorNotFound,
               @"a chain for nobody in the list is not kept");
    NSMutableData *forged = [revoked.encodedData mutableCopy];
    ((uint8_t *)forged.mutableBytes)[forged.length - 1] ^= 1;
    SZFTExpect([store mergeDeviceChainData:forged forRootKey:root.publicKey error:NULL] ==
                   SZFriendsChainMergeRefused, @"a forged chain is refused");
    SZFTExpect([[store deviceChainForRootKey:root.publicKey].encodedData isEqualToData:revoked.encodedData],
               @"what is kept is the newest honest chain");
    // A device key speaks for one person: another friend's chain cannot claim it, even with its consent.
    SZFriendsIdentity *priyaRoot = SZFTDevice(20);
    SZFTFriendWithRoot(store, @"priya", priyaRoot);
    SZFriendsDeviceChain *claim = SZFTAdd(SZFTGenesis(priyaRoot), root, priyaRoot);
    SZFTExpect([store mergeDeviceChainData:claim.encodedData forRootKey:priyaRoot.publicKey error:&error] ==
                   SZFriendsChainMergeRefused && error.code == SZFriendsStoreErrorConstraint,
               @"claimed key: %@", error);
    [store close];
}

static void TestOwnChain(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"devices-own"));
    SZFriendsIdentity *me = SZFTDevice(30), *desk = SZFTDevice(31), *stranger = SZFTDevice(32);
    SZFriendsDeviceChain *mine = [store ownDeviceChainCreatingGenesisWithIdentity:me error:NULL];
    NSError *error = nil;
    SZFriendsDeviceChain *withDesk = SZFTAdd(mine, desk, me);
    SZFTExpect([store mergeOwnDeviceChain:withDesk error:&error] == SZFriendsChainMergeChanged, @"add: %@", error);
    SZFTExpect([[store rootKeyForDeviceKey:desk.publicKey] isEqualToData:me.publicKey] &&
                   [store personWithIdentityKey:desk.publicKey] == nil, @"our own devices are never a friend");
    SZFTExpect([store mergeOwnDeviceChain:SZFTGenesis(stranger) error:NULL] == SZFriendsChainMergeRefused,
               @"another root is not our chain");
    SZFTExpect([store noteDeviceKey:desk.publicKey seenAtDate:SZFTAt(500) error:NULL], @"seen");
    NSArray<SZFriendsDeviceRecord *> *devices = [store devicesOfRootKey:me.publicKey];
    SZFTExpect(devices.count == 2 && [devices[1].lastSeenAt isEqualToDate:SZFTAt(500)] && devices[0].isRoot,
               @"Your devices: both, with the desk's last connection");
    SZFriendsDeviceChain *renamed = [withDesk chainByRenamingTo:@"Studio" system:@"macOS 26.2" signedBy:desk
                                                           date:SZFTAt(600) error:NULL];
    SZFTExpect([store mergeOwnDeviceChain:renamed error:NULL] == SZFriendsChainMergeChanged &&
                   [[store devicesOfRootKey:me.publicKey][1].name isEqualToString:@"Studio"] &&
                   [[store devicesOfRootKey:me.publicKey][1].lastSeenAt isEqualToDate:SZFTAt(500)],
               @"a rename keeps the last connection");
    // Joining another profile: its chain must include this device.
    SZFriendsIdentity *theirRoot = SZFTDevice(40);
    SZFTExpect(![store adoptOwnDeviceChain:SZFTGenesis(theirRoot) localDeviceKey:me.publicKey error:NULL],
               @"a chain without this device is not adopted");
    SZFriendsDeviceChain *joined = SZFTAdd(SZFTGenesis(theirRoot), me, theirRoot);
    SZFTExpect([store adoptOwnDeviceChain:joined localDeviceKey:me.publicKey error:&error], @"adopt: %@", error);
    SZFTExpect([store.ownDeviceChain.rootKey isEqualToData:theirRoot.publicKey] &&
                   [store devicesOfRootKey:me.publicKey].count == 0 &&
                   [store rootKeyForDeviceKey:desk.publicKey] == nil,
               @"the profile's chain replaces this device's own");
    // Reset Friends: a new identity starts a new chain, so every chain goes with the people.
    SZFTExpect([store deleteEverythingExceptReceivedFilesWithError:&error], @"reset: %@", error);
    SZFTExpect(store.ownDeviceChain == nil && [store devicesOfRootKey:theirRoot.publicKey].count == 0 &&
                   [store rootKeyForDeviceKey:me.publicKey] == nil, @"Reset Friends forgets every chain");
    [store close];
}

void SZFTRunDeviceTests(void) {
    TestExistingProfileGetsItsGenesis();
    TestFriendsChains();
    TestOwnChain();
}
