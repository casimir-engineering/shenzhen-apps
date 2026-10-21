// Opens the service areas in the order SZFriendsHelperMain requires and holds them for the dispatch layer.

#import "service/helper/SZFriendsHelperServices.h"

#import <sodium.h>

#import "service/discovery/SZFriendsDiscovery.h"
#import "service/helper/SZFriendsHelperInternal.h"
#import "service/helper/SZFriendsHelperTesting.h"
#import "service/helper/SZFriendsHostCheckIn.h"
#import "service/helper/nearby/SZFriendsNearbyService.h"
#import "service/host/SZFriendsHostConnection.h"
#import "service/notify/SZFriendsNotify.h"
#import "service/store/SZFriendsTransferThumbnails.h"

@implementation SZFriendsHelperResources

+ (instancetype)loadFromBundle:(NSBundle *)bundle {
    SZFriendsHelperResources *resources = [[self alloc] init];
    resources->_wordList = [SZFriendsWordList bundledList];
    resources->_animalSet = [SZFriendsAnimalSet bundledSet];
    NSString *hostList = [bundle pathForResource:@"bootstrap-hosts" ofType:@"json"];
    if (hostList != nil) resources->_bootstrapHostList = [NSData dataWithContentsOfFile:hostList];
    NSString *keys = [bundle pathForResource:@"pinned-keys" ofType:@"json"];
    if (keys != nil) resources->_pinnedHostKeys = [NSData dataWithContentsOfFile:keys];
    // Logged, not fatal: without a word list no new Friends ID can be drawn, but an existing one still works,
    // and without the animal set pictures fall back to placeholders.
    if (resources->_wordList == nil) SZFriendsHelperLog(@"word list missing or invalid in the helper bundle");
    if (resources->_animalSet == nil) SZFriendsHelperLog(@"animal set missing in the helper bundle");
    return resources;
}

@end

@implementation SZFriendsHelperServices {
    NSDictionary<NSString *, NSString *> *_environment;
    SZFriendsIdentityManager *_identityManager;
}

- (instancetype)initWithPaths:(SZFriendsStatePaths *)paths
                  environment:(NSDictionary<NSString *, NSString *> *)environment
                    resources:(SZFriendsHelperResources *)resources {
    if ((self = [super init])) {
        _paths = paths;
        _environment = [environment copy];
        _resources = resources;
        _identityState = SZFriendsIdentityStateUnavailable;
        if (resources.wordList != nil) _codec = [[SZFriendsIDCodec alloc] initWithWordList:resources.wordList];
    }
    return self;
}

+ (NSData *)randomBytes:(NSUInteger)count {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    randombytes_buf(data.mutableBytes, count);
    return data;
}

- (void)open {
    [self openHostList];
    [self openIdentity];
    [self openStore];
}

// Before the store: a first start draws its ID with the signed list's word count (ADR 0006).
- (void)openHostList {
    NSString *why = nil;
    _checkInSetup = [SZFriendsCheckInSetup setupWithEnvironment:_environment
                                                    bundledList:self.resources.bootstrapHostList
                                                    bundledKeys:self.resources.pinnedHostKeys
                                                            why:&why];
    if (_checkInSetup == nil) {
        SZFriendsHelperLog(@"no host check-in: %@", why ?: @"no reason given");
        return;
    }
    _hostListCache = [[SZFriendsHostListCache alloc] initWithCachePath:self.paths.hostListPath
                                                         bootstrapData:_checkInSetup.bootstrapData
                                                            pinnedKeys:_checkInSetup.pinnedKeys];
}

static NSString *SZFriendsIdentityProblem(NSError *error);

- (void)openIdentity {
    // The file key store whenever SZFRIENDS_STATE_DIR is set, so tests and probes cannot reach the Keychain.
    id<SZFriendsKeyStore> keyStore = SZFriendsDefaultKeyStore(self.paths.stateDirectory, _environment);
    _identityManager = [[SZFriendsIdentityManager alloc] initWithKeyStore:keyStore];
    SZFriendsIdentityState state = SZFriendsIdentityStateUnavailable;
    NSError *error = nil;
    _identity = [_identityManager loadOrCreateWithState:&state error:&error];
    // Never regenerated here: an unreadable key is shown as unavailable with an explicit reset, because every
    // friend would see a silent new key as a key change (brief § Identity and keys).
    _identityState = _identity != nil ? state : SZFriendsIdentityStateUnavailable;
    if (_identity == nil) SZFriendsHelperLog(@"identity unavailable: %@", SZFriendsIdentityProblem(error));
}

// The description and the store's own status (an OSStatus from the Keychain), so helper.log says which refusal it was.
static NSString *SZFriendsIdentityProblem(NSError *error) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSError *e = error; e != nil && parts.count < 4; e = e.userInfo[NSUnderlyingErrorKey]) {
        [parts addObject:[e.domain isEqualToString:SZFriendsIdentityErrorDomain]
                             ? e.localizedDescription
                             : [NSString stringWithFormat:@"%@ %ld", e.domain, (long)e.code]];
    }
    return parts.count ? [parts componentsJoinedByString:@" / "] : @"no detail";
}

- (void)openNotifierOnQueue:(dispatch_queue_t)queue {
    if (_store == nil || _notifier != nil) return;
    NSString *directory = self.paths.stateDirectory;
    // A test home never touches the notification centre: every Mac test posts to the sink.
    id<SZFriendsNotificationPoster> poster =
        _environment[@"SZFRIENDS_STATE_DIR"] != nil
            ? [[SZFriendsNotifyFileSink alloc] initWithStateDirectory:directory environment:_environment]
            : [[SZFriendsNotifySystemPoster alloc] initWithQueue:queue];
    SZFriendsNotifySettings *settings = [[SZFriendsNotifySettings alloc] initWithStateDirectory:directory];
    _notifier = [[SZFriendsNotifier alloc] initWithStore:_store transfers:_transfers settings:settings poster:poster
                                                   queue:queue];
}

- (BOOL)retryIdentity {
    if (_identity != nil) return YES;
    if (_identityManager == nil) return NO;
    NSError *error = nil;
    SZFriendsIdentity *identity = [_identityManager loadExistingWithError:&error];
    if (identity == nil) return NO;
    _identity = identity;
    _identityState = SZFriendsIdentityStateReady;
    SZFriendsHelperLog(@"identity available again");
    return YES;
}

- (void)openStore {
    NSError *error = nil;
    _store = [SZFriendsStore storeInDirectory:self.paths.stateDirectory error:&error];
    if (_store == nil) {
        // A store a newer helper migrated past us is left alone; the list explains that an update is needed.
        if ([error.domain isEqualToString:SZFriendsStoreErrorDomain] && error.code == SZFriendsStoreErrorNewerSchema) {
            _updateNeed = SZFriendsUpdateNeedStore;
        }
        SZFriendsHelperLog(@"store unavailable: %@", error.localizedDescription ?: @"no detail");
        return;
    }
    _outbox = [[SZFriendsOutbox alloc] initWithStore:_store];
    _transfers = [[SZFriendsTransfers alloc] initWithStore:_store stateDirectory:self.paths.stateDirectory];
    // Previews a crash left unrecorded, or whose rows an older helper deleted, go before anything new is written.
    [_transfers removeUnreferencedThumbnailFiles];
    [self ensureProfile];
    [self expireOutbox];
    [self expireIncomingRequests];
    [self expireOutgoingRequests];
}

// First start: an ID usable nearby at once (brief § Friends ID), a random animal (brief § Pictures), and the
// presence secret friends will receive on acceptance (ADR 0004).
- (void)ensureProfile {
    if (_store.friendsID.length == 0) {
        // The harness may give a first start a chosen ID (two holders of one ID); once, never after a reset.
        NSString *friendsID = SZFriendsHelperTestHooks.initialFriendsID ?: [self drawFriendsID];
        SZFriendsHelperTestHooks.initialFriendsID = nil;
        if (friendsID != nil) {
            _store.friendsID = friendsID;
            _store.friendsIDState = SZFriendsIDStateUnreserved;
        }
    }
    if (_store.profilePicture == nil || _store.profilePicture.kind == SZFriendsPictureKindPlaceholder) {
        SZFriendsAnimalSet *set = self.resources.animalSet;
        if (set != nil && set.count > 0) _store.profilePicture = [set randomDefaultPicture];
    }
    if (_store.ownPresenceSecret == nil) _store.ownPresenceSecret = SZFriendsNewPresenceSecret();
}

- (nullable NSString *)drawFriendsID {
    if (_codec == nil) return nil;
    // The signed list's new_id_words (2 until the admin publishes 3); 2 when this helper has no list.
    NSInteger listWords = _hostListCache != nil ? _hostListCache.currentList.newIDWords : 2;
    if (_store.idCollisionsInARow >= 3) listWords = 3; // ADR 0006: three collisions in a row stay three words
    return [SZFriendsIDStatus initialStatusWithCodec:_codec
                                      listNewIDWords:listWords
                                           generator:SZFriendsSystemRandomUniform()].friendsID;
}

- (BOOL)removeIdentityForResetWithError:(NSError **)error {
    return _identityManager == nil || [_identityManager deleteIdentityWithError:error];
}

// The old identity leaves the keychain first, and nothing else changes unless that worked: a keychain that refuses
// (locked, say) used to be found out after the friends, history and Friends ID were already gone, leaving the person
// with nothing and an identity they still could not read. Then the old identity's data goes and the new identity
// last: a reset that replaced the identity and then failed to wipe kept the old friends and presence secret beside
// the new key, and went on advertising tags old friends could match, linking the two (review: Reset Friends
// ordering); the presence secret changes before the wipe, so a wipe that fails after the delete links nothing
// either. Nothing is advertised from the first step until the reset has succeeded (SZFriendsNearbyService
// -suspendForReset).
- (BOOL)resetFriendsWithError:(NSError **)error {
    [self.nearby suspendForReset];
    // Removing it again after the router did is harmless: there is nothing left to find.
    if (![self removeIdentityForResetWithError:error]) return NO;
    if (_store != nil) {
        // Old friends' tags stop matching before anything else, so even a reset that fails from here links nothing.
        _store.ownPresenceSecret = SZFriendsNewPresenceSecret();
        // Friends, history, pictures and private copies go; received files stay (PROTOCOL.md reset_friends).
        if (![_store deleteEverythingExceptReceivedFilesWithError:error]) return NO;
        _store.friendsID = nil;
        _store.previousFriendsID = nil;
        _store.idCollisionsInARow = 0;
        _store.profileName = nil;
        _store.profilePicture = [SZFriendsPicture placeholder];
    }
    // The old identity's host attestation, beside the list where the check-in client keeps it: its release forgets it
    // too, but a helper not checking in now (a test, or no list) never released, and the file names the old ID.
    NSString *attestation = [[self.paths.hostListPath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"host-attestation.json"];
    [[NSFileManager defaultManager] removeItemAtPath:attestation error:NULL];
    SZFriendsIdentity *identity = [_identityManager createIdentityWithError:error];
    if (identity == nil) return NO;
    _identity = identity;
    _identityState = SZFriendsIdentityStateCreated;
    if (_store != nil) [self ensureProfile];
    return YES;
}

- (BOOL)expireOutbox {
    // Nothing waits forever without saying so: 30 days unsent becomes Failed with Try again (SZFriendsOutbox.h).
    // The harness moves this clock forward instead of waiting a month (SZFriendsHelperTesting.h).
    NSDate *now = [NSDate dateWithTimeIntervalSinceNow:SZFriendsHelperTestHooks.outboxClockOffset];
    NSError *error = nil;
    NSArray *expired = [_outbox expireEntriesAtDate:now error:&error];
    if (expired == nil && error != nil) SZFriendsHelperLog(@"outbox expiry failed: %@", error.localizedDescription);
    return expired.count > 0;
}

- (BOOL)expireIncomingRequests {
    // A request nobody answered lapses after 14 days (SZFriendsIncomingRequestLifetime): while it waits the requester's
    // key is one the key policy knows, so the wait must end (wave-3 review). The same injected clock as the outbox.
    NSDate *now = [NSDate dateWithTimeIntervalSinceNow:SZFriendsHelperTestHooks.outboxClockOffset];
    NSError *error = nil;
    NSArray<SZFriendsPersonRecord *> *lapsed = [_store expireIncomingRequestsAtDate:now error:&error];
    if (lapsed == nil && _store != nil) {
        SZFriendsHelperLog(@"request expiry failed: %@", error.localizedDescription);
    }
    return lapsed.count > 0;
}

- (BOOL)expireOutgoingRequests {
    // A request we sent admits its key to our hidden listener only while an answer can come; once none can, the row
    // lapses so nothing keeps that key known (wave-4 re-check). The same injected clock as the outbox.
    NSDate *now = [NSDate dateWithTimeIntervalSinceNow:SZFriendsHelperTestHooks.outboxClockOffset];
    NSError *error = nil;
    NSArray<SZFriendsPersonRecord *> *lapsed = [_store expireOutgoingRequestsAtDate:now error:&error];
    if (lapsed == nil && _store != nil) {
        SZFriendsHelperLog(@"outgoing request expiry failed: %@", error.localizedDescription);
    }
    return lapsed.count > 0;
}

- (void)close {
    // Received bytes made durable first, so the next helper resumes from all of them (ADR 0003).
    [_transfers flushProgressWithError:NULL];
    [_store close];
}

@end
