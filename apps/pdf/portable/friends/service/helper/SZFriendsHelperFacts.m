// Store records to presentation facts, computed once per publish pass (SZFriendsHelperFacts.h).

#import "service/helper/SZFriendsHelperFacts.h"
#import "service/helper/SZFriendsHelperLinks.h"
#import "service/store/SZFriendsStoreLinks.h"
#import "service/store/SZFriendsStoreSync.h"
#import "service/sync/SZFriendsSync.h"

#import "service/helper/nearby/SZFriendsNearbyDevices.h"
#import "service/transfer/SZFriendsDirectWiFiBoost.h"
#import "service/store/SZFriendsTransferThumbnails.h"
#import "service/thumbnails/SZFriendsThumbnails.h"

static SZFriendsPersonRelation SZFriendsPersonRelationFromStore(SZFriendsRelation relation) {
    switch (relation) {
        case SZFriendsRelationIncomingRequest: return SZFriendsPersonRelationIncomingRequest;
        case SZFriendsRelationOutgoingRequest: return SZFriendsPersonRelationOutgoingRequest;
        case SZFriendsRelationFriend: return SZFriendsPersonRelationFriend;
        case SZFriendsRelationRemoved: return SZFriendsPersonRelationRemoved;
        case SZFriendsRelationBlocked: return SZFriendsPersonRelationBlocked;
    }
    return SZFriendsPersonRelationRemoved;
}

SZFriendsItemFacts *SZFriendsItemFactsFromRecord(SZFriendsItemRecord *record, SZFriendsHelperServices *services) {
    SZFriendsItemFacts *facts = [[SZFriendsItemFacts alloc] init];
    facts.itemID = record.itemID;
    facts.conversationID = record.conversationID;
    facts.outgoing = record.direction == SZFriendsDirectionOutgoing;
    facts.sentAt = record.sentAt;
    facts.text = record.text;
    facts.viaAssistant = record.viaAssistant;
    facts.eventKind = record.eventKind;
    facts.eventArguments = record.eventArguments;
    switch (record.kind) {
        case SZFriendsItemKindMessage: facts.kind = SZFriendsItemFactsKindMessage; break;
        case SZFriendsItemKindTransfer: facts.kind = SZFriendsItemFactsKindTransfer; break;
        case SZFriendsItemKindEvent: facts.kind = SZFriendsItemFactsKindEvent; break;
    }
    // The store reads each item's outbox state with it. Delivered entries stay in the outbox, so -1 means the store
    // has no record of a delivery at all (history from before), and the presentation then claims nothing, unless the
    // person cancelled the message, whose entry went with the cancel.
    facts.outboxState = record.outboxState;
    facts.failureReason = record.outboxFailureReason;
    facts.cancelled = record.cancelled;
    facts.outboxWritten = record.outboxWritten;
    if (record.kind == SZFriendsItemKindTransfer && record.transferID != nil) {
        SZFriendsTransferRecord *transfer = [services.transfers transferWithID:record.transferID];
        facts.transferID = record.transferID;
        if (transfer != nil) {
            facts.fileName = transfer.fileName;
            facts.fileExtension = transfer.fileName.pathExtension.lowercaseString;
            facts.fileSize = transfer.size;
            facts.bytesDone = transfer.verifiedBytes;
            facts.transferState = transfer.state;
            facts.acceptedAutomatically = transfer.acceptedAutomatically;
            facts.askedBecauseDiskLow = transfer.askedBecauseDiskLow;
            facts.bytesPerSecond = transfer.measuredBytesPerSecond;
            facts.localPath = transfer.receivedPath;
            if (transfer.receivedPath.length && !facts.outgoing) {
                switch (SZFriendsSavedPlaceOfFile(services.paths.stateDirectory, transfer.receivedPath)) {
                    case SZFriendsSavedPlaceDownloads: facts.savedToDownloads = YES; break;
                    case SZFriendsSavedPlaceFolder:
                        facts.savedFolderName =
                            transfer.receivedPath.stringByDeletingLastPathComponent.lastPathComponent;
                        break;
                    case SZFriendsSavedPlaceKept: break;
                }
            }
            // Moved or deleted by the person (ADR 0016): no path; the item says where the file still is.
            BOOL copyHere = transfer.receivedPath.length > 0 &&
                            (transfer.outgoing || transfer.state == SZFriendsTransferStateReceived);
            if (copyHere && SZFriendsSyncLocalPathOfTransfer(transfer) == nil) {
                facts.fileMissing = YES;
                facts.localPath = nil;
                facts.savedToDownloads = NO;
                facts.savedFolderName = nil;
                // Our other computers hear that this one no longer holds it, while a session with one is live.
                [services.nearby scheduleSyncCapture];
            }
            facts.fileTypeIdentifier = SZFriendsTypeIdentifierForFileName(transfer.fileName);
            // A row whose file is gone (a crash between the two) shows no preview rather than a broken one, and a
            // received file never shows the sender's picture: once it is here, only our own preview of it counts.
            SZFriendsThumbnailRecord *thumbnail = [services.transfers thumbnailForTransfer:record.transferID];
            BOOL superseded = thumbnail.source == SZFriendsThumbnailSourceSender &&
                              transfer.state == SZFriendsTransferStateReceived;
            if (thumbnail != nil && !superseded && [NSFileManager.defaultManager fileExistsAtPath:thumbnail.path]) {
                facts.thumbnailPath = thumbnail.path;
                facts.thumbnailWidth = thumbnail.width;
                facts.thumbnailHeight = thumbnail.height;
                facts.thumbnailFromSender = thumbnail.source == SZFriendsThumbnailSourceSender;
            }
            facts.failureReason = transfer.failureReason ?: record.outboxFailureReason;
            facts.transferRoute = SZFriendsRouteMethodNone;
            // A moving transfer shows what arrived (or what the recipient made durable) right now, the link carrying
            // it and its measured rate, not only what the store committed in its last batch.
            SZFriendsLiveTransfer live;
            if ([services.nearby liveTransfer:record.transferID state:&live]) {
                facts.bytesDone = MAX(facts.bytesDone, live.bytes);
                facts.transferRoute = live.route;
                if (live.bytesPerSecond > 0) facts.bytesPerSecond = live.bytesPerSecond;
            }
            facts.finishing = !transfer.outgoing && [services.nearby transferShowsFinishing:record.transferID];
            SZFriendsBoostRow *boost = [services.nearby boostRowForTransfer:record.transferID];
            if (boost != nil) {
                facts.boostStage = boost.stage;
                facts.boostNetwork = boost.network;
                facts.boostLeavesWiFi = boost.leavesWiFi;
                facts.boostOverEthernet = boost.overEthernet;
                facts.boostBluetoothSeconds = boost.bluetoothSeconds;
                facts.boostDirectSeconds = boost.directSeconds;
            }
        } else {
            // A file another device of ours has (sync): its record is here at once, its bytes when copied.
            SZFriendsSyncFileRecord *file = [services.store syncFileWithID:record.transferID];
            if (file != nil) {
                facts.fileName = file.fileName;
                facts.fileExtension = file.fileName.pathExtension.lowercaseString;
                facts.fileSize = file.size;
                facts.transferState = file.state;
                facts.fileTypeIdentifier = SZFriendsTypeIdentifierForFileName(file.fileName);
                facts.transferRoute = SZFriendsRouteMethodNone;
                // Received on another computer, and no computer of the profile holds it any more.
                facts.fileMissing = !file.outgoing && file.state == SZFriendsTransferStateReceived &&
                                    ![services.nearby anotherComputerHoldsFile:file];
            }
        }
        if (facts.fileMissing && !facts.outgoing) {
            facts.again = [services.nearby againStateOfTransfer:record.transferID];
            double fraction = 0;
            BOOL copying = [services.nearby againCopyingTransfer:record.transferID fraction:&fraction];
            facts.againConnected = copying || [services.nearby againReachesConversation:record.conversationID];
            facts.againFraction = fraction;
        }
    }
    return facts;
}

NSDictionary<NSString *, id> *SZFriendsHelperReceivedSnapshot(SZFriendsHelperServices *services) {
    NSMutableArray *files = [NSMutableArray array];
    for (SZFriendsReceivedFile *file in [services.transfers receivedFilesWithLimit:100] ?: @[]) {
        NSString *source = file.source == SZFriendsReceivedSourceLink     ? @"link"
                           : file.source == SZFriendsReceivedSourceDevice ? @"device"
                                                                          : @"friend";
        [files addObject:@{
            @"transfer_id" : file.transferID,
            @"path" : file.path,
            @"file_name" : file.path.lastPathComponent,
            @"received_at" : @((long long)floor(file.receivedAt.timeIntervalSince1970)),
            @"source" : source
        }];
    }
    return @{@"files" : files};
}

NSArray<NSString *> *SZFriendsHelperCapabilityList(SZFriendsHelperServices *services) {
    // Only what this helper really does: a view must not offer a search that cannot find anyone. A helper under
    // SZFRIENDS_STATE_DIR runs only the adapters a test asked for and checks in only with a loopback host.
    NSMutableArray<NSString *> *capabilities = [NSMutableArray array];
    SZFriendsNearbyService *nearby = services.nearby;
    if ([nearby hasAdapterForMethod:SZFriendsDiscoveryMethodNetwork]) [capabilities addObject:@"nearby.network"];
    if ([nearby hasAdapterForMethod:SZFriendsDiscoveryMethodBluetooth]) [capabilities addObject:@"nearby.bluetooth"];
    if (services.checkInSetup != nil) [capabilities addObject:@"host.checkin"];
    // Links are made for the Friends host's pages, so only a helper that checks in offers them (PROTOCOL.md § Links).
    if (services.checkInSetup != nil && services.store != nil && services.identity != nil) {
        [capabilities addObject:@"links"];
    }
    [capabilities addObject:@"messages.status"];
    [capabilities addObject:@"messages.cancel"];
    [capabilities addObject:@"mentions"];
    // One profile on several computers: Your computers, joining, You (PROTOCOL.md § Devices).
    if (services.store != nil && services.identity != nil && nearby != nil) [capabilities addObject:@"devices"];
    // Files a friend sent come back from them when none of the person's computers has them (§ Getting a file again).
    if (services.store != nil && services.identity != nil && nearby != nil) [capabilities addObject:@"files.again"];
    // Received files go to Downloads or the folder the person chose (PROTOCOL.md § Views, settings and received).
    if (services.transfers != nil) [capabilities addObject:@"received.folder"];
    if (nearby.reachesFriendsOnline) [capabilities addObject:@"online"];
    // This helper posts system notifications (PROTOCOL.md § Notifications).
    if (services.notifier != nil) [capabilities addObject:@"notifications"];
    return capabilities;
}

@implementation SZFriendsFactsPass {
    SZFriendsHelperServices *_services;
    NSArray<SZFriendsPersonRecord *> *_records;
    NSMutableDictionary<NSString *, SZFriendsItemRecord *> *_newest;
    NSMutableDictionary<NSString *, SZFriendsItemRecord *> *_messages; // each person's newest message or file, by id
    NSArray<SZFriendsPersonFacts *> *_people;
    NSDictionary<NSString *, SZFriendsPersonFacts *> *_peopleByConversation;
    NSDictionary<NSString *, SZFriendsItemFacts *> *_previewItems;
    SZFriendsProfileFacts *_profile;
    SZFriendsNearbyFacts *_nearby;
    SZFriendsMentionDirectory *_mentionDirectory;
    NSSet<NSString *> *_helperCapabilities;
    NSSet<NSString *> *_linkContacts;
    NSDictionary<NSString *, NSArray<NSNumber *> *> *_foundMethods;
    SZFriendsDevicesFacts *_devices;
    BOOL _devicesRead;
}

- (NSSet<NSString *> *)helperCapabilities {
    if (_helperCapabilities == nil) _helperCapabilities = [NSSet setWithArray:SZFriendsHelperCapabilityList(_services)];
    return _helperCapabilities;
}

- (instancetype)initWithServices:(SZFriendsHelperServices *)services now:(NSDate *)now {
    if ((self = [super init])) {
        _services = services;
        _now = now;
        _newest = [NSMutableDictionary dictionary];
        _messages = [NSMutableDictionary dictionary];
    }
    return self;
}

// The newest item of a conversation: what its row's subtitle describes.
- (nullable SZFriendsItemRecord *)newestItemInConversation:(NSString *)conversationID {
    id cached = _newest[conversationID];
    if (cached != nil) return cached == [NSNull null] ? nil : cached;
    BOOL hasEarlier = NO;
    SZFriendsItemRecord *newest = [_services.store itemsInConversation:conversationID beforeItemID:nil limit:1
                                                            hasEarlier:&hasEarlier].lastObject;
    _newest[conversationID] = newest ?: (id)[NSNull null];
    return newest;
}

// The newest message or file of a conversation (a file received through a link counts; other events do not), and how
// many files went with it: the same kind from the same side, each within a minute of the next (at most 50, as the
// Rust helper counts).
- (nullable SZFriendsItemRecord *)lastMessageInConversation:(NSString *)conversationID
                                                  fileCount:(NSInteger *)fileCount {
    *fileCount = 0;
    SZFriendsItemRecord *newest = nil, *later = nil;
    NSString *before = nil;
    for (BOOL more = YES; more;) {
        BOOL hasEarlier = NO;
        NSArray<SZFriendsItemRecord *> *page = [_services.store itemsInConversation:conversationID beforeItemID:before
                                                                              limit:50
                                                                         hasEarlier:&hasEarlier];
        for (SZFriendsItemRecord *record in page.reverseObjectEnumerator) {
            if (before && [record.itemID isEqualToString:before]) continue; // a page ends at the one before it
            if (record.kind == SZFriendsItemKindEvent &&
                ![record.eventKind isEqualToString:SZFriendsEventReceivedLinkFile])
                continue;
            if (newest == nil) {
                newest = later = record;
                if (record.kind == SZFriendsItemKindMessage) return newest;
                *fileCount = 1;
                continue;
            }
            if (record.kind != newest.kind || record.direction != newest.direction || *fileCount >= 50 ||
                [later.sentAt timeIntervalSinceDate:record.sentAt] > 60)
                return newest;
            later = record;
            (*fileCount)++;
        }
        more = hasEarlier && page.count > (before ? 1 : 0);
        before = page.firstObject.itemID;
    }
    return newest;
}

- (NSArray<SZFriendsPersonRecord *> *)records {
    if (_records == nil) _records = _services.store != nil ? [_services.store peopleByLatestInteraction] : @[];
    return _records;
}

- (SZFriendsPersonFacts *)factsForRecord:(SZFriendsPersonRecord *)record {
    SZFriendsTransfers *transfers = _services.transfers;
    SZFriendsPersonFacts *facts = [[SZFriendsPersonFacts alloc] init];
    facts.conversationID = record.conversationID;
    facts.name = record.name;
    facts.friendsID = record.friendsID;
    facts.identityKey = record.identityKey;
    facts.picture = record.picture ?: [SZFriendsPicture placeholder];
    facts.relation = SZFriendsPersonRelationFromStore(record.relation);
    // Local while a session is up, on its route (Internet or Relay for one online, which shows as Online); Offline
    // otherwise. A request by ID that never reached anyone has no route to show at all.
    SZFriendsRouteMethod live = [_services.nearby liveRouteForConversation:record.conversationID];
    if (live != SZFriendsRouteMethodNone) {
        facts.routeKind = SZFriendsRouteKindLocal;
        facts.routeMethod = live;
    } else {
        // A request from a mention knows the key but has never met a static key: nothing to show either.
        BOOL neverConnected = record.identityKey == nil || record.staticKey == nil;
        facts.routeKind = neverConnected ? SZFriendsRouteKindNone : SZFriendsRouteKindOffline;
        facts.routeMethod = SZFriendsRouteMethodNone;
        // Whether an online attempt is worth mentioning: Connecting, Couldn’t connect, or neither.
        if (!neverConnected) facts.onlineReach = [_services.nearby onlineReachForPerson:record now:_now];
    }
    facts.verified = record.verified;
    facts.verifiedAt = record.verifiedAt;
    // The store says confirmed only while friendsID is still the ID the host attested for this key.
    facts.friendsIDConfirmed = record.friendsIDConfirmed;
    facts.autoAccept = record.autoAccept;
    facts.keyChangePending = record.keyChangePending;
    facts.unreadCount = record.unreadCount;
    facts.offersWaiting = (NSInteger)[transfers pendingIncomingOfferCountForConversation:record.conversationID];
    facts.lastInteractionAt = record.lastInteractionAt ?: [NSDate dateWithTimeIntervalSince1970:0];
    facts.lastPreviewItemID = [self newestItemInConversation:record.conversationID].itemID;
    NSInteger files = 0;
    SZFriendsItemRecord *message = [self lastMessageInConversation:record.conversationID fileCount:&files];
    facts.lastMessageItemID = message.itemID;
    facts.lastMessageFileCount = files;
    if (message != nil) _messages[message.itemID] = message;
    facts.requestAt = record.requestAt;
    facts.requestFoundNearby = record.requestFoundNearby;
    facts.unconfirmedAnswerID = record.unconfirmedAnswerID;
    facts.comparisonCode = record.comparisonCode;
    NSInteger received = 0;
    for (SZFriendsTransferRecord *transfer in [transfers transfersInConversation:record.conversationID]) {
        if (!transfer.outgoing && transfer.state == SZFriendsTransferStateReceived) received++;
    }
    facts.receivedFileCount = received;
    facts.receivedRevealPath = self.profile.receivedDirectory;
    if (_linkContacts == nil) _linkContacts = [_services.store linkContactConversationIDs] ?: [NSSet set];
    facts.linkContact = [_linkContacts containsObject:record.conversationID];
    facts.leftList = record.leftListAt != nil;
    // How a friend nearby was found, for their row (nearby.found).
    if (record.relation == SZFriendsRelationFriend) {
        if (_foundMethods == nil) _foundMethods = [_services.nearby foundMethodsByConversation] ?: @{};
        facts.foundMethods = _foundMethods[record.conversationID];
    }
    return facts;
}

- (NSArray<SZFriendsPersonFacts *> *)people {
    if (_people == nil) {
        NSMutableArray *people = [NSMutableArray array];
        NSMutableDictionary *byConversation = [NSMutableDictionary dictionary];
        for (SZFriendsPersonRecord *record in [self records]) {
            SZFriendsPersonFacts *facts = [self factsForRecord:record];
            // You is nobody's friend: its row and header are the devices facts' (+Devices); its conversation opens.
            if ([record.conversationID isEqualToString:SZFriendsYouConversationID]) {
                facts.routeKind = SZFriendsRouteKindNone;
                facts.onlineReach = SZFriendsOnlineReachUnknown;
            } else {
                [people addObject:facts];
            }
            byConversation[facts.conversationID] = facts;
        }
        _people = people;
        _peopleByConversation = byConversation;
    }
    return _people;
}

- (nullable SZFriendsPersonFacts *)personWithConversationID:(NSString *)conversationID {
    (void)[self people];
    return _peopleByConversation[conversationID];
}

- (NSDictionary<NSString *, SZFriendsItemFacts *> *)previewItems {
    if (_previewItems == nil) {
        NSMutableDictionary *previews = [NSMutableDictionary dictionary];
        for (SZFriendsPersonFacts *person in self.people) {
            SZFriendsItemRecord *newest = [self newestItemInConversation:person.conversationID];
            // Keyed by item id: each row's newest item, and the message or file the builder looks up by its
            // lastMessageItemID.
            if (newest != nil) previews[newest.itemID] = SZFriendsItemFactsFromRecord(newest, _services);
            SZFriendsItemRecord *message = person.lastMessageItemID ? _messages[person.lastMessageItemID] : nil;
            if (message != nil && previews[message.itemID] == nil)
                previews[message.itemID] = SZFriendsItemFactsFromRecord(message, _services);
        }
        _previewItems = previews;
    }
    return _previewItems;
}

- (NSInteger)waitingCountExcluding:(nullable NSString *)conversationID {
    NSInteger count = 0;
    for (SZFriendsPersonFacts *person in self.people) {
        if (conversationID != nil && [person.conversationID isEqualToString:conversationID]) continue;
        if (person.leftList) continue; // off the list: nothing of theirs waits in it
        if (person.relation == SZFriendsPersonRelationIncomingRequest || person.offersWaiting > 0 ||
            person.keyChangePending) {
            count++;
        }
    }
    return count;
}

- (NSArray<SZFriendsItemFacts *> *)itemsInConversation:(NSString *)conversationID
                                                window:(NSUInteger)window
                                            hasEarlier:(BOOL *)hasEarlier {
    BOOL earlier = NO;
    NSArray<SZFriendsItemRecord *> *records = [_services.store itemsInConversation:conversationID
                                                                       beforeItemID:nil
                                                                              limit:window
                                                                         hasEarlier:&earlier];
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:records.count];
    for (SZFriendsItemRecord *record in records) [items addObject:SZFriendsItemFactsFromRecord(record, _services)];
    if (hasEarlier) *hasEarlier = earlier;
    return items;
}

- (NSArray<SZFriendsItemFacts *> *)outgoingMessagesWithIDs:(NSArray<NSString *> *)messageIDs {
    NSMutableArray *messages = [NSMutableArray arrayWithCapacity:messageIDs.count];
    for (SZFriendsItemRecord *record in [_services.store outgoingMessagesWithIDs:messageIDs])
        [messages addObject:SZFriendsItemFactsFromRecord(record, _services)];
    return messages;
}

- (nullable SZFriendsDevicesFacts *)devices {
    if (!_devicesRead) {
        _devicesRead = YES;
        if ([self.helperCapabilities containsObject:@"devices"]) _devices = [_services.nearby devicesFactsAtDate:_now];
    }
    return _devices;
}

- (SZFriendsProfileFacts *)profile {
    if (_profile == nil) {
        SZFriendsStore *store = _services.store;
        SZFriendsProfileFacts *profile = [[SZFriendsProfileFacts alloc] init];
        profile.name = store.profileName;
        profile.friendsID = store.friendsID ?: @"";
        profile.friendsIDState = store != nil ? store.friendsIDState : SZFriendsIDStateUnreserved;
        profile.previousFriendsID = store.previousFriendsID;
        profile.picture = store.profilePicture ?: [SZFriendsPicture placeholder];
        profile.identityPublicKey = _services.identity.publicKey ?: [NSData data];
        profile.identityState = _services.identity != nil ? SZFriendsIdentityFactsStateReady
                                                          : SZFriendsIdentityFactsStateUnavailable;
        profile.updateNeed = _services.updateNeed;
        SZFriendsTransfers *transfers = _services.transfers;
        NSString *stateDirectory = _services.paths.stateDirectory;
        profile.receivedDirectory =
            transfers ? transfers.destinationDirectory : SZFriendsReceivedFolder(stateDirectory);
        profile.receivedFolderName = SZFriendsChosenReceivedFolder(stateDirectory).lastPathComponent;
        switch (SZFriendsLastReceivedFallback(stateDirectory)) {
            case SZFriendsReceivedFallbackNone: break;
            case SZFriendsReceivedFallbackDownloads:
                profile.receivedFallback = SZFriendsReceivedFallbackFactsDownloads;
                break;
            case SZFriendsReceivedFallbackKept: profile.receivedFallback = SZFriendsReceivedFallbackFactsKept; break;
        }
        _profile = profile;
    }
    return _profile;
}

- (SZFriendsProfileFacts *)profileWithLinks {
    SZFriendsProfileFacts *profile = self.profile;
    if (profile.links == nil && [self.helperCapabilities containsObject:@"links"]) {
        profile.links = SZFriendsHelperLinksFacts(_services, _now);
    }
    return profile;
}

- (SZFriendsMentionDirectory *)mentionDirectory {
    if (_mentionDirectory == nil) {
        _mentionDirectory = [[SZFriendsMentionDirectory alloc] initWithPeople:self.people profile:self.profile];
    }
    return _mentionDirectory;
}

- (SZFriendsNearbyFacts *)nearby {
    if (_nearby == nil) {
        SZFriendsNearbyFacts *nearby = [[SZFriendsNearbyFacts alloc] init];
        NSDate *deadline = _services.store.visibilityDeadline;
        nearby.visibilityDeadline = [deadline compare:_now] == NSOrderedDescending ? deadline : nil;
        SZFriendsNearbyService *service = _services.nearby;
        // Without the service (no store or identity) neither method can run; Nearby says so rather than presenting
        // an empty successful search.
        nearby.networkState = service ? [service stateOfMethod:SZFriendsDiscoveryMethodNetwork]
                                      : SZFriendsAdapterStateUnavailable;
        nearby.bluetoothState = service ? [service stateOfMethod:SZFriendsDiscoveryMethodBluetooth]
                                        : SZFriendsAdapterStateUnavailable;
        nearby.searching = nearby.networkState == SZFriendsAdapterStateWorking ||
                           nearby.bluetoothState == SZFriendsAdapterStateWorking;
        nearby.people = service ? [service nearbyPeople] : @[];
        _nearby = nearby;
    }
    return _nearby;
}

@end
