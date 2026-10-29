// The Objective-C interop peer's block exchanges, one per friend's session with fast transfers: made, kept ticking
// for the scheduler's timers, and wired to the peer's events (ADR 0018), as the nearby service does.

#import "SZFSessionPeer.h"

@implementation SZFPeer (Blocks)

// The session's block exchange, made once it is a friend's session that negotiated fast transfers.
- (nullable SZFriendsBlockExchange *)blocksOf:(SZFPeerSession *)session {
    if (session.blocks != nil) return session.blocks;
    if (session.conversationID == nil || !session.channel.fastTransfers) return nil;
    __weak SZFPeerSession *weakSession = session;
    SZFriendsBlockExchange *blocks = [[SZFriendsBlockExchange alloc]
        initWithTransfers:self.transfers
           conversationID:session.conversationID
                    route:session.channel.initiatorRoute
                     send:^BOOL(SZFriendsFrame *frame) {
                         return [weakSession.channel sendFrame:frame];
                     }
                   queued:^NSUInteger {
                       return weakSession.channel.queuedBulkFrames;
                   }];
    blocks.pieces = session.channel.pieces;
    __weak SZFriendsBlockExchange *weakBlocks = blocks;
    session.channel.onWritten = ^{
        [weakBlocks written:SZFriendsHeadLane];
    };
    [self wireBlocks:blocks toSession:session];
    if (session.channel.handshakeHash.length == 64) {
        [blocks formGroupWithHandshakeHash:session.channel.handshakeHash initiator:session.channel.isInitiator];
    }
    session.blocks = blocks;
    return blocks;
}

// The scheduler's timers (a lane gone silent, a lane given up), every 0.25 s while the session holds the exchange, as
// the helper's block tick.
- (void)tickBlocksOf:(SZFPeerSession *)session {
    __weak SZFPeerSession *weakSession = session;
    __weak SZFPeer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), self.queue, ^{
        SZFPeerSession *strongSession = weakSession;
        if (strongSession.blocks == nil || strongSession.channel == nil) return;
        [strongSession.blocks tick];
        [weakSelf tickBlocksOf:strongSession];
    });
}

// The exchange's events, for the session that holds it (its first session, or the lane that took over).
- (void)wireBlocks:(SZFriendsBlockExchange *)blocks toSession:(SZFPeerSession *)session {
    __weak SZFPeerSession *weakSession = session;
    __weak SZFPeer *weakSelf = self;
    [self tickBlocksOf:session];
    blocks.onReceived = ^(NSString *transferID) {
        NSString *path = [weakSelf.transfers transferWithID:transferID].receivedPath ?: @"";
        [weakSelf emit:@{@"event" : @"received_file", @"transfer" : transferID, @"path" : path}];
    };
    // The bench reads the resume point here, as it reads a CHUNK resume's offset.
    blocks.onWanted = ^(NSString *transferID, uint64_t offset, BOOL resumed) {
        (void)resumed;
        [weakSelf emit:@{@"event" : @"sending", @"session" : @(weakSession.sessionID), @"transfer" : transferID,
                         @"offset" : @(offset), @"blocks" : @YES}];
    };
    blocks.onFlushNeeded = ^{
        SZFPeerSession *strongSession = weakSession;
        if (strongSession == nil || strongSession.blockFlushArmed) return;
        strongSession.blockFlushArmed = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), weakSelf.queue, ^{
            strongSession.blockFlushArmed = NO;
            [strongSession.blocks flushDue];
        });
    };
}

@end
