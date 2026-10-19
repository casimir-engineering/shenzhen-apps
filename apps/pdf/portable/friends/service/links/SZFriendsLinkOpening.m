// Opening a download link from the opener's end (SZFriendsLinks.h): the setup, then the download into a sink. And the
// sink an app's receive_link uses: the file arrives as a received transfer in the sender's conversation.
//
// A download whose connection drops mid-file (the relay ends sessions after an hour; networks change) carries on, as
// a transfer resumes (ADR 0001): a new setup with fresh nonces and keys, then a download from the first chunk not yet
// written, into the same transfer. It gives up after SZFriendsLinkResumesWithoutProgress drops in a row that brought
// nothing new.

#import "service/links/SZFriendsLinkOpening.h"

#import "service/identity/SZFriendsIdentity.h"
#import "service/thumbnails/SZFriendsThumbnails.h"

NSString *const SZFriendsLinkSenderDomain = @"SZFriends link sender v1";
NSString *const SZFriendsEventReceivedThroughLink = @"received_through_link";
static const NSUInteger SZFriendsLinkResumesWithoutProgress = 3;

@interface SZFriendsLinkOpening () <SZFriendsLinkSetupDelegate>
@end

@implementation SZFriendsLinkOpening {
    SZFriendsLinkSetup *_setup;
    SZFriendsLinkDownload *_download;
    SZFriendsLinkEnvironment *_environment;
    id<SZFriendsLinkSink> _sink;
    void (^_completion)(SZFriendsLinkOutcome);
    void (^_open)(NSData *, void (^)(id, BOOL));
    NSData *_linkID, *_secret;
    NSUInteger _stalls;
    uint64_t _resumedAt;
    BOOL _linkEnded;
}

- (instancetype)initWithLinkID:(NSData *)linkID
                        secret:(NSData *)secret
                   environment:(SZFriendsLinkEnvironment *)environment
                          sink:(id<SZFriendsLinkSink>)sink {
    SZFriendsLinkKeys *keys = [[SZFriendsLinkKeys alloc] initWithLinkID:linkID secret:secret];
    if (keys == nil || environment.transport == nil || environment.queue == nil) return nil;
    if ((self = [super init])) {
        _environment = environment;
        _sink = sink;
        _linkID = [linkID copy];
        _secret = [secret copy];
        _setup = [[SZFriendsLinkSetup alloc] initOpenerWithKeys:keys environment:environment];
        _setup.delegate = self;
    }
    return self;
}

- (void)startWithOpen:(void (^)(NSData *, void (^)(id, BOOL)))open
           completion:(void (^)(SZFriendsLinkOutcome))completion {
    _completion = [completion copy];
    _open = [open copy];
    [self startSetup];
}

- (void)startSetup {
    void (^open)(NSData *, void (^)(id, BOOL)) = _open;
    [_setup startWithOpen:^(NSData *hello, void (^done)(id<SZFriendsOnlineSignalChannel>, BOOL)) {
        open(hello, ^(id channel, BOOL ownerOnline) {
            done([channel conformsToProtocol:@protocol(SZFriendsOnlineSignalChannel)] ? channel : nil, ownerOnline);
        });
    }];
}

- (void)linkSetup:(SZFriendsLinkSetup *)setup didOpenStream:(id<SZFriendsByteStream>)stream attempt:(uint8_t)attempt {
    if (setup != _setup) {
        [stream close];
        return;
    }
    _attempt = attempt;
    NSData *key = [setup.keys contentKeyForAttempt:attempt];
    SZFriendsLinkDownload *download = [[SZFriendsLinkDownload alloc] initWithStream:stream contentKey:key sink:_sink
                                                                              queue:_environment.queue
                                                                       resumingFrom:_download];
    download.stallTimeout = _environment.stallTimeout;
    _download = download;
    __weak SZFriendsLinkOpening *weakSelf = self;
    __weak SZFriendsLinkDownload *weakDownload = download;
    download.onFinish = ^(SZFriendsLinkOutcome outcome) { [weakSelf download:weakDownload finished:outcome]; };
    [download start];
}

- (void)download:(SZFriendsLinkDownload *)download finished:(SZFriendsLinkOutcome)outcome {
    if (download != _download || _completion == nil) return;
    if (download.lost) {
        _stalls = download.nextChunk > _resumedAt ? 0 : _stalls + 1;
        _resumedAt = download.nextChunk;
        if (_stalls < SZFriendsLinkResumesWithoutProgress) {
            [self carryOn];
            return;
        }
        [_sink linkDidStop:outcome];
    }
    [self finish:outcome];
}

// A new setup, with fresh nonces and keys; the next download resumes from the one that dropped.
- (void)carryOn {
    SZFriendsLinkSetup *old = _setup;
    old.delegate = nil;
    [old close];
    _setup = [[SZFriendsLinkSetup alloc] initOpenerWithKeys:[[SZFriendsLinkKeys alloc] initWithLinkID:_linkID
                                                                                                secret:_secret]
                                                environment:_environment];
    _setup.delegate = self;
    [self startSetup];
}

- (void)noteLinkEnded {
    _linkEnded = YES;
}

- (void)linkSetup:(SZFriendsLinkSetup *)setup didFail:(SZFriendsLinkOutcome)outcome {
    if (setup != _setup) return;
    if (_linkEnded && outcome == SZFriendsLinkOutcomeUnavailable) outcome = SZFriendsLinkOutcomeEnded;
    [_sink linkDidStop:outcome];
    [self finish:outcome];
}

- (void)finish:(SZFriendsLinkOutcome)outcome {
    void (^completion)(SZFriendsLinkOutcome) = _completion;
    _completion = nil;
    if (completion == nil) return;
    [_download close];
    // The connection goes a moment after the last control record (done, cancel) left on it.
    SZFriendsLinkSetup *setup = _setup;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), _environment.queue, ^{ [setup close]; });
    completion(outcome);
}

- (void)cancel {
    if (_completion == nil) return;
    if (_download != nil && !_download.lost) [_download close]; // finishes the opening, through the download
    if (_completion != nil) [self linkSetup:_setup didFail:SZFriendsLinkOutcomeFailed];
}

@end

#pragma mark - Receiving in an app

@implementation SZFriendsLinkReceiver {
    SZFriendsStore *_store;
    SZFriendsTransfers *_transfers;
    NSData *_ownKey;
    NSData *_linkID;
    NSString *_transferID;
}

- (instancetype)initWithStore:(SZFriendsStore *)store
                    transfers:(SZFriendsTransfers *)transfers
                  ownIdentity:(NSData *)ownKey
                       linkID:(NSData *)linkID {
    if ((self = [super init])) {
        _store = store;
        _transfers = transfers;
        _ownKey = ownKey;
        _linkID = linkID;
    }
    return self;
}

// The sender's identity must sign what this file is, so the file lands with the person who made the link, never
// with whoever a forged name points at. A person blocked here gets nothing through a link either.
- (BOOL)linkDidReceiveMetadata:(SZFriendsLinkMetadata *)metadata {
    NSData *key = metadata.senderIdentityKey;
    BOOL signedBySender = key.length == 32 && metadata.blake2b.length == 32 &&
                          [SZFriendsIdentity verifySignature:metadata.senderSignature
                                                  forMessage:[metadata signedBytesForLinkID:_linkID]
                                                      domain:SZFriendsLinkSenderDomain
                                                   publicKey:key];
    if (!signedBySender || [key isEqualToData:_ownKey]) return NO;
    SZFriendsPersonRecord *person = [_store personWithIdentityKey:key];
    if (person.relation == SZFriendsRelationBlocked) return NO;
    if (person == nil) {
        person = [[SZFriendsPersonRecord alloc] init];
        person.conversationID = SZFriendsNewIdentifier();
        person.identityKey = key;
        person.friendsID = metadata.senderFriendsID.length ? metadata.senderFriendsID : nil;
        person.name = metadata.senderName.length ? metadata.senderName : nil;
        person.relation = SZFriendsRelationRemoved;
        person.lastInteractionAt = [NSDate date];
        if (![_store savePerson:person error:NULL] || ![_store markLinkContact:person.conversationID error:NULL]) {
            return NO;
        }
    }
    NSString *transferID = SZFriendsNewIdentifier();
    SZFriendsTransferRecord *transfer =
        [_transfers recordLinkTransferWithID:transferID conversationID:person.conversationID fileName:metadata.name
                                 uniformType:SZFriendsTypeIdentifierForFileName(metadata.name) size:metadata.size
                               contentDigest:metadata.blake2b error:NULL];
    if (transfer == nil) return NO;
    _transferID = transferID;
    _conversationID = person.conversationID;
    _fileName = transfer.fileName;
    if (self.onStarted) self.onStarted(metadata);
    return YES;
}

- (BOOL)linkDidReceiveBytes:(NSData *)bytes atOffset:(uint64_t)offset {
    if (bytes.length == 0) return YES;
    return [_transfers appendChunk:bytes atOffset:offset toTransfer:_transferID fromConversation:_conversationID
                             error:NULL];
}

// The BLAKE2b the sender signed is the transfer's digest: publishing checks it, as streamed and as read back.
- (BOOL)linkDidFinish {
    SZFriendsTransferRecord *transfer = [_transfers transferWithID:_transferID];
    if (![_transfers finishTransfer:_transferID finalDigest:transfer.contentDigest fromConversation:_conversationID
                              error:NULL]) {
        return NO;
    }
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = SZFriendsNewIdentifier();
    item.conversationID = _conversationID;
    item.kind = SZFriendsItemKindEvent;
    item.direction = SZFriendsDirectionIncoming;
    item.sentAt = [NSDate date];
    item.receivedAt = item.sentAt;
    item.eventKind = SZFriendsEventReceivedThroughLink;
    item.eventArguments = @{@"file" : _fileName ?: @""};
    [_store insertItem:item error:NULL];
    return YES;
}

- (void)linkDidStop:(SZFriendsLinkOutcome)outcome {
    (void)outcome;
    if (_transferID == nil) return;
    SZFriendsTransferRecord *transfer = [_transfers transferWithID:_transferID];
    if (transfer.state == SZFriendsTransferStateReceiving) {
        [_transfers failTransfer:_transferID reason:SZFriendsTransferFailureDigestMismatch error:NULL];
    }
}

@end
