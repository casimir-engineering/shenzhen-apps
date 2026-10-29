// Nearby Friends in the helper: lifecycle, advertising, presence windows, visibility, wake (SZFriendsNearbyService.h).

#import "service/helper/nearby/SZFriendsNearbyDevices.h"
#import "service/helper/nearby/SZFriendsNearbyJoin.h"

#import "service/helper/nearby/SZFriendsWakeMonitor.h"

const NSTimeInterval SZFriendsNearbyConnectingTimeout = 12;

// PROTOCOL.md § Snapshots: transfer progress at most 4 times per second.
static const CFTimeInterval SZFriendsProgressInterval = 0.25;
// Shutdown waits this long for the CLOSE frames before the process exits anyway.
static const NSTimeInterval SZFriendsShutdownFlush = 1.0;

@implementation SZFriendsNearbyStranger
@end

@implementation SZFriendsNearbyService {
    dispatch_source_t _windowTimer;
    dispatch_source_t _visibilityTimer;
    SZFriendsWakeMonitor *_wakeMonitor;
    BOOL _changeScheduled;
}

- (instancetype)initWithServices:(SZFriendsHelperServices *)services
                        adapters:(NSArray<id<SZFriendsDiscoveryAdapter>> *)adapters
                           queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _services = services;
        _adapters = [adapters copy];
        _queue = queue;
        _links = [NSMutableSet set];
        _activeLinks = [NSMutableDictionary dictionary];
        _publicProfiles = [NSMutableDictionary dictionary];
        _publicStaticKeys = [NSMutableDictionary dictionary];
        _publicPictures = [NSMutableDictionary dictionary];
        _attempts = [NSMutableDictionary dictionary];
        _dialing = [NSMutableSet set];
        _retryAfter = [NSMutableDictionary dictionary];
        _failures = [NSMutableDictionary dictionary];
        _keptElsewhere = [NSMutableDictionary dictionary];
        _byIDSenders = [NSMutableDictionary dictionary];
        _callbackBroadcasts = [NSMutableDictionary dictionary];
        if (_adapters.count > 0) {
            // Nobody matches until the store has been read (-rebuildTagMatcher at start).
            SZFriendsTagMatcher nobody = ^NSString *(NSData *tag) {
                (void)tag;
                return nil;
            };
            SZFriendsDiscoveryMerger *merger = [[SZFriendsDiscoveryMerger alloc] initWithTagMatcher:nobody];
            _coordinator = [[SZFriendsDiscoveryCoordinator alloc] initWithAdapters:_adapters merger:merger queue:queue
                                                                             clock:^NSDate * { return [NSDate date]; }];
            _coordinator.delegate = self;
            // The adapters apply these per listener and per remote address, before any Diffie-Hellman.
            _coordinator.admissionLimits = SZFriendsHelperTestHooks.admissionLimits ?: SZFriendsNearbyAdmissionLimits();
        }
        // A stored deadline further away than 5 minutes, or already past, is dropped at once: fails closed.
        _visibility = [[SZFriendsVisibility alloc] initWithStoredDeadline:services.store.visibilityDeadline
                                                                     now:SZFriendsInstantNow()];
        if (services.store != nil && _visibility.deadline == nil) services.store.visibilityDeadline = nil;
    }
    return self;
}

#pragma mark - Lifecycle

- (BOOL)ready {
    return self.services.store != nil && self.services.identity != nil && !self.shutDown && !self.resetting &&
           !self.removedFromProfile; // a computer removed from its profile sends nothing (+Devices)
}

- (void)startAtLaunch {
    self.removedFromProfile = self.services.store != nil && [self computeThisComputerRemoved];
    if (![self ready]) return;
    [self rebuildTagMatcher];
    [self refreshAdvertisement];
    // ADR 0004 § Permissions at launch: only adapters that cannot prompt start before the person opens Friends.
    [self.coordinator startAtLaunchWithNearbyPermissionsRequested:self.services.store.nearbyPermissionsRequested];
    [self armWindowTimer];
    [self armVisibilityTimer];
    __weak SZFriendsNearbyService *weakSelf = self;
    _wakeMonitor = [[SZFriendsWakeMonitor alloc] initWithQueue:self.queue
        willSleep:^{ [weakSelf.services.transfers flushProgressWithError:NULL]; }
        didWake:^{ [weakSelf systemDidWake]; }];
    if (self.coordinator != nil) [_wakeMonitor start];
    [self scheduleReconsider];
    [self resumeSecretRenewalAfterStart]; // a while later (+Devices)
    [self startDirectWiFiForOwnHome];     // ADR 0019; never in a test home (+Boost)
}

- (void)activate {
    if (![self ready]) return;
    // Recorded before starting, so the next launch starts Nearby without waiting to be opened again: the prompt,
    // if any, belongs to this open.
    if (!self.services.store.nearbyPermissionsRequested) self.services.store.nearbyPermissionsRequested = YES;
    [self refreshAdvertisement];
    [self.coordinator activate];
    [self changed];
}

- (void)systemDidWake {
    if (![self ready]) return;
    // ADR 0004: after a wake past the deadline, visibility stops before anything else is advertised.
    if (![self.visibility isVisibleAt:SZFriendsInstantNow()]) self.services.store.visibilityDeadline = nil;
    [self rebuildTagMatcher];
    [self refreshAdvertisement];
    [self.coordinator restartAfterWake];
    [self armWindowTimer];
    [self armVisibilityTimer];
    [self scheduleReconsider];
    [self changed];
}

- (void)beginHandover {
    self.handingOver = YES;
}

- (BOOL)workInFlight {
    return [self transfersInFlight];
}

- (void)shutdownWithCompletion:(void (^)(void))completion {
    if (self.shutDown) {
        completion();
        return;
    }
    // Durable first: whatever happens to the CLOSE frames, the next helper resumes from every received byte.
    [self.services.transfers flushProgressWithError:NULL];
    [self stopDirectWiFi]; // END to the friend while the sessions can carry it; the Mac goes back to its network
    for (SZFriendsPeerLink *link in self.links.allObjects) {
        [link cancelTimers];
        [link.channel closeWithReason:SZFriendsCloseReasonShuttingDown];
    }
    self.shutDown = YES;
    [self cancelTimers];
    [_wakeMonitor stop];
    [self.coordinator stop];
    // Online attempts end once their sessions have said CLOSE: ending them first would cut the streams under it.
    __weak SZFriendsNearbyService *weakSelf = self;
    [self waitForLinksThen:^{
        [weakSelf stopOnline];
        completion();
    }
                  deadline:[NSDate dateWithTimeIntervalSinceNow:SZFriendsShutdownFlush]];
}

- (void)waitForLinksThen:(void (^)(void))completion deadline:(NSDate *)deadline {
    if (self.links.count == 0 || deadline.timeIntervalSinceNow <= 0) {
        completion();
        return;
    }
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        if (strongSelf == nil) {
            completion();
            return;
        }
        [strongSelf waitForLinksThen:completion deadline:deadline];
    });
}

- (void)cancelTimers {
    if (_windowTimer != nil) dispatch_source_cancel(_windowTimer);
    if (_visibilityTimer != nil) dispatch_source_cancel(_visibilityTimer);
    _windowTimer = _visibilityTimer = nil;
}

- (void)suspendForReset {
    if (self.resetting) return;
    self.resetting = YES;
    [self stopOnline]; // its attempts speak for the old identity
    [self forgetJoins]; // nothing waits to join a profile that is going away, and this computer joins nothing
    [self.visibility stop];
    // Off the air first, whatever happens to the rest of the reset: a reset that failed after the identity changed
    // used to keep advertising tags old friends could match, linking the old identity to the new one.
    [self.coordinator advertisePresenceTag:nil callbackTags:@[] publicEntry:NO];
    for (SZFriendsPeerLink *link in self.links.allObjects) [link.channel closeWithReason:SZFriendsCloseReasonNormal];
    [self changed];
}

- (void)identityDidReset {
    self.resetting = NO;
    // A new identity starts on its own: no profile's computers, removed or not, and no sync with them (+Devices).
    self.removedFromProfile = NO;
    self.ownRootKeyCache = nil;
    self.syncEngine = nil;
    self.syncKnownDevices = nil;
    // Every session authenticated the old identity; the new one starts with nobody.
    for (SZFriendsPeerLink *link in self.links.allObjects) [link.channel closeWithReason:SZFriendsCloseReasonNormal];
    [self.publicProfiles removeAllObjects];
    [self.publicStaticKeys removeAllObjects];
    [self.publicPictures removeAllObjects];
    [self.callbackBroadcasts removeAllObjects];
    [self.attempts removeAllObjects];
    [self.retryAfter removeAllObjects];
    [self.failures removeAllObjects];
    [self.keptElsewhere removeAllObjects];
    [self.visibility stop];
    [self rebuildTagMatcher];
    [self refreshAdvertisement];
    [self armVisibilityTimer];
    [self changed];
}

#pragma mark - Changes

- (void)changed {
    [self scheduleSyncCapture]; // what changed reaches our other devices while a session with one is live (+Sync)
    if (_changeScheduled) return;
    _changeScheduled = YES;
    // One publish per turn however many frames arrived in it; the publisher rate-limits per subscription too.
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_async(self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf->_changeScheduled = NO;
        if (strongSelf.onChange) strongSelf.onChange();
    });
}

- (void)progressChanged {
    if (self.progressChangeScheduled) return;
    CFTimeInterval since = CFAbsoluteTimeGetCurrent() - self.lastProgressChange;
    NSTimeInterval wait = MAX(0, SZFriendsProgressInterval - since);
    self.progressChangeScheduled = YES;
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.progressChangeScheduled = NO;
        strongSelf.lastProgressChange = CFAbsoluteTimeGetCurrent();
        [strongSelf changed];
    });
}

- (void)peopleChanged {
    if (![self ready]) return;
    [self rebuildTagMatcher];
    [self refreshAdvertisement];
    for (SZFriendsPeerLink *link in self.links.allObjects) {
        if (link.conversationID == nil) continue;
        SZFriendsPersonRecord *person = [self.services.store personWithConversationID:link.conversationID];
        // Blocked people cannot stay connected; removed people only until the answer they wait for is delivered.
        BOOL removedAndDone = person.relation == SZFriendsRelationRemoved &&
                              ![self hasDeliverableEntriesForPerson:person] && link.inFlightEntries.count == 0;
        if (person == nil || person.relation == SZFriendsRelationBlocked || removedAndDone) {
            [link.channel closeWithReason:SZFriendsCloseReasonNormal];
        }
    }
    for (NSString *conversationID in self.activeLinks.allKeys) [self deliverPendingForConversation:conversationID];
    [self scheduleReconsider];
    [self changed];
}

- (void)outboxChangedForConversation:(NSString *)conversationID {
    if (![self ready]) return;
    [self onlineOutboxChangedForConversation:conversationID];
    [self deliverPendingForConversation:conversationID];
    [self scheduleReconsider];
    [self changed];
}

- (void)profileChanged {
    if (![self ready]) return;
    for (SZFriendsPeerLink *link in self.activeLinks.allValues) {
        link.profileSent = NO;
        [self sendProfileOnLink:link];
    }
    [self changed]; // our other computers get the new name and picture too, as any change (+Sync)
}

- (void)transferChanged:(NSString *)transferID {
    if (![self ready]) return;
    SZFriendsTransferRecord *transfer = [self.services.transfers transferWithID:transferID];
    if (transfer == nil) {
        [self stopTransfer:transferID];
        return;
    }
    BOOL running = transfer.state == SZFriendsTransferStateReceiving || transfer.state == SZFriendsTransferStateSending;
    if (!running) [self stopTransfer:transferID];
    // The answer (OFFER_REPLY or CANCEL) goes first, so the sender learns of the acceptance before the PROGRESS.
    [self outboxChangedForConversation:transfer.conversationID];
    SZFriendsPeerLink *link = [self liveLinkForConversation:transfer.conversationID];
    // A download accepted (or retried) now announces where it stands, so the sender starts at once.
    if (link != nil && !transfer.outgoing && transfer.state == SZFriendsTransferStateReceiving) {
        [link.endedTransfers removeObject:transferID];
        [self startTransfersOnLink:link];
    }
}

- (void)historyDeleted {
    for (SZFriendsPeerLink *link in self.links) {
        NSMutableSet<NSString *> *ids = [NSMutableSet setWithArray:link.senders.allKeys];
        [ids addObjectsFromArray:link.receivers.allKeys];
        for (NSString *transferID in ids) {
            if ([self.services.transfers transferWithID:transferID] == nil) [self stopTransfer:transferID];
        }
    }
    [self changed];
}

- (void)keyChangeAccepted:(NSString *)conversationID {
    (void)conversationID;
    // The store made the reviewed key the one IK dials; dial with it now.
    [self scheduleReconsider];
}

#pragma mark - Timers

- (dispatch_source_t)timerWithHandler:(void (^)(SZFriendsNearbyService *service))handler {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        if (strongSelf != nil) handler(strongSelf);
    });
    dispatch_resume(timer);
    return timer;
}

// Every 15-minute window: a new tag (and Bonjour name), the matcher's accepted windows move on, and one-shot
// attempts from older windows are forgotten.
- (void)armWindowTimer {
    if (_windowTimer == nil) {
        _windowTimer = [self timerWithHandler:^(SZFriendsNearbyService *service) { [service windowEnded]; }];
    }
    NSDate *end = SZFriendsPresenceWindowEnd([NSDate date]);
    // Wall-clock based so a Mac that slept across the boundary rotates as soon as it runs again.
    struct timespec when = {.tv_sec = (time_t)ceil(end.timeIntervalSince1970) + 1, .tv_nsec = 0};
    dispatch_source_set_timer(_windowTimer, dispatch_walltime(&when, 0), DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
}

- (void)windowEnded {
    if (![self ready]) return;
    [self rebuildTagMatcher];
    [self refreshAdvertisement];
    [self pruneAttempts];
    // What strangers' public entries said is kept only while the merger still knows them: nobody's profile is
    // remembered after they left.
    NSMutableSet<NSString *> *present = [NSMutableSet set];
    for (SZFriendsCandidate *candidate in self.coordinator.merger.candidates) {
        if (candidate.identityKey != nil) [present addObject:SZFriendsLinkHex(candidate.identityKey)];
    }
    for (NSString *keyHex in self.publicProfiles.allKeys) {
        if ([present containsObject:keyHex]) continue;
        [self.publicProfiles removeObjectForKey:keyHex];
        [self.publicStaticKeys removeObjectForKey:keyHex];
        [self.publicPictures removeObjectForKey:keyHex];
    }
    [self armWindowTimer];
}

- (void)armVisibilityTimer {
    NSTimeInterval remaining = [self.visibility remainingAt:SZFriendsInstantNow()];
    if (remaining <= 0) {
        if (_visibilityTimer != nil) {
            dispatch_source_set_timer(_visibilityTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
        }
        return;
    }
    if (_visibilityTimer == nil) {
        _visibilityTimer = [self timerWithHandler:^(SZFriendsNearbyService *service) { [service visibilityCheck]; }];
    }
    dispatch_source_set_timer(_visibilityTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)((remaining + 0.05) * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 20 * NSEC_PER_MSEC);
}

- (void)visibilityCheck {
    if (![self.visibility isVisibleAt:SZFriendsInstantNow()]) {
        // The deadline stops the public entry on both adapters at once (one advertisement call reaches both).
        self.services.store.visibilityDeadline = nil;
        [self refreshAdvertisement];
        [self changed];
    }
    [self armVisibilityTimer];
}

#pragma mark - Visibility intents

- (NSDate *)startVisibility {
    NSDate *deadline = [self.visibility startAt:SZFriendsInstantNow()];
    self.services.store.visibilityDeadline = deadline;
    [self refreshAdvertisement];
    [self armVisibilityTimer];
    [self changed];
    return deadline;
}

- (void)stopVisibility {
    [self.visibility stop];
    self.services.store.visibilityDeadline = nil;
    [self refreshAdvertisement];
    [self armVisibilityTimer];
    [self changed];
}

#pragma mark - Discovery coordinator

- (void)discoveryCoordinatorDidChangeCandidates:(SZFriendsDiscoveryCoordinator *)coordinator {
    (void)coordinator;
    [self scheduleReconsider];
    [self changed];
}

- (void)discoveryCoordinator:(SZFriendsDiscoveryCoordinator *)coordinator
              didChangeState:(SZFriendsAdapterState)state
                    ofMethod:(SZFriendsDiscoveryMethod)method {
    (void)coordinator, (void)state, (void)method;
    [self changed];
}

- (void)discoveryCoordinator:(SZFriendsDiscoveryCoordinator *)coordinator
             didAcceptStream:(id<SZFriendsByteStream>)stream
                       route:(SZFriendsRouteMethod)route
                 publicEntry:(BOOL)publicEntry {
    (void)coordinator;
    if (![self ready]) {
        [stream close];
        return;
    }
    [self acceptStream:stream route:route publicEntry:publicEntry];
}

@end
