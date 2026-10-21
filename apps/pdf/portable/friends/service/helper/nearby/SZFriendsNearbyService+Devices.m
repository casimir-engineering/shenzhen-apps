// This person's computers in the helper (PROTOCOL.md § Devices): what Your computers, You and files on another computer
// show, removing and renaming computers, Get, and what follows when the profile's computers change: a removed
// computer stops sending, a revoked one loses its sessions, and the first authorized computer draws new secrets and
// tells friends the new presence secret, so a removed computer can no longer recognise or follow them.

#import "service/helper/nearby/SZFriendsNearbyDevices.h"

#import "service/helper/SZFriendsHelperFacts.h"
#import "service/helper/SZFriendsHostCheckIn.h"
#import "service/helper/SZFriendsHelperTesting.h"
#import "service/helper/nearby/SZFriendsNearbyJoin.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/store/SZFriendsStoreSync.h"
#import "service/sync/SZFriendsSync.h"

static const NSUInteger SZFriendsComputerNameMax = 64;
// After start, a turn to draw new secrets that was waiting is looked at again this much later: past the first snapshot.
static const NSTimeInterval SZFriendsSecretRenewalResumeDelay = 10;
// You items looked at for "On all your computers": as many as a conversation snapshot shows.
static const NSUInteger SZFriendsYouItemsWindow = 200;

NSString *SZFriendsDeviceIDForKey(NSData *deviceKey) {
    NSData *prefix = deviceKey.length >= 8 ? [deviceKey subdataWithRange:NSMakeRange(0, 8)] : deviceKey;
    return [@"d_" stringByAppendingString:SZFriendsLinkHex(prefix)];
}

@implementation SZFriendsNearbyService (Devices)

#pragma mark - Who we are

- (nullable NSData *)ownRootKeyEvenIfRemoved {
    SZFriendsStore *store = self.services.store;
    NSData *root = [store rootKeyForDeviceKey:[self localIdentityKey]];
    if (root != nil) {
        self.ownRootKeyCache = root;
        return root;
    }
    // A revoked computer finds no root by its own key; the chain it holds still names it.
    if (self.ownRootKeyCache == nil && [store isRevokedDeviceKey:[self localIdentityKey]]) {
        self.ownRootKeyCache = store.ownDeviceChain.rootKey;
    }
    return self.ownRootKeyCache;
}

- (BOOL)computeThisComputerRemoved {
    SZFriendsStore *store = self.services.store;
    if (store == nil || self.services.identity == nil) return NO;
    return [store isRevokedDeviceKey:[self localIdentityKey]] ||
           [[store syncStateForKey:SZFriendsCheckInRemovedByHostKey] boolValue];
}

- (BOOL)ownDeviceConnected:(NSData *)deviceKey {
    SZFriendsPeerLink *link = self.syncLinkTable[SZFriendsLinkHex(deviceKey)];
    return link != nil && !link.closed;
}

#pragma mark - Changes

- (void)ownDevicesChanged {
    SZFriendsStore *store = self.services.store;
    if (store == nil || self.services.identity == nil) return;
    // A device that just joined shows its tags only in reads made from now on (Bluetooth caches a read per window).
    for (id<SZFriendsDiscoveryAdapter> adapter in self.adapters) {
        if ([adapter respondsToSelector:@selector(rereadDiscovery)]) [adapter rereadDiscovery];
    }
    BOOL removed = [self computeThisComputerRemoved];
    if (removed && !self.removedFromProfile) {
        self.removedFromProfile = YES;
        SZFriendsHelperLog(@"this computer was removed from its profile: it reads, and sends nothing");
        [self stopOnline];
        [self forgetJoins];
        [self.services.checkIn stop];
        [self.coordinator advertisePresenceTag:nil callbackTags:@[] publicEntry:NO];
        for (SZFriendsPeerLink *link in self.links.allObjects) {
            [link.channel closeWithReason:SZFriendsCloseReasonNormal];
        }
        [self changed];
        return;
    }
    self.removedFromProfile = removed;
    if (removed) return;
    // A computer removed from the profile loses every session with us at once, told why by the chain (+Removed).
    for (SZFriendsPeerLink *link in self.syncLinkTable.allValues) {
        if (link.closed || [self isOwnDeviceKey:link.channel.remoteIdentityKey]) continue;
        [self tellRemovedComputerOnLink:link];
    }
    // Friends connected now hear of a computer added, removed or renamed at once (a CHAIN frame on every session),
    // so they accept a new computer before it first reaches them; the others at their next session.
    for (SZFriendsPeerLink *link in self.activeLinks.allValues) {
        if (!link.closed) [self sendChainOnLink:link];
    }
    NSData *root = [store rootKeyForDeviceKey:[self localIdentityKey]];
    if (root != nil && [store devicesOfRootKey:root].count >= 2) [store ensureYouConversation:NULL];
    [self renewSecretsIfDue];
    [self changed];
}

// One authorized computer draws new secrets after a revocation (the first, or the next ones in turn when it is away);
// friends get the new presence secret, so the removed computer's copy matches nothing any more. Our other computers
// learn both by sync. While this computer waits its turn, it looks again when the turn comes.
- (void)renewSecretsIfDue {
    SZFriendsSyncEngine *engine = [self activeSyncEngine];
    NSData *fresh = [engine renewSecretsAfterRevocation];
    if (fresh != nil) {
        SZFriendsHelperLog(@"a computer was removed: new secrets drawn, friends are told");
        [self tellFriendsPresenceSecret];
        [self rebuildTagMatcher];
        [self refreshAdvertisement];
        return;
    }
    NSDate *due = [engine secretRenewalDueDate];
    if (due == nil || self.secretRenewalScheduled || self.shutDown) return;
    self.secretRenewalScheduled = YES;
    NSTimeInterval wait = MAX(1, MIN([due timeIntervalSinceNow] + 1, SZFriendsSyncSecretRenewalWait));
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.shutDown) return;
        strongSelf.secretRenewalScheduled = NO;
        if (!strongSelf.removedFromProfile) [strongSelf renewSecretsIfDue];
    });
}

- (void)resumeSecretRenewalAfterStart {
    NSTimeInterval delay = self.secretRenewalResumeDelay > 0 ? self.secretRenewalResumeDelay
                                                             : SZFriendsSecretRenewalResumeDelay;
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        // A computer with no other in its profile has no engine and nothing to read past the device index.
        if (strongSelf != nil && !strongSelf.shutDown && !strongSelf.removedFromProfile) [strongSelf renewSecretsIfDue];
    });
}

- (void)tellFriendsPresenceSecret {
    for (SZFriendsPersonRecord *person in [self.services.store peopleByLatestInteraction]) {
        if (person.relation != SZFriendsRelationFriend || person.identityKey == nil) continue;
        [self enqueueKind:SZFriendsOutboxKindPresenceSecret conversationID:person.conversationID payload:nil];
        [self deliverPendingForConversation:person.conversationID];
    }
}

- (void)hostSaysThisComputerWasRemoved {
    [self ownDevicesChanged];
}

#pragma mark - Intents

- (nullable NSString *)revokeDeviceWithID:(NSString *)deviceID {
    SZFriendsStore *store = self.services.store;
    SZFriendsIdentity *identity = self.services.identity;
    if (self.removedFromProfile || store == nil || identity == nil) return @"not_allowed";
    NSData *local = identity.publicKey;
    if ([deviceID isEqualToString:SZFriendsDeviceIDForKey(local)]) return @"not_allowed"; // only through Start Over
    NSData *root = [store rootKeyForDeviceKey:local];
    SZFriendsDeviceRecord *target = nil;
    for (SZFriendsDeviceRecord *device in root ? [store devicesOfRootKey:root] : @[]) {
        if ([SZFriendsDeviceIDForKey(device.deviceKey) isEqualToString:deviceID]) target = device;
    }
    if (target == nil || target.state != SZFriendsChainDeviceAuthorized) return @"not_found";
    NSError *error = nil;
    SZFriendsDeviceChain *chain = [store.ownDeviceChain chainByRevokingDeviceKey:target.deviceKey signedBy:identity
                                                                            date:[NSDate date]
                                                                           error:&error];
    if (chain == nil || [store mergeOwnDeviceChain:chain error:&error] == SZFriendsChainMergeRefused) {
        SZFriendsHelperLog(@"could not remove a computer: %@", error.localizedDescription);
        return @"internal";
    }
    // Which of its events count from now on, for our other computers to hold it to (ADR 0014).
    [[self activeSyncEngine] recordRevocationOfDeviceKey:target.deviceKey error:NULL];
    [self noticeOwnDevicesChange];
    [self.services.checkIn restartAfterRevoking]; // the host turns it away from now on
    [self changed];
    return nil;
}

- (nullable NSString *)renameThisComputer:(NSString *)typed reason:(NSString *_Nullable *_Nullable)reason {
    SZFriendsStore *store = self.services.store;
    SZFriendsIdentity *identity = self.services.identity;
    if (self.removedFromProfile || store == nil || identity == nil) return @"not_allowed";
    NSString *name = [typed stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUInteger bytes = [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    BOOL control = [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound;
    if (bytes == 0 || bytes > SZFriendsComputerNameMax || control) {
        if (reason) *reason = bytes == 0 ? @"empty" : @"invalid";
        return @"name_invalid";
    }
    NSError *error = nil;
    SZFriendsDeviceChain *held = [store ownDeviceChainCreatingGenesisWithIdentity:identity error:&error];
    SZFriendsChainDevice *me = [held deviceWithKey:identity.publicKey];
    if (me == nil) return @"not_allowed";
    if ([me.name isEqualToString:name]) return nil;
    SZFriendsDeviceChain *renamed = [held chainByRenamingTo:name system:me.system signedBy:identity
                                                       date:[NSDate date] error:&error];
    if (renamed == nil || [store mergeOwnDeviceChain:renamed error:&error] == SZFriendsChainMergeRefused) {
        SZFriendsHelperLog(@"could not rename this computer: %@", error.localizedDescription);
        return @"internal";
    }
    [self noticeOwnDevicesChange];
    [self changed];
    return nil;
}

- (nullable NSString *)fetchFileFromDevice:(NSString *)transferID {
    SZFriendsStore *store = self.services.store;
    if (self.removedFromProfile || store == nil) return @"not_allowed";
    SZFriendsSyncEngine *engine = [self activeSyncEngine];
    SZFriendsSyncFileRecord *file = [store syncFileWithID:transferID];
    SZFriendsTransferRecord *row = [store transferRecordWithID:transferID];
    if (row != nil && SZFriendsSyncLocalPathOfTransfer(row) != nil) return @"not_allowed"; // here already
    // Here before and moved or deleted, or never here: Get copies it from a computer that holds it now.
    if (engine == nil || file == nil || ![self anotherComputerHoldsFile:file]) return @"not_found";
    SZFriendsTransfers *transfers = self.services.transfers;
    uint64_t free = transfers.freeBytesProvider ? [transfers freeBytesForReceiving] : UINT64_MAX;
    if (free < file.size) return @"disk_full";
    if (![engine requestFile:transferID error:NULL]) return @"internal";
    [self pumpSyncExchanges];
    [self scheduleReconsider]; // the computer holding it is dialed, nearby or online
    [self changed];
    return nil;
}

- (BOOL)cancelFetchOfFile:(NSString *)transferID {
    SZFriendsSyncEngine *engine = [self activeSyncEngine];
    if (engine == nil || ![engine isFileRequested:transferID]) return NO;
    [engine cancelFileRequest:transferID error:NULL];
    [self pumpSyncExchanges];
    [self changed];
    return YES;
}

#pragma mark - Facts

- (NSArray<SZFriendsDeviceFacts *> *)computerFacts {
    SZFriendsStore *store = self.services.store;
    NSData *local = [self localIdentityKey];
    NSData *root = [self ownRootKeyEvenIfRemoved];
    SZFriendsDeviceFacts *me = nil;
    NSMutableArray<SZFriendsDeviceRecord *> *others = [NSMutableArray array];
    for (SZFriendsDeviceRecord *device in root ? [store devicesOfRootKey:root] : @[]) {
        if ([device.deviceKey isEqualToData:local]) {
            me = [[SZFriendsDeviceFacts alloc] init];
            me.name = device.name;
            me.system = device.system;
        } else if (device.state == SZFriendsChainDeviceAuthorized) {
            [others addObject:device];
        }
    }
    if (me == nil) { // one computer, no chain yet: as it will name itself
        me = [[SZFriendsDeviceFacts alloc] init];
        me.name = SZFriendsHelperDeviceName();
        me.system = SZFriendsHelperDeviceSystem();
    }
    me.deviceID = SZFriendsDeviceIDForKey(local);
    me.thisComputer = YES;
    me.connected = YES;
    [others sortUsingComparator:^NSComparisonResult(SZFriendsDeviceRecord *a, SZFriendsDeviceRecord *b) {
        NSComparisonResult order = [a.addedAt compare:b.addedAt];
        return order != NSOrderedSame ? order : [SZFriendsLinkHex(a.deviceKey) compare:SZFriendsLinkHex(b.deviceKey)];
    }];
    NSMutableArray<SZFriendsDeviceFacts *> *computers = [NSMutableArray arrayWithObject:me];
    for (SZFriendsDeviceRecord *device in others) {
        SZFriendsDeviceFacts *facts = [[SZFriendsDeviceFacts alloc] init];
        facts.deviceID = SZFriendsDeviceIDForKey(device.deviceKey);
        facts.name = device.name;
        facts.system = device.system;
        facts.connected = [self ownDeviceConnected:device.deviceKey];
        facts.lastSeenAt = device.lastSeenAt;
        [computers addObject:facts];
    }
    return computers;
}

// Read once per pass: which transfers are here, which keys are our other computers and what they are called.
- (NSDictionary<NSString *, SZFriendsDeviceFileFacts *> *)fileFactsWithEngine:(SZFriendsSyncEngine *)engine {
    SZFriendsStore *store = self.services.store;
    // Rows here, and which of them still have their bytes (what the person moved or deleted does not).
    NSMutableSet<NSString *> *rows = [NSMutableSet set], *here = [NSMutableSet set];
    for (SZFriendsTransferRecord *transfer in [store allTransferRecords]) {
        [rows addObject:transfer.transferID];
        if (SZFriendsSyncLocalPathOfTransfer(transfer) != nil) [here addObject:transfer.transferID];
    }
    NSSet<NSData *> *ours = [NSSet setWithArray:engine.otherDeviceKeys];
    NSMutableDictionary<NSData *, NSString *> *names = [NSMutableDictionary dictionary];
    NSData *root = [self ownRootKeyEvenIfRemoved];
    for (SZFriendsDeviceRecord *device in root ? [store devicesOfRootKey:root] : @[]) {
        names[device.deviceKey] = device.name;
    }
    NSMutableDictionary<NSString *, NSNumber *> *copying = [NSMutableDictionary dictionary];
    for (SZFriendsPeerLink *link in self.syncLinkTable.allValues) {
        NSString *transferID = link.syncExchange.copyingTransferID;
        if (transferID != nil) copying[transferID] = @(link.syncExchange.copyingFraction);
    }
    NSMutableDictionary<NSString *, SZFriendsDeviceFileFacts *> *files = [NSMutableDictionary dictionary];
    for (SZFriendsSyncFileRecord *file in [store syncFiles]) {
        if ([here containsObject:file.transferID]) continue;
        NSData *holder = nil;
        BOOL connected = NO;
        for (NSData *key in file.holders) {
            if (![ours containsObject:key]) continue;
            BOOL live = [self ownDeviceConnected:key];
            if (holder == nil || (live && !connected)) holder = key;
            connected = connected || live;
        }
        if (holder == nil) continue;
        SZFriendsDeviceFileFacts *facts = [[SZFriendsDeviceFileFacts alloc] init];
        facts.deviceName = names[holder] ?: SZFriendsHelperDeviceName();
        facts.fetching = [engine isFileRequested:file.transferID] ||
                         (![rows containsObject:file.transferID] &&
                          SZFriendsSyncCopiesAutomatically(file.size, file.conversationID));
        facts.holderConnected = connected;
        facts.fraction = [copying[file.transferID] doubleValue];
        // The session carrying the copy, as the conversation's route shows a friend's file.
        SZFriendsPeerLink *carrier = [self liveSyncLinkForDeviceHex:SZFriendsLinkHex(holder)];
        facts.routeMethod = carrier != nil ? carrier.raceRoute : SZFriendsRouteMethodNone;
        files[file.transferID] = facts;
    }
    return files;
}

- (void)fillYouFacts:(SZFriendsDevicesFacts *)facts engine:(nullable SZFriendsSyncEngine *)engine {
    SZFriendsStore *store = self.services.store;
    SZFriendsPersonRecord *record = [store personWithConversationID:SZFriendsYouConversationID];
    BOOL hasItems = NO;
    NSArray<SZFriendsItemRecord *> *items = record ? [store itemsInConversation:SZFriendsYouConversationID
                                                                   beforeItemID:nil
                                                                          limit:SZFriendsYouItemsWindow
                                                                     hasEarlier:&hasItems]
                                                   : @[];
    if (record == nil || (facts.computers.count < 2 && items.count == 0)) return;
    SZFriendsPersonFacts *you = [[SZFriendsPersonFacts alloc] init];
    you.conversationID = SZFriendsYouConversationID;
    you.name = store.profileName;
    you.friendsID = store.friendsID;
    you.picture = store.profilePicture ?: [SZFriendsPicture placeholder];
    you.relation = SZFriendsPersonRelationFriend;
    you.unreadCount = record.unreadCount;
    you.lastInteractionAt = record.lastInteractionAt ?: [NSDate dateWithTimeIntervalSince1970:0];
    facts.you = you;
    if (items.lastObject != nil) facts.youPreview = SZFriendsItemFactsFromRecord(items.lastObject, self.services);
    // With no other computer (one was removed, say), what is here is on every computer there is.
    NSMutableSet<NSString *> *everywhere = [NSMutableSet set];
    if (engine == nil || engine.otherDeviceKeys.count == 0) {
        for (SZFriendsItemRecord *item in items) {
            if (item.direction == SZFriendsDirectionOutgoing) [everywhere addObject:item.itemID];
        }
    } else {
        [everywhere unionSet:[engine itemsOnEveryDeviceInConversation:SZFriendsYouConversationID]];
    }
    facts.youItemsEverywhere = everywhere;
    NSMutableDictionary<NSString *, NSNumber *> *serving = [NSMutableDictionary dictionary];
    for (SZFriendsPeerLink *link in self.syncLinkTable.allValues) {
        NSString *transferID = link.syncExchange.servingTransferID;
        if (transferID != nil) serving[transferID] = @(link.syncExchange.servingFraction);
    }
    facts.youCopying = serving;
}

- (SZFriendsDevicesFacts *)devicesFactsAtDate:(NSDate *)now {
    SZFriendsDevicesFacts *facts = [[SZFriendsDevicesFacts alloc] init];
    facts.now = now;
    if (self.services.store == nil || self.services.identity == nil) return facts;
    facts.computers = [self computerFacts];
    facts.removed = self.removedFromProfile;
    facts.joinOffered = !facts.removed && [self joinAvailable];
    // Joining after Reset Friends: a profile on this computer only, with people in it that joining would replace.
    facts.joinReplaces = !facts.removed && !facts.joinOffered && self.services.store.ownDeviceChain.devices.count <= 1;
    facts.friendsID = self.services.store.friendsID;
    SZFriendsSyncEngine *engine = [self activeSyncEngine];
    [self fillYouFacts:facts engine:engine];
    if (engine != nil) facts.files = [self fileFactsWithEngine:engine];
    return facts;
}

@end
