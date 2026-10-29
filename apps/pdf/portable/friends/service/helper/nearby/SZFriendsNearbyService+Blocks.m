// Files by blocks on a fast session (ADR 0018, PROTOCOL.md § Fast transfers): the nearby service's side of
// SZFriendsBlockExchange, one per live friend's session that negotiated fast transfers. The exchange moves the frames
// and the store keeps the blocks; this file ties them to the link: what is sent where, ACK expectations, durability
// batches on the helper queue, and what a received file sets off.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

#import <sodium.h>

// A durability batch comes due at most a second after a block was written (SZFriendsBlockDownloads.m).
static const NSTimeInterval SZFriendsBlockFlushDelay = 0.5;

@implementation SZFriendsNearbyService (Blocks)

- (SZFriendsBlockExchange *)blocksOnLink:(SZFriendsPeerLink *)link {
    if (link.blocks != nil) return link.blocks;
    if (!link.live || link.closed || link.conversationID == nil || !link.channel.fastTransfers) return nil;
    __weak SZFriendsNearbyService *weakSelf = self;
    __weak SZFriendsPeerLink *weakLink = link;
    SZFriendsBlockExchange *blocks = [[SZFriendsBlockExchange alloc]
        initWithTransfers:self.services.transfers
           conversationID:link.conversationID
                    route:link.raceRoute
                     send:^BOOL(SZFriendsFrame *frame) {
                         return [weakLink.channel sendFrame:frame];
                     }];
    blocks.onChanged = ^{
        [weakSelf changed];
    };
    blocks.onSending = ^(NSString *transferID) {
        SZFriendsPeerLink *strongLink = weakLink;
        [strongLink.endedTransfers removeObject:transferID];
        [strongLink expectAckForID:transferID token:[@"done:" stringByAppendingString:transferID]];
    };
    blocks.onReceived = ^(NSString *transferID) {
        SZFriendsNearbyService *strongSelf = weakSelf;
        // The file is what it claimed to be: our own preview of it now replaces the sender's (+Thumbnails).
        [strongSelf makeLocalThumbnailForReceivedTransfer:transferID];
        [strongSelf.services.notifier noteTransferReceived:transferID];
    };
    blocks.onWanted = ^(NSString *transferID, uint64_t offset, BOOL resumed) {
        if (resumed) {
            SZFriendsHelperLog(@"transfer %@ resumes at byte %llu", [transferID substringToIndex:8],
                               (unsigned long long)offset);
        }
    };
    blocks.pace = ^BOOL(NSUInteger bytes) {
        SZFriendsNearbyService *strongSelf = weakSelf;
        SZFriendsPeerLink *strongLink = weakLink;
        double rate = SZFriendsHelperTestHooks.chunkBytesPerSecond;
        if (rate <= 0 || strongSelf == nil || strongLink == nil) return NO;
        if ([strongSelf paceLink:strongLink bytes:bytes rate:rate]) return YES;
        strongLink.paceBytes += bytes;
        return NO;
    };
    blocks.onFlushNeeded = ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        SZFriendsPeerLink *strongLink = weakLink;
        if (strongSelf && strongLink) [strongSelf scheduleBlockFlushOnLink:strongLink];
    };
    link.blocks = blocks;
    return blocks;
}

- (void)scheduleBlockFlushOnLink:(SZFriendsPeerLink *)link {
    if (link.blockFlushScheduled) return;
    link.blockFlushScheduled = YES;
    __weak SZFriendsPeerLink *weakLink = link;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsBlockFlushDelay * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsPeerLink *strongLink = weakLink;
        if (strongLink == nil) return;
        strongLink.blockFlushScheduled = NO;
        if (!strongLink.closed) [strongLink.blocks flushDue];
        [self progressChanged];
    });
}

#pragma mark - Lanes

// At most 15 lanes per group, indexes 1 to 15 (ADR 0018 § 6).
static const uint8_t SZFriendsLaneIndexMax = 15;

- (void)admitLane:(SZFriendsPeerLink *)link {
    SZFriendsSecureChannel *channel = link.channel;
    NSData *token = channel.presentedLane;
    for (SZFriendsPeerLink *head in self.links) {
        if (head == link || head.lane || !head.live || head.closed || head.superseded || head.conversationID == nil ||
            !head.channel.fastTransfers || !channel.fastTransfers ||
            ![head.channel.remoteStaticKey isEqualToData:channel.remoteStaticKey] ||
            ![head.channel.remoteIdentityKey isEqualToData:channel.remoteIdentityKey]) {
            continue;
        }
        NSMutableIndexSet *used = [NSMutableIndexSet indexSet];
        for (SZFriendsPeerLink *lane in head.lanes) [used addIndex:lane.laneIndex];
        // Every index is tried, so how long this takes says nothing about which one matched.
        uint8_t found = 0;
        for (uint8_t index = 1; index <= SZFriendsLaneIndexMax; index++) {
            NSData *expected = SZFriendsLaneToken(head.channel.handshakeHash ?: [NSData data], index);
            BOOL same = expected.length == 16 && token.length == 16 &&
                        sodium_memcmp(expected.bytes, token.bytes, 16) == 0;
            if (same && ![used containsIndex:index] && found == 0) found = index;
        }
        if (found == 0) continue;
        link.lane = YES;
        link.laneHead = head;
        link.laneIndex = found;
        link.conversationID = head.conversationID;
        [head.lanes addObject:link];
        // The lane's peer always hears something from it while the group lasts, so it never takes it for silent.
        [channel setLivenessKeepalive:YES watch:NO];
        return;
    }
    SZFriendsHelperLog(@"lane refused: no live session with that device and a free index matches its token");
    [channel closeWithReason:SZFriendsCloseReasonLaneRefused];
}

- (void)link:(SZFriendsPeerLink *)link receivedBlockFrame:(SZFriendsFrame *)frame {
    SZFriendsBlockExchange *blocks = [self blocksOnLink:link];
    if (blocks == nil || ![blocks handleFrame:frame]) {
        // ADR 0001: nothing moves outside an accepted transfer; a block frame that names none closes the session.
        SZFriendsHelperLog(@"a block frame out of place: closing the session");
        [link.channel closeWithReason:SZFriendsCloseReasonProtocolError];
        return;
    }
    [self updateLivenessOnLink:link];
    [self progressChanged];
}

@end
