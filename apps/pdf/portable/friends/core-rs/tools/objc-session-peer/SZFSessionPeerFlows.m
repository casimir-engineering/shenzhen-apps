// The Objective-C interop peer's sessions: events out, Add by ID answers, and files through the helper's own store,
// as the nearby service moves them (service/helper/nearby/SZFriendsNearbyService+Transfers.m): an offer acknowledged
// and accepted, chunks through the window, PROGRESS from the store's durable count (flushed after a pause), DONE
// checked and acknowledged, and resume from the recipient's PROGRESS on every new session.

#import "SZFSessionPeer.h"

#import "service/session/SZFriendsSecureChannelInternal.h"

static NSString *const SZFPatternNames[] = {@"XX", @"IK", @"NN"};
// As the helper does: when chunks pause, received bytes are made durable anyway so the sender's window reopens.
static const NSTimeInterval SZFProgressFlushDelay = 0.5;

static SZFriendsFrame *SZFIDFrame(SZFriendsFrameType type, NSData *offerID, NSDictionary *more) {
    NSMutableDictionary *fields = [NSMutableDictionary dictionaryWithDictionary:more ?: @{}];
    fields[@(SZFriendsFieldID)] = offerID;
    return [SZFriendsFrame frameWithType:type fields:fields];
}

// As the helper does (ADR 0018 § 7): PING while the session carries a transfer, and close it after the silence limit
// while the other side owes PROGRESS or the rest of a file.
static void SZFUpdateLiveness(SZFPeerSession *session) {
    BOOL keepalive = NO, watch = NO;
    SZFriendsTransferLiveness(session.senders.allValues, session.receivers.allValues, &keepalive, &watch);
    [session.channel setLivenessKeepalive:keepalive watch:watch];
}

@implementation SZFPeer (Flows)

- (void)attachChannel:(SZFriendsSecureChannel *)channel toSession:(SZFPeerSession *)session {
    session.channel = channel;
    self.sessions[@(session.sessionID)] = session;
    __weak SZFPeer *weakSelf = self;
    __weak SZFPeerSession *weakSession = session;
    channel.onEstablished = ^{ [weakSelf establishedSession:weakSession]; };
    channel.onFrame = ^(SZFriendsFrame *frame) { [weakSelf session:weakSession receivedFrame:frame]; };
    channel.onClose = ^(NSError *error) {
        SZFPeer *strongSelf = weakSelf;
        SZFPeerSession *strongSession = weakSession;
        if (strongSelf == nil || strongSession == nil) return;
        [strongSelf devicesClosed:strongSession];
        [strongSelf.transfers flushProgressWithError:NULL];
        for (NSFileHandle *source in strongSession.sources.allValues) [source closeFile];
        NSNumber *reason = error.userInfo[SZFriendsSessionCloseReasonKey];
        SZFriendsSecureChannel *closing = strongSession.channel;
        [strongSelf emit:@{@"event" : @"closed", @"session" : @(strongSession.sessionID), @"error" : @(error.code),
                           @"reason" : reason ?: [NSNull null],
                           @"rekeys" : @[ @(closing.rekeysSent), @(closing.rekeysReceived) ]}];
        [strongSelf.sessions removeObjectForKey:@(strongSession.sessionID)];
    };
}

- (void)establishedSession:(SZFPeerSession *)session {
    SZFriendsSecureChannel *channel = session.channel;
    [self emit:@{
        @"event" : @"established", @"session" : @(session.sessionID), @"initiator" : @(channel.isInitiator),
        @"pattern" : SZFPatternNames[channel.pattern],
        @"remote_identity" : channel.remoteIdentityKey ? SZFHex(channel.remoteIdentityKey) : [NSNull null],
        @"token" : channel.presentedRequestToken ? SZFHex(channel.presentedRequestToken) : [NSNull null],
        @"route" : @(channel.initiatorRoute), @"minor" : @(channel.negotiatedMinor),
    }];
    [self devicesEstablished:session];
    SZFriendsPersonRecord *person =
        channel.remoteIdentityKey ? [self.store personWithIdentityKey:channel.remoteIdentityKey] : nil;
    if (person == nil) return;
    session.conversationID = person.conversationID;
    NSArray *unfinished = [self.transfers unfinishedIncomingTransfersForConversation:person.conversationID];
    if (unfinished.count) [self.transfers flushProgressWithError:NULL];
    for (SZFriendsTransferRecord *__strong record in unfinished) {
        record = [self.transfers transferWithID:record.transferID] ?: record;
        SZFriendsChunkReceiver *receiver =
            [[SZFriendsChunkReceiver alloc] initWithOfferID:SZFBytes(record.transferID) size:record.size
                                             verifiedOffset:record.verifiedBytes route:channel.initiatorRoute];
        if (receiver == nil) continue;
        session.receivers[record.transferID] = receiver;
        [channel sendFrame:[receiver resumeProgressFrame]];
    }
    SZFUpdateLiveness(session);
}

- (void)session:(SZFPeerSession *)session receivedFrame:(SZFriendsFrame *)frame {
    if ([self devicesSession:session frame:frame]) return;
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    NSString *offer = wire ? SZFHex(wire) : nil;
    BOOL handled = NO;
    switch (frame.type) {
    case SZFriendsFrameTypeOffer: handled = [self session:session offer:frame id:offer]; break;
    case SZFriendsFrameTypeOfferReply: handled = [self session:session offerReply:frame id:offer]; break;
    case SZFriendsFrameTypeProgress: handled = [self session:session progress:frame id:offer]; break;
    case SZFriendsFrameTypeChunk: handled = [self session:session chunk:frame id:offer]; break;
    case SZFriendsFrameTypeDone: handled = [self session:session done:frame id:offer]; break;
    case SZFriendsFrameTypeAck: handled = [self session:session acknowledged:offer]; break;
    case SZFriendsFrameTypeRequestByID: handled = [self session:session requestByID:frame]; break;
    default: break;
    }
    if (handled) {
        SZFUpdateLiveness(session);
        return;
    }
    [self emit:@{@"event" : @"frame", @"session" : @(session.sessionID), @"type" : @(frame.type),
                 @"frame" : SZFHex(SZFriendsEncodeFrame(frame, NULL))}];
}

- (void)closeForProtocol:(SZFPeerSession *)session {
    [session.channel closeWithReason:SZFriendsCloseReasonProtocolError];
}

- (BOOL)session:(SZFPeerSession *)session offer:(SZFriendsFrame *)frame id:(NSString *)offer {
    uint64_t size = 0;
    NSString *name = [frame stringForTag:SZFriendsFieldName];
    NSData *digest = [frame dataForTag:SZFriendsFieldDigest];
    if (session.conversationID == nil || offer == nil || name == nil || digest == nil ||
        ![frame getUInt64:&size forTag:SZFriendsFieldSize]) {
        [self closeForProtocol:session];
        return YES;
    }
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    NSError *error = nil;
    NSString *type = [frame stringForTag:SZFriendsFieldFileType];
    SZFriendsTransferRecord *record = [self.transfers recordIncomingOfferWithID:offer
                                                                 conversationID:session.conversationID
                                                                       fileName:name
                                                                    uniformType:type
                                                                           size:size
                                                                  contentDigest:digest
                                                                         sentAt:[NSDate date]
                                                                          error:&error];
    BOOL accepted = record != nil && [self.transfers acceptTransfer:offer automatically:NO error:&error];
    SZFriendsChunkReceiver *receiver =
        accepted ? [[SZFriendsChunkReceiver alloc] initWithOfferID:wire size:size verifiedOffset:0
                                                              route:session.channel.initiatorRoute]
                 : nil;
    [session.channel sendFrame:SZFIDFrame(SZFriendsFrameTypeAck, wire, nil)];
    NSDictionary *reply = @{@(SZFriendsFieldAccept) : [SZFriendsFrame fieldWithUInt64:receiver != nil
                                                                                  tag:SZFriendsFieldAccept],
                            @(SZFriendsFieldOffset) : [SZFriendsFrame fieldWithUInt64:0 tag:SZFriendsFieldOffset]};
    [session.channel sendFrame:SZFIDFrame(SZFriendsFrameTypeOfferReply, wire, reply)];
    if (receiver == nil) {
        [self emit:@{@"event" : @"transfer_failed", @"transfer" : offer, @"why" : error.localizedDescription ?: @""}];
        return YES;
    }
    session.receivers[offer] = receiver;
    [self emit:@{@"event" : @"offer", @"session" : @(session.sessionID), @"transfer" : offer, @"size" : @(size)}];
    return YES;
}

- (BOOL)session:(SZFPeerSession *)session
    startSending:(NSString *)offer
        accepted:(BOOL)accepted
          offset:(uint64_t)offset {
    NSError *error = nil;
    if (session.conversationID == nil ||
        ![self.transfers peerAnsweredTransfer:offer accepted:accepted offset:offset
                             fromConversation:session.conversationID error:&error]) {
        [self emit:@{@"event" : @"transfer_failed", @"transfer" : offer, @"why" : error.localizedDescription ?: @""}];
        return NO;
    }
    if (!accepted) {
        [self emit:@{@"event" : @"declined", @"transfer" : offer}];
        return YES;
    }
    SZFriendsTransferRecord *record = [self.transfers transferWithID:offer];
    NSFileHandle *source = record.stagedPath ? SZFriendsOpenSnapshotForSending(record.stagedPath) : nil;
    SZFriendsChunkSender *sender = [[SZFriendsChunkSender alloc] initWithOfferID:SZFBytes(offer) size:record.size
                                                                    resumeOffset:offset
                                                                           route:session.channel.initiatorRoute];
    if (source == nil || sender == nil) return NO;
    session.senders[offer] = sender;
    session.sources[offer] = source;
    [self emit:@{@"event" : @"sending", @"session" : @(session.sessionID), @"transfer" : offer, @"offset" : @(offset)}];
    [self pumpSession:session];
    return YES;
}

- (BOOL)session:(SZFPeerSession *)session offerReply:(SZFriendsFrame *)frame id:(NSString *)offer {
    uint64_t accept = 0, offset = 0;
    [frame getUInt64:&accept forTag:SZFriendsFieldAccept];
    [frame getUInt64:&offset forTag:SZFriendsFieldOffset];
    if (offer == nil || ![self session:session startSending:offer accepted:accept == 1 offset:offset]) {
        [self closeForProtocol:session];
    }
    return YES;
}

- (BOOL)session:(SZFPeerSession *)session progress:(SZFriendsFrame *)frame id:(NSString *)offer {
    SZFriendsChunkSender *sender = offer ? session.senders[offer] : nil;
    if (sender != nil) {
        if (![sender handleProgressFrame:frame error:NULL]) [self closeForProtocol:session];
        else [self pumpSession:session];
        return YES;
    }
    uint64_t offset = 0;
    [frame getUInt64:&offset forTag:SZFriendsFieldOffset];
    if (offer == nil || ![self session:session startSending:offer accepted:YES offset:offset]) {
        [self closeForProtocol:session];
    }
    return YES;
}

- (void)reportProgressOnSession:(SZFPeerSession *)session transfer:(NSString *)offer {
    SZFriendsChunkReceiver *receiver = session.receivers[offer];
    uint64_t durable = [self.transfers transferWithID:offer].verifiedBytes;
    if (receiver == nil || durable <= receiver.reportedOffset) return;
    SZFriendsFrame *progress = [receiver progressFrameForDurableOffset:durable];
    if (progress) [session.channel sendFrame:progress];
}

- (void)armFlushOnSession:(SZFPeerSession *)session {
    if (session.flushArmed) return;
    session.flushArmed = YES;
    __weak SZFPeerSession *weakSession = session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFProgressFlushDelay * NSEC_PER_SEC)), self.queue, ^{
        SZFPeerSession *strongSession = weakSession;
        if (strongSession == nil) return;
        strongSession.flushArmed = NO;
        [self.transfers flushProgressWithError:NULL];
        for (NSString *offer in strongSession.receivers.allKeys) {
            [self reportProgressOnSession:strongSession transfer:offer];
        }
    });
}

- (BOOL)session:(SZFPeerSession *)session chunk:(SZFriendsFrame *)frame id:(NSString *)offer {
    SZFriendsChunkReceiver *receiver = offer ? session.receivers[offer] : nil;
    uint64_t offset = receiver.receivedOffset;
    NSData *data = [receiver acceptChunkFrame:frame error:NULL];
    if (data == nil || ![self.transfers appendChunk:data atOffset:offset toTransfer:offer
                                   fromConversation:session.conversationID error:NULL]) {
        [self closeForProtocol:session]; // unsolicited, out of place, or not stored
        return YES;
    }
    [self reportProgressOnSession:session transfer:offer];
    [self armFlushOnSession:session];
    return YES;
}

- (BOOL)session:(SZFPeerSession *)session done:(SZFriendsFrame *)frame id:(NSString *)offer {
    SZFriendsChunkReceiver *receiver = offer ? session.receivers[offer] : nil;
    NSData *digest = [receiver acceptDoneFrame:frame error:NULL];
    if (digest == nil) {
        [self closeForProtocol:session];
        return YES;
    }
    [session.receivers removeObjectForKey:offer];
    NSError *error = nil;
    if ([self.transfers finishTransfer:offer finalDigest:digest fromConversation:session.conversationID
                                 error:&error]) {
        [session.channel sendFrame:SZFIDFrame(SZFriendsFrameTypeAck, [frame dataForTag:SZFriendsFieldID], nil)];
        NSString *path = [self.transfers transferWithID:offer].receivedPath ?: @"";
        [self emit:@{@"event" : @"received_file", @"transfer" : offer, @"path" : path}];
    } else {
        [self emit:@{@"event" : @"transfer_failed", @"transfer" : offer, @"why" : error.localizedDescription ?: @""}];
    }
    return YES;
}

// The offer's ACK moves it to Offered; the ACK after DONE says their device verified the file.
- (BOOL)session:(SZFPeerSession *)session acknowledged:(NSString *)offer {
    SZFriendsTransferRecord *record = offer ? [self.transfers transferWithID:offer] : nil;
    if (record == nil || !record.outgoing || session.conversationID == nil) return NO;
    if (record.state == SZFriendsTransferStateQueued) {
        [self.transfers markOfferDelivered:offer fromConversation:session.conversationID error:NULL];
    } else if (record.state == SZFriendsTransferStateSending &&
               [self.transfers peerVerifiedTransfer:offer fromConversation:session.conversationID error:NULL]) {
        [session.senders removeObjectForKey:offer];
        [session.sources[offer] closeFile];
        [session.sources removeObjectForKey:offer];
        [self emit:@{@"event" : @"delivered", @"transfer" : offer}];
    }
    return YES;
}

- (BOOL)session:(SZFPeerSession *)session requestByID:(SZFriendsFrame *)frame {
    [session.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeReceived fields:@{}]];
    NSData *identity = SZFriendsVerifyRequestByIDFrame(frame, session.channel.handshakeHash);
    if (identity == nil) return YES;
    [self emit:@{
        @"event" : @"request_by_id", @"session" : @(session.sessionID), @"identity_key" : SZFHex(identity),
        @"static_key" : SZFHex([frame dataForTag:SZFriendsFieldStaticKey]),
        @"token" : SZFHex([frame dataForTag:SZFriendsFieldToken]),
        @"callback_secret" : SZFHex([frame dataForTag:SZFriendsFieldCallbackSecret]),
        @"friends_id" : [frame stringForTag:SZFriendsFieldFriendsID] ?: [NSNull null],
    }];
    return YES;
}

// Chunks while the window has room, then DONE; the channel lets messages overtake the queued chunks.
- (void)pumpSession:(SZFPeerSession *)session {
    for (NSString *offer in session.senders.allKeys) {
        SZFriendsChunkSender *sender = session.senders[offer];
        NSFileHandle *source = session.sources[offer];
        uint64_t offset = 0;
        NSUInteger length = 0;
        while ([sender getNextChunkOffset:&offset length:&length]) {
            NSData *data = SZFriendsReadSnapshotAt(source, offset, length);
            SZFriendsFrame *chunk = [sender chunkFrameWithData:data];
            if (chunk == nil || ![session.channel sendFrame:chunk]) return;
        }
        if (sender.allSent && ![session.doneSent containsObject:offer]) {
            SZFriendsTransferRecord *record = [self.transfers transferWithID:offer];
            NSDictionary *digest = @{@(SZFriendsFieldDigest) : record.contentDigest};
            if ([session.channel sendFrame:SZFIDFrame(SZFriendsFrameTypeDone, SZFBytes(offer), digest)]) {
                [session.doneSent addObject:offer];
            }
        }
    }
    SZFUpdateLiveness(session);
}

- (NSDictionary *)sendFileWithCommand:(NSDictionary *)command {
    SZFPeerSession *session = self.sessions[@([command[@"session"] unsignedLongLongValue])];
    if (session.conversationID == nil) return @{@"error" : @"not a friend's session"};
    NSError *error = nil;
    SZFriendsTransferRecord *record = [self.transfers stageOutgoingFileAtPath:command[@"path"] ?: @""
                                                                     revision:nil
                                                               conversationID:session.conversationID
                                                                        error:&error];
    if (record == nil) return @{@"error" : error.localizedDescription ?: @"stage failed"};
    NSMutableDictionary *fields = [@{
        @(SZFriendsFieldName) : [record.fileName dataUsingEncoding:NSUTF8StringEncoding],
        @(SZFriendsFieldSize) : [SZFriendsFrame fieldWithUInt64:record.size tag:SZFriendsFieldSize],
        @(SZFriendsFieldDigest) : record.contentDigest,
    } mutableCopy];
    if (record.uniformType) {
        fields[@(SZFriendsFieldFileType)] = [record.uniformType dataUsingEncoding:NSUTF8StringEncoding];
    }
    [session.channel sendFrame:SZFIDFrame(SZFriendsFrameTypeOffer, SZFBytes(record.transferID), fields)];
    return @{@"transfer" : record.transferID, @"size" : @(record.size), @"digest" : SZFHex(record.contentDigest)};
}

- (NSDictionary *)requestByIDWithCommand:(NSDictionary *)command {
    SZFPeerSession *session = self.sessions[@([command[@"session"] unsignedLongLongValue])];
    NSData *token = SZFBytes(command[@"token"]) ?: [NSData data];
    NSData *callback = SZFBytes(command[@"callback"]) ?: [NSData data];
    SZFriendsFrame *frame = SZFriendsMakeRequestByIDFrame(self.identity, command[@"friends_id"] ?: @"", token, callback,
                                                          session.channel.handshakeHash ?: [NSData data]);
    return @{@"sent" : (frame != nil && [session.channel sendFrame:frame]) ? @YES : @NO};
}

@end
