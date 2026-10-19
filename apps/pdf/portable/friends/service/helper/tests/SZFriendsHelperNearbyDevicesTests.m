// friends-helper-check: the person's computers in the helper (SZFriendsNearbyService+Devices.m). Two helpers' services
// share one profile (A first, B added): Your computers lists both, this one first; renaming checks the name; removing
// B revokes it in A's chain, records which of B's events count, draws new secrets on A and queues the new presence
// secret for friends; B, once the chain reaches it, is a removed computer that sends nothing; Get asks for a file
// another computer holds, and Cancel lets it be; and a computer that joined checks in for the person.

#import "SZFriendsHelperNearbyTests.h"

#import "service/helper/SZFriendsHostCheckIn.h"
#import "service/helper/nearby/SZFriendsNearbyDevices.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/sync/SZFriendsSync.h"

static SZFriendsNearbyService *SZFNComputer(NSString *scratch, NSString *name) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, name);
    return services ? SZFNNearbyWith(services, @[]) : nil;
}

// A's profile with B added, held by both.
static SZFriendsDeviceChain *SZFNShareProfile(SZFriendsNearbyService *a, SZFriendsNearbyService *b) {
    SZFriendsIdentity *first = a.services.identity, *second = b.services.identity;
    SZFriendsDeviceChain *chain = [a.services.store ownDeviceChainCreatingGenesisWithIdentity:first error:NULL];
    chain = [chain chainByAddingDeviceKey:second.publicKey staticKey:second.staticPublicKey
                                  consent:SZFriendsDeviceConsent(second, chain.rootKey) name:@"Studio Mac"
                                   system:@"macOS 26.1" signedBy:first date:[NSDate date] error:NULL];
    EXPECT(chain != nil && [a.services.store mergeOwnDeviceChain:chain error:NULL] == SZFriendsChainMergeChanged &&
               [b.services.store adoptOwnDeviceChain:chain localDeviceKey:second.publicKey error:NULL],
           "one profile on two computers");
    [a noticeOwnDevicesChange];
    [b noticeOwnDevicesChange];
    return chain;
}

static void TestYourComputers(SZFriendsNearbyService *a, SZFriendsNearbyService *b) {
    SZFriendsDevicesFacts *facts = [a devicesFactsAtDate:[NSDate date]];
    EXPECT(facts.computers.count == 2 && facts.computers[0].thisComputer && !facts.computers[1].thisComputer,
           "this computer first, then the other");
    EXPECT([facts.computers[1].name isEqual:@"Studio Mac"] && !facts.computers[1].connected &&
               facts.computers[1].lastSeenAt == nil, "B as its add link named it, never reached");
    EXPECT([facts.computers[1].deviceID isEqual:SZFriendsDeviceIDForKey(b.services.identity.publicKey)], "its id");
    EXPECT(facts.you != nil && !facts.removed && !facts.joinOffered, "You shows with two computers; no joining");

    NSString *reason = nil;
    EXPECT([[a renameThisComputer:@"  " reason:&reason] isEqual:@"name_invalid"] && [reason isEqual:@"empty"],
           "an empty name");
    EXPECT([[a renameThisComputer:@"Line\nbreak" reason:&reason] isEqual:@"name_invalid"] &&
               [reason isEqual:@"invalid"], "a control character");
    NSString *long65 = [@"" stringByPaddingToLength:65 withString:@"m" startingAtIndex:0];
    EXPECT([[a renameThisComputer:long65 reason:&reason] isEqual:@"name_invalid"], "over 64 bytes");
    EXPECT([a renameThisComputer:@" Raph’s Mac mini " reason:NULL] == nil, "renamed");
    SZFriendsChainDevice *me = [a.services.store.ownDeviceChain deviceWithKey:a.services.identity.publicKey];
    EXPECT([me.name isEqual:@"Raph’s Mac mini"], "in the chain, trimmed: %@", me.name);
}

static void TestGet(SZFriendsNearbyService *a, SZFriendsNearbyService *b) {
    SZFriendsSyncFileRecord *file = [[SZFriendsSyncFileRecord alloc] init];
    file.transferID = @"t_on_studio";
    file.conversationID = SZFNSavePerson(a.services.store, SZFriendsRelationFriend).conversationID;
    file.state = SZFriendsTransferStateReceived;
    file.fileName = @"Factory audit photos.pdf";
    file.size = 312475648;
    file.contentDigest = SZFNBytes(32);
    file.createdAt = [NSDate date];
    file.holders = @[ b.services.identity.publicKey ];
    EXPECT([a.services.store saveSyncFile:file error:NULL], "B holds a large file");
    SZFriendsDeviceFileFacts *facts = [a devicesFactsAtDate:[NSDate date]].files[file.transferID];
    EXPECT(facts != nil && !facts.fetching && [facts.deviceName isEqual:@"Studio Mac"], "on Studio Mac, Get");
    EXPECT([[a fetchFileFromDevice:@"t_unknown"] isEqual:@"not_found"], "an unknown file");
    a.services.transfers.freeBytesProvider = ^uint64_t(NSString *path) { (void)path; return 1000; };
    EXPECT([[a fetchFileFromDevice:file.transferID] isEqual:@"disk_full"], "no room for it");
    a.services.transfers.freeBytesProvider = ^uint64_t(NSString *path) { (void)path; return UINT64_MAX; };
    EXPECT([a fetchFileFromDevice:file.transferID] == nil, "Get");
    EXPECT([a devicesFactsAtDate:[NSDate date]].files[file.transferID].fetching, "it copies when B is reached");
    EXPECT([a cancelFetchOfFile:file.transferID] && ![a cancelFetchOfFile:file.transferID], "Cancel, once");
    EXPECT(![a devicesFactsAtDate:[NSDate date]].files[file.transferID].fetching, "back on Studio Mac");
}

// A check-in for A against a loopback port nobody listens on: it starts clients and reaches nothing.
static SZFriendsHelperCheckIn *SZFNLoopbackCheckIn(NSString *scratch, SZFriendsNearbyService *a) {
    NSData *list = nil, *keys = nil;
    SZFNMakeList(@"ws://127.0.0.1:9/v1", &list, &keys);
    NSDictionary *env = @{@"SZFRIENDS_STATE_DIR" : scratch,
                          @"SZFRIENDS_TEST_HOST_LIST" : SZFNWrite(scratch, @"devices-list.json", list),
                          @"SZFRIENDS_TEST_HOST_KEYS" : SZFNWrite(scratch, @"devices-keys.json", keys)};
    SZFriendsCheckInSetup *setup = [SZFriendsCheckInSetup setupWithEnvironment:env bundledList:nil bundledKeys:nil
                                                                           why:NULL];
    NSString *cachePath = [scratch stringByAppendingPathComponent:@"devices-hosts.json"];
    SZFriendsHostListCache *cache = [[SZFriendsHostListCache alloc] initWithCachePath:cachePath
                                                                        bootstrapData:setup.bootstrapData
                                                                           pinnedKeys:setup.pinnedKeys];
    SZFriendsHelperCheckIn *checkIn = [[SZFriendsHelperCheckIn alloc] initWithServices:a.services setup:setup
                                                                                 cache:cache
                                                                                 queue:dispatch_get_main_queue()];
    a.services.checkIn = checkIn;
    return checkIn;
}

static void TestRemoving(NSString *scratch, SZFriendsNearbyService *a, SZFriendsNearbyService *b) {
    SZFriendsStore *store = a.services.store;
    SZFriendsHelperCheckIn *checkIn = SZFNLoopbackCheckIn(scratch, a);
    [checkIn start];
    EXPECT(checkIn.clientsStarted == 1, "checking in");
    SZFriendsPersonRecord *friend = SZFNSavePerson(store, SZFriendsRelationFriend);
    NSData *oldSecret = store.ownPresenceSecret;
    NSString *bID = SZFriendsDeviceIDForKey(b.services.identity.publicKey);
    EXPECT([[a revokeDeviceWithID:@"d_0011223344556677"] isEqual:@"not_found"], "an unknown computer");
    EXPECT([[a revokeDeviceWithID:SZFriendsDeviceIDForKey(a.services.identity.publicKey)] isEqual:@"not_allowed"],
           "not this computer");
    EXPECT([a revokeDeviceWithID:bID] == nil, "B removed");
    EXPECT([[a revokeDeviceWithID:bID] isEqual:@"not_found"], "already removed");
    EXPECT(checkIn.clientsStarted == 2, "a new check-in brings the chain that removes B to the host");
    [checkIn stop];
    a.services.checkIn = nil;
    EXPECT([store.ownDeviceChain revokesDeviceKey:b.services.identity.publicKey], "in A's chain");
    EXPECT([a devicesFactsAtDate:[NSDate date]].computers.count == 1, "gone from Your computers");
    NSString *key = [@"rv/" stringByAppendingString:SZFriendsLinkHex(b.services.identity.publicKey)];
    EXPECT([store syncRegisterForKey:key] != nil, "which of B's events count is recorded");
    EXPECT(store.ownPresenceSecret.length == 32 && ![store.ownPresenceSecret isEqual:oldSecret],
           "the first computer draws a new presence secret");
    BOOL told = NO;
    for (SZFriendsOutboxEntry *entry in [a.services.outbox pendingEntriesForConversation:friend.conversationID]) {
        told = told || entry.kind == SZFriendsOutboxKindPresenceSecret;
    }
    EXPECT(told, "and friends are sent it");

    // The chain reaches B: it is a removed computer.
    EXPECT(![b computeThisComputerRemoved], "not before it knows");
    [b.services.store mergeOwnDeviceChain:store.ownDeviceChain error:NULL];
    [b noticeOwnDevicesChange];
    EXPECT(b.removedFromProfile && [b computeThisComputerRemoved], "removed once the chain reaches it");
    SZFriendsDevicesFacts *removed = [b devicesFactsAtDate:[NSDate date]];
    EXPECT(removed.removed && !removed.joinOffered, "the list says so");
    EXPECT([[b revokeDeviceWithID:SZFriendsDeviceIDForKey(a.services.identity.publicKey)] isEqual:@"not_allowed"] &&
               [[b renameThisComputer:@"Anything" reason:NULL] isEqual:@"not_allowed"],
           "and it changes nothing");
    // Start Over: a new identity on its own, which works again.
    [b suspendForReset];
    EXPECT([b.services resetFriendsWithError:NULL], "started over");
    [b identityDidReset];
    EXPECT(!b.removedFromProfile && ![b computeThisComputerRemoved] && b.syncEngine == nil, "a computer of its own");
    EXPECT([b renameThisComputer:@"Fresh Mac" reason:NULL] == nil, "that changes things again");
}

// Reset Friends on the profile's first computer while the profile has others releases nothing: the ID is the
// person's, which the other computers keep checking in with.
static void TestFirstComputerKeepsTheID(NSString *scratch, SZFriendsNearbyService *a) {
    SZFriendsHelperCheckIn *checkIn = SZFNLoopbackCheckIn(scratch, a);
    [checkIn start];
    EXPECT(checkIn.clientsStarted == 1, "checking in");
    __block BOOL done = NO;
    [checkIn releaseIdentityWithCompletion:^{ done = YES; }];
    EXPECT(done, "no release is even tried: the reset goes ahead at once");
    [checkIn stop];
    a.services.checkIn = nil;
}

// A computer that joined first releases the ID it held on its own, then checks in for the person; a release no host
// confirmed is owed again at the next start.
static void TestPreJoinRelease(NSString *scratch, SZFriendsNearbyService *b) {
    SZFriendsHelperCheckIn *checkIn = SZFNLoopbackCheckIn(scratch, b);
    [b.services.store setSyncState:@YES forKey:SZFriendsCheckInPreJoinReleaseKey error:NULL];
    NSDate *began = [NSDate date];
    [checkIn start];
    EXPECT(checkIn.clientsStarted == 0, "the release goes first");
    for (int i = 0; i < 70 && checkIn.clientsStarted == 0; i++) SZFNSpin(0.1);
    NSTimeInterval releaseTakes = [[NSDate date] timeIntervalSinceDate:began];
    EXPECT(checkIn.clientsStarted == 1, "then the check-in, though no host answered");
    EXPECT([[b.services.store syncStateForKey:SZFriendsCheckInPreJoinReleaseKey] boolValue], "and it is still owed");
    [checkIn stop];
    // Stopped (Disable, exit) while the release runs: when it ends, nothing checks in.
    SZFriendsHelperCheckIn *stopped = SZFNLoopbackCheckIn(scratch, b);
    [stopped start];
    [stopped stop];
    SZFNSpin(MIN(6, releaseTakes * 2 + 0.5));
    EXPECT(stopped.clientsStarted == 0, "a stopped check-in stays stopped");
    b.services.checkIn = nil;
}

static void TestMembership(SZFriendsNearbyService *a, SZFriendsNearbyService *b) {
    SZFriendsHostListCache *cache = [[SZFriendsHostListCache alloc]
        initWithCachePath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"szfn-hosts.json"]
            bootstrapData:[NSData data]
               pinnedKeys:@[]];
    dispatch_queue_t queue = dispatch_get_main_queue();
    SZFriendsHostSocketFactory sockets = SZFriendsHostWebSocketFactory(queue);
    SZFriendsCheckInClient *joined = [[SZFriendsCheckInClient alloc] initWithListCache:cache
                                                                             identity:b.services.identity
                                                                           appVersion:@"26.10.15-1"
                                                                        socketFactory:sockets
                                                                                queue:queue];
    SZFriendsConfigureCheckInMembership(joined, b.services.store, b.services.identity.publicKey);
    NSData *chain = nil;
    NSData *root = joined.membershipProvider(&chain);
    EXPECT([root isEqual:a.services.identity.publicKey] &&
               [chain isEqual:b.services.store.ownDeviceChain.encodedData] && !joined.drawsIDs,
           "a joined computer checks in for the person, with the chain, and draws no ID");
    SZFriendsCheckInClient *first = [[SZFriendsCheckInClient alloc] initWithListCache:cache
                                                                            identity:a.services.identity
                                                                          appVersion:@"26.10.15-1"
                                                                       socketFactory:sockets
                                                                               queue:queue];
    SZFriendsConfigureCheckInMembership(first, a.services.store, a.services.identity.publicKey);
    chain = nil;
    EXPECT([first.membershipProvider(&chain) isEqual:a.services.identity.publicKey] &&
               [chain isEqual:a.services.store.ownDeviceChain.encodedData] && first.drawsIDs,
           "the first is its own root, and brings the chain once it has others");
}

// B, the profile's second computer, removes C and waits its turn to draw new secrets (the first computer may be
// away). The helper restarts meanwhile: once its wait is over, the new helper draws soon after start, without any
// change to the profile's computers to set it going.
static void TestRenewalResumesAfterRestart(NSString *scratch) {
    SZFriendsNearbyService *a = SZFNComputer(scratch, @"renew-a"), *b = SZFNComputer(scratch, @"renew-b");
    SZFriendsHelperServices *third = SZFNOpenServices(scratch, @"renew-c");
    if (a == nil || b == nil || third == nil) return;
    SZFriendsIdentity *first = a.services.identity, *second = b.services.identity, *removed = third.identity;
    SZFriendsDeviceChain *chain = [a.services.store ownDeviceChainCreatingGenesisWithIdentity:first error:NULL];
    for (SZFriendsIdentity *device in @[ second, removed ]) {
        chain = [chain chainByAddingDeviceKey:device.publicKey staticKey:device.staticPublicKey
                                      consent:SZFriendsDeviceConsent(device, chain.rootKey) name:@"Laptop"
                                       system:@"macOS 26.1" signedBy:first date:[NSDate date] error:NULL];
    }
    chain = [chain chainByRevokingDeviceKey:removed.publicKey signedBy:second date:[NSDate date] error:NULL];
    SZFriendsStore *store = b.services.store;
    EXPECT(chain != nil && [store adoptOwnDeviceChain:chain localDeviceKey:second.publicKey error:NULL],
           "B holds a profile of three computers, C removed by B");
    SZFriendsPersonRecord *friend = SZFNSavePerson(store, SZFriendsRelationFriend);
    NSData *before = store.ownPresenceSecret ?: [NSData data];
    [b noticeOwnDevicesChange];
    EXPECT([store.ownPresenceSecret isEqual:before] && b.secretRenewalScheduled, "B waits for the first computer");
    // The helper stops and starts again; the wait was noticed long enough ago that B's turn has come.
    NSTimeInterval noticed = [NSDate date].timeIntervalSince1970 - SZFriendsSyncSecretRenewalWait - 5;
    EXPECT([store setSyncState:@(noticed) forKey:@"revocations_noticed_at" error:NULL], "noticed 10 minutes ago");
    __block BOOL stopped = NO;
    [b shutdownWithCompletion:^{ stopped = YES; }];
    for (int i = 0; i < 30 && !stopped; i++) SZFNSpin(0.1);
    [b.services close];
    b = nil;
    SZFriendsHelperServices *reopened = SZFNOpenServices(scratch, @"renew-b");
    if (reopened == nil) return;
    SZFriendsNearbyService *restarted = SZFNNearbyWith(reopened, @[]);
    restarted.secretRenewalResumeDelay = 0.2;
    [restarted startAtLaunch];
    EXPECT([restarted.services.store.ownPresenceSecret isEqual:before], "nothing on the way to the first snapshot");
    for (int i = 0; i < 40 && [restarted.services.store.ownPresenceSecret isEqual:before]; i++) SZFNSpin(0.1);
    EXPECT(restarted.services.store.ownPresenceSecret.length == 32 &&
               ![restarted.services.store.ownPresenceSecret isEqual:before],
           "the restarted helper draws new secrets soon after start");
    BOOL told = NO;
    SZFriendsOutbox *outbox = restarted.services.outbox;
    for (SZFriendsOutboxEntry *entry in [outbox pendingEntriesForConversation:friend.conversationID]) {
        told = told || entry.kind == SZFriendsOutboxKindPresenceSecret;
    }
    EXPECT(told, "and friends are sent the new one");
    [restarted shutdownWithCompletion:^{}];
}

void SZFNTestDevices(NSString *scratch) {
    SZFriendsNearbyService *a = SZFNComputer(scratch, @"devices-a"), *b = SZFNComputer(scratch, @"devices-b");
    if (a == nil || b == nil) return;
    SZFNShareProfile(a, b);
    TestYourComputers(a, b);
    TestGet(a, b);
    TestMembership(a, b);
    TestFirstComputerKeepsTheID(scratch, a);
    TestPreJoinRelease(scratch, b);
    TestRemoving(scratch, a, b);
    TestRenewalResumesAfterRestart(scratch);
}
