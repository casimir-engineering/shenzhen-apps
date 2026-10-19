// The helper's links (SZFriendsLinks.h): making, registering, serving, revoking and expiring download links, the
// friend link's URL, and receiving a download link in this Mac's apps.

#import "service/links/SZFriendsLinkOpening.h"

#import <sodium.h>

#import "service/host/SZFriendsHostRendezvousInternal.h"
#import "service/identity/SZFriendsIdentity.h"
#import "service/thumbnails/SZFriendsThumbnails.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// One opening being served: its setup, then its upload.
@interface SZFriendsLinkServing : NSObject
@property(nonatomic, strong) SZFriendsLinkSetup *setup;
@property(nonatomic, strong, nullable) SZFriendsLinkUpload *upload;
@property(nonatomic, copy) NSData *linkID;
@end

@implementation SZFriendsLinkServing
@end

@interface SZFriendsLinkService () <SZFriendsLinkSetupDelegate>
@end

static NSDate * (^SZFriendsLinkTestClock)(void);

// The clock expiry reads: the wall clock, unless a test moved it.
static NSDate *SZFriendsLinkNow(void) {
    return SZFriendsLinkTestClock ? SZFriendsLinkTestClock() : [NSDate date];
}

@implementation SZFriendsLinkService {
    SZFriendsStore *_store;
    SZFriendsTransfers *_transfers;
    SZFriendsIdentity *_identity;
    NSString *_linksDirectory;
    dispatch_queue_t _queue;
    NSMutableArray<SZFriendsLinkServing *> *_serving;
    NSMutableSet<SZFriendsLinkOpening *> *_openings;
    // Links revoked while the host could not be told: unregistered at the next connection (this run only).
    NSMutableSet<NSData *> *_unregisterLater;
    NSUInteger _expiryGeneration;
}

- (instancetype)initWithStore:(SZFriendsStore *)store
                    transfers:(SZFriendsTransfers *)transfers
                     identity:(SZFriendsIdentity *)identity
               stateDirectory:(NSString *)stateDirectory
                        queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _store = store;
        _transfers = transfers;
        _identity = identity;
        _linksDirectory = [stateDirectory stringByAppendingPathComponent:@"links"];
        _queue = queue;
        _serving = [NSMutableArray array];
        _openings = [NSMutableSet set];
        _unregisterLater = [NSMutableSet set];
    }
    return self;
}

+ (NSDate * (^)(void))testClock {
    return SZFriendsLinkTestClock;
}

+ (void)setTestClock:(NSDate * (^)(void))clock {
    SZFriendsLinkTestClock = [clock copy];
}

- (NSUInteger)servingCount {
    return _serving.count;
}

static NSString *SZFriendsLinkHexName(NSData *linkID) {
    NSMutableString *hex = [NSMutableString string];
    const uint8_t *bytes = linkID.bytes;
    for (NSUInteger i = 0; i < linkID.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static NSData *SZFriendsLinkRandom(NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    randombytes_buf(data.mutableBytes, length);
    return data;
}

#pragma mark - The host

// link_register for one live link; the host keeps only keyed hashes of the id and of who holds it.
- (void)registerLink:(SZFriendsDownloadLinkRecord *)link {
    SZFriendsHostOnline *online = self.hostOnline;
    if (online == nil || !online.available) return;
    NSTimeInterval left = link.expiresAt.timeIntervalSinceNow;
    if (left <= 0) return;
    int64_t expires = (int64_t)floor([online hostNow] + left);
    [online sendType:@"link_register"
              fields:@{@"link_id" : SZFriendsLinkBase64URLEncode(link.linkID), @"expires" : @(expires)}];
}

// link_tombstones: why ended links ended, by hash only, so whoever opens one is told "revoked" or "expired" at once.
// Sent when a link ends and again on every connection (the host may have restarted, or not heard), at most 64 a
// message. A tombstone also ends the host's binding of a link it still holds, so it goes before link_unregister.
- (void)sendTombstones:(NSArray<SZFriendsLinkTombstone *> *)tombstones {
    SZFriendsHostOnline *online = self.hostOnline;
    if (online == nil || !online.available || tombstones.count == 0) return;
    NSTimeInterval hostNow = [online hostNow];
    NSMutableArray *batch = [NSMutableArray array];
    for (SZFriendsLinkTombstone *tombstone in tombstones) {
        // Never past the host's 31 days by its own clock.
        NSTimeInterval left = MIN(tombstone.until.timeIntervalSinceNow, SZFriendsLinkTombstoneLifetime - 300);
        if (left <= 1) continue;
        [batch addObject:@{@"hash" : SZFriendsLinkBase64URLEncode(tombstone.linkHash), @"reason" : tombstone.reason,
                           @"until" : @((int64_t)floor(hostNow + left))}];
        if (batch.count == 64) {
            [online sendType:@"link_tombstones" fields:@{@"tombstones" : [batch copy]}];
            [batch removeAllObjects];
        }
    }
    if (batch.count > 0) [online sendType:@"link_tombstones" fields:@{@"tombstones" : batch}];
}

- (void)sendTombstonesOfLinks:(NSArray<SZFriendsDownloadLinkRecord *> *)links {
    NSMutableSet<NSData *> *hashes = [NSMutableSet set];
    for (SZFriendsDownloadLinkRecord *link in links) [hashes addObject:SZFriendsLinkTombstoneHash(link.linkID)];
    NSMutableArray *ended = [NSMutableArray array];
    for (SZFriendsLinkTombstone *tombstone in [_store linkTombstonesAtDate:[NSDate date]]) {
        if ([hashes containsObject:tombstone.linkHash]) [ended addObject:tombstone];
    }
    [self sendTombstones:ended];
}

- (void)hostBecameAvailable {
    SZFriendsHostOnline *online = self.hostOnline;
    [self sendTombstones:[_store linkTombstonesAtDate:[NSDate date]]];
    for (NSData *linkID in _unregisterLater) {
        [online sendType:@"link_unregister" fields:@{@"link_id" : SZFriendsLinkBase64URLEncode(linkID)}];
    }
    if (online.available) [_unregisterLater removeAllObjects];
    [self expireLinks];
    for (SZFriendsDownloadLinkRecord *link in [self liveLinks]) [self registerLink:link];
}

#pragma mark - Making and ending links

- (NSArray<SZFriendsDownloadLinkRecord *> *)liveLinks {
    NSDate *now = SZFriendsLinkNow();
    NSMutableArray *live = [NSMutableArray array];
    for (SZFriendsDownloadLinkRecord *link in [_store downloadLinks]) {
        if ([link.expiresAt compare:now] == NSOrderedDescending) [live addObject:link];
    }
    return live;
}

- (void)makeDownloadLinkForPath:(NSString *)path
                    displayName:(NSString *)displayName
                 revisionSHA256:(NSData *)revisionSHA256
                   revisionSize:(NSNumber *)revisionSize
                    expiresDays:(NSInteger)days
                     completion:(void (^)(SZFriendsDownloadLinkRecord *, NSString *, NSError *))completion {
    NSString *origin = self.linkOrigin ? self.linkOrigin() : nil;
    if ((days != 1 && days != 7 && days != 30) || origin == nil) {
        completion(nil, nil, [NSError errorWithDomain:SZFriendsStoreErrorDomain code:SZFriendsStoreErrorInvalid
                                             userInfo:nil]);
        return;
    }
    NSData *linkID = SZFriendsLinkRandom(16), *secret = SZFriendsLinkRandom(32);
    NSString *directory = _linksDirectory;
    NSString *clonePath = [directory stringByAppendingPathComponent:SZFriendsLinkHexName(linkID)];
    NSString *name = displayName.length ? displayName : path.lastPathComponent;
    dispatch_queue_t queue = _queue;
    __weak SZFriendsLinkService *weakSelf = self;
    // Hashing a large file takes a while: off the helper's queue.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions : @0700} error:NULL];
        NSError *error = nil;
        SZFriendsDownloadLinkRecord *link = SZFriendsLinkHoldFile(path, clonePath, &error);
        BOOL revisionDiffers = link != nil && ((revisionSHA256 && ![revisionSHA256 isEqualToData:link.sha256]) ||
                                               (revisionSize && revisionSize.unsignedLongLongValue != link.size));
        if (revisionDiffers) {
            SZFriendsLinkReleaseFile(link, directory);
            link = nil;
            error = [NSError errorWithDomain:SZFriendsStoreErrorDomain code:SZFriendsStoreErrorSourceChanged
                                    userInfo:nil];
        }
        if (link == nil) {
            dispatch_async(queue, ^{ completion(nil, nil, error); });
            return;
        }
        link.linkID = linkID;
        link.secret = secret;
        link.fileName = SZFriendsSanitizedFileName(name);
        link.uniformType = SZFriendsTypeIdentifierForFileName(link.fileName);
        link.createdAt = [NSDate date];
        link.expiresAt = [link.createdAt dateByAddingTimeInterval:(NSTimeInterval)days * 86400];
        [[[SZFriendsThumbnailMaker alloc] init]
            makeThumbnailOfFileAtPath:SZFriendsLinkServedPath(link)
                       typeIdentifier:link.uniformType
                                queue:queue
                           completion:^(SZFriendsThumbnail *thumbnail) {
                               if (thumbnail.png.length <= SZFriendsLinkThumbnailMaxBytes) {
                                   link.thumbnailPNG = thumbnail.png;
                               }
                               [weakSelf storeLink:link origin:origin completion:completion];
                           }];
    });
}

- (void)storeLink:(SZFriendsDownloadLinkRecord *)link
           origin:(NSString *)origin
       completion:(void (^)(SZFriendsDownloadLinkRecord *, NSString *, NSError *))completion {
    NSError *error = nil;
    if (![_store saveDownloadLink:link error:&error]) {
        SZFriendsLinkReleaseFile(link, _linksDirectory);
        completion(nil, nil, error);
        return;
    }
    [self registerLink:link];
    [self scheduleExpiry];
    SZFriendsDownloadLinkPayload *payload = [SZFriendsDownloadLinkPayload new];
    payload.linkID = link.linkID;
    payload.secret = link.secret;
    completion(link, SZFriendsLinkWebURL(origin, [payload payloadString]), nil);
    if (self.onChange) self.onChange();
}

- (void)endLink:(SZFriendsDownloadLinkRecord *)link {
    SZFriendsLinkReleaseFile(link, _linksDirectory);
    for (SZFriendsLinkServing *serving in [_serving copy]) {
        if ([serving.linkID isEqualToData:link.linkID]) [self stopServing:serving];
    }
}

- (BOOL)revokeLinkID:(NSData *)linkID error:(NSError **)error {
    SZFriendsDownloadLinkRecord *link = [_store removeDownloadLink:linkID error:error];
    if (link == nil) return NO;
    [self sendTombstonesOfLinks:@[ link ]];
    SZFriendsHostOnline *online = self.hostOnline;
    if (online.available) {
        [online sendType:@"link_unregister" fields:@{@"link_id" : SZFriendsLinkBase64URLEncode(linkID)}];
    } else {
        [_unregisterLater addObject:linkID];
    }
    [self endLink:link];
    if (self.onChange) self.onChange();
    return YES;
}

- (void)expireLinks {
    NSArray<SZFriendsDownloadLinkRecord *> *expired = [_store removeDownloadLinksExpiredAtDate:SZFriendsLinkNow()
                                                                                        error:NULL];
    [self sendTombstonesOfLinks:expired];
    for (SZFriendsDownloadLinkRecord *link in expired) [self endLink:link];
    if (expired.count > 0 && self.onChange) self.onChange();
    [self scheduleExpiry];
}

// One timer, at the earliest expiry; nothing is scheduled while no link exists.
- (void)scheduleExpiry {
    NSDate *next = nil;
    for (SZFriendsDownloadLinkRecord *link in [_store downloadLinks]) {
        if (next == nil || [link.expiresAt compare:next] == NSOrderedAscending) next = link.expiresAt;
    }
    NSUInteger generation = ++_expiryGeneration;
    if (next == nil) return;
    NSTimeInterval wait = MIN(MAX(next.timeIntervalSinceNow, 0) + 1, 3600);
    __weak SZFriendsLinkService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), _queue, ^{
        SZFriendsLinkService *service = weakSelf;
        if (service != nil && service->_expiryGeneration == generation) [service expireLinks];
    });
}

#pragma mark - The friend link

- (NSString *)friendLinkURLWithFriendsID:(NSString *)friendsID name:(NSString *)name {
    NSString *origin = self.linkOrigin ? self.linkOrigin() : nil;
    SZFriendsInviteRecord *invite = origin ? [_store standingInviteCreatingIfNeeded:YES error:NULL] : nil;
    if (invite == nil) return nil;
    SZFriendsFriendLinkPayload *payload = [SZFriendsFriendLinkPayload new];
    payload.identityKey = _identity.publicKey;
    payload.inviteToken = invite.token;
    payload.friendsID = friendsID;
    // A name too long for the link is left out rather than cut: the page then names the Friends ID.
    payload.name = [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= SZFriendsLinkNameMax ? name ?: @"" : @"";
    NSString *text = [payload payloadString];
    return text ? SZFriendsLinkWebURL(origin, text) : nil;
}

- (BOOL)resetFriendLinkWithError:(NSError **)error {
    BOOL reset = [_store resetStandingInviteAtDate:[NSDate date] error:error] != nil;
    if (reset && self.onChange) self.onChange();
    return reset;
}

#pragma mark - Serving

- (BOOL)receiveOpenOfLinkID:(NSData *)linkID channel:(id)channel payload:(NSData *)payload {
    SZFriendsDownloadLinkRecord *link = [_store downloadLinkWithID:linkID];
    SZFriendsLinkEnvironment *environment = self.environment ? self.environment() : nil;
    SZFriendsLinkKeys *keys = link ? [[SZFriendsLinkKeys alloc] initWithLinkID:link.linkID secret:link.secret] : nil;
    if (keys == nil || environment == nil || ![channel conformsToProtocol:@protocol(SZFriendsOnlineSignalChannel)]) {
        return NO;
    }
    BOOL expired = [link.expiresAt compare:SZFriendsLinkNow()] != NSOrderedDescending;
    SZFriendsLinkServing *serving = [SZFriendsLinkServing new];
    serving.linkID = link.linkID;
    serving.setup = [[SZFriendsLinkSetup alloc] initSenderWithKeys:keys channel:channel environment:environment];
    serving.setup.delegate = self;
    if (![serving.setup receiveHello:payload refusing:expired ? SZFriendsLinkEndExpired : nil]) return NO;
    [_serving addObject:serving];
    return YES;
}

- (SZFriendsLinkServing *)servingForSetup:(SZFriendsLinkSetup *)setup {
    for (SZFriendsLinkServing *serving in _serving) {
        if (serving.setup == setup) return serving;
    }
    return nil;
}

- (void)stopServing:(SZFriendsLinkServing *)serving {
    [_serving removeObject:serving];
    [serving.upload close];
    [serving.setup close];
}

// Gating's last step: the link is still live and its file still the one it was made for, checked only now that the
// opener has proved the secret, and before any connection exists.
- (NSString *)linkSetupOpenerProved:(SZFriendsLinkSetup *)setup {
    SZFriendsDownloadLinkRecord *link = [_store downloadLinkWithID:setup.keys.linkID];
    if (link == nil) return SZFriendsLinkEndRevoked;
    if ([link.expiresAt compare:SZFriendsLinkNow()] != NSOrderedDescending) return SZFriendsLinkEndExpired;
    return SZFriendsLinkSourceUnchanged(link) ? nil : SZFriendsLinkEndChanged;
}

- (void)linkSetup:(SZFriendsLinkSetup *)setup didFail:(SZFriendsLinkOutcome)outcome {
    (void)outcome;
    SZFriendsLinkServing *serving = [self servingForSetup:setup];
    if (serving) [self stopServing:serving];
}

- (SZFriendsLinkMetadata *)metadataForLink:(SZFriendsDownloadLinkRecord *)link {
    SZFriendsLinkMetadata *metadata = [SZFriendsLinkMetadata new];
    metadata.name = link.fileName;
    metadata.size = link.size;
    UTType *type = link.uniformType ? [UTType typeWithIdentifier:link.uniformType] : nil;
    metadata.mediaType = type.preferredMIMEType ?: @"application/octet-stream";
    metadata.sha256 = link.sha256;
    metadata.thumbnailPNG = link.thumbnailPNG;
    metadata.senderName = self.profileName ? self.profileName() : nil;
    metadata.senderFriendsID = _store.friendsID;
    metadata.senderIdentityKey = _identity.publicKey;
    metadata.blake2b = link.blake2b;
    metadata.senderSignature = [_identity signatureForMessage:[metadata signedBytesForLinkID:link.linkID]
                                                       domain:SZFriendsLinkSenderDomain];
    return metadata;
}

- (void)linkSetup:(SZFriendsLinkSetup *)setup didOpenStream:(id<SZFriendsByteStream>)stream attempt:(uint8_t)attempt {
    SZFriendsLinkServing *serving = [self servingForSetup:setup];
    SZFriendsDownloadLinkRecord *link = [_store downloadLinkWithID:setup.keys.linkID];
    if (serving == nil || link == nil) {
        [stream close];
        if (serving) [self stopServing:serving];
        return;
    }
    serving.upload = [[SZFriendsLinkUpload alloc] initWithStream:stream link:link metadata:[self metadataForLink:link]
                                                      contentKey:[setup.keys contentKeyForAttempt:attempt]
                                                           queue:_queue];
    SZFriendsLinkEnvironment *environment = self.environment ? self.environment() : nil;
    if (environment) serving.upload.startTimeout = environment.startTimeout;
    __weak SZFriendsLinkService *weakSelf = self;
    __weak SZFriendsLinkServing *weakServing = serving;
    serving.upload.onFinish = ^(BOOL downloaded) {
        SZFriendsLinkService *service = weakSelf;
        SZFriendsLinkServing *finished = weakServing;
        if (service == nil || finished == nil) return;
        if (downloaded && [service->_store countDownloadOfLink:finished.linkID error:NULL] && service.onChange) {
            service.onChange();
        }
        // A moment for the opener to read the last records before the connection goes.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), service->_queue, ^{
            [weakSelf stopServing:finished];
        });
    };
    [serving.upload start];
}

#pragma mark - Receiving in this Mac's apps

- (void)receiveLink:(SZFriendsDownloadLinkPayload *)payload
            started:(void (^)(NSString *, SZFriendsLinkMetadata *, SZFriendsLinkOutcome))started {
    SZFriendsLinkEnvironment *environment = self.environment ? self.environment() : nil;
    SZFriendsHostOnline *online = self.hostOnline;
    SZFriendsLinkReceiver *receiver = [[SZFriendsLinkReceiver alloc] initWithStore:_store transfers:_transfers
                                                                       ownIdentity:_identity.publicKey
                                                                            linkID:payload.linkID];
    SZFriendsLinkOpening *opening = environment && online.available
                                        ? [[SZFriendsLinkOpening alloc] initWithLinkID:payload.linkID
                                                                                secret:payload.secret
                                                                           environment:environment
                                                                                  sink:receiver]
                                        : nil;
    if (opening == nil) {
        started(nil, nil, SZFriendsLinkOutcomeUnavailable);
        return;
    }
    __block void (^once)(NSString *, SZFriendsLinkMetadata *, SZFriendsLinkOutcome) = [started copy];
    __weak SZFriendsLinkReceiver *weakReceiver = receiver;
    receiver.onStarted = ^(SZFriendsLinkMetadata *metadata) {
        if (once) once(weakReceiver.conversationID, metadata, SZFriendsLinkOutcomeDone);
        once = nil;
    };
    [_openings addObject:opening];
    __weak SZFriendsLinkService *weakSelf = self;
    __weak SZFriendsLinkOpening *weakOpening = opening;
    [opening startWithOpen:^(NSData *hello, void (^done)(id, BOOL)) {
        [online openToLinkID:payload.linkID payload:hello completion:^(SZFriendsHostSignal *signal, NSError *error) {
            if ([error.domain isEqual:SZFriendsHostOnlineErrorDomain] &&
                error.code == SZFriendsHostOnlineErrorLinkEnded) {
                [weakOpening noteLinkEnded]; // revoked or expired: not_found, as the sender itself would say
            }
            done(signal ? SZFriendsOnlineChannelForSignal(signal) : nil, signal.ownerOnline);
        }];
    }
        completion:^(SZFriendsLinkOutcome outcome) {
            if (once) once(nil, nil, outcome);
            once = nil;
            SZFriendsLinkService *service = weakSelf;
            if (service == nil) return;
            [service->_openings removeObject:weakOpening];
            if (service.onChange) service.onChange();
            (void)receiver; // kept until the opening ends
        }];
}

@end
