// Delivery on a live link (SZFriendsNearbyService+Delivery.m): what the outbox records around handing a frame to the
// channel.

#import "SZFriendsHelperNearbyTests.h"

// A fake channel that looks at the outbox the moment a frame is handed to it, and can refuse the frame.
@interface SZFNWatchingChannel : SZFNFakeChannel
@property(nonatomic) BOOL refuses;
@property(nonatomic, copy, nullable) void (^watch)(void);
@end

@implementation SZFNWatchingChannel
// A peer without previews (protocol minor 0): this test is about the outbox, not THUMBNAIL frames.
- (NSUInteger)negotiatedMinor {
    return 0;
}
- (BOOL)sendFrame:(SZFriendsFrame *)frame {
    if (self.watch) self.watch();
    if (self.refuses) return NO;
    [self.sent addObject:frame];
    return YES;
}
@end

// A message to `conversationID`, queued as send_message queues one: its history item and its outbox entry.
static SZFriendsOutboxEntry *SZFNQueueMessage(SZFriendsHelperServices *services, NSString *conversationID) {
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.conversationID = conversationID;
    item.itemID = SZFriendsNewIdentifier();
    item.kind = SZFriendsItemKindMessage;
    item.direction = SZFriendsDirectionOutgoing;
    item.text = @"See you Friday";
    item.sentAt = [NSDate date];
    item.receivedAt = item.sentAt;
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = SZFriendsNewIdentifier();
    entry.conversationID = conversationID;
    entry.kind = SZFriendsOutboxKindMessage;
    entry.itemID = item.itemID;
    entry.createdAt = item.sentAt;
    NSError *error = nil;
    EXPECT([services.outbox enqueue:entry item:item error:&error], "a message is queued: %@", error);
    return entry;
}

static SZFriendsPeerLink *SZFNLiveLink(SZFNFakeChannel *channel, NSString *conversationID) {
    SZFriendsPeerLink *link = SZFNLink(channel);
    link.conversationID = conversationID;
    link.live = YES;
    link.adopted = YES;
    return link;
}

// Security review, wave 6a (Cancel after a lost acknowledgement): Cancel trusts the stored attempts alone, and the
// entry used to be marked written only after the channel took the frame, so a failed commit or a crash between the
// two left a message on its way to the friend that Cancel would delete. Written is committed first now: the channel
// sees the entry written as it is handed the frame. A frame the channel refuses goes back to Queued and keeps the
// count, so Cancel answers that it may have been sent rather than deleting it.
void SZFNTestWrittenBeforeSend(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"written");
    if (services == nil) return;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsPersonRecord *friend = SZFNSavePerson(services.store, SZFriendsRelationFriend);
    SZFriendsOutboxEntry *message = SZFNQueueMessage(services, friend.conversationID);
    SZFNWatchingChannel *channel = [[SZFNWatchingChannel alloc] init];
    __block SZFriendsOutboxEntry *seen = nil;
    channel.watch = ^{
      seen = [services.outbox entryWithID:message.entryID];
    };
    SZFriendsPeerLink *link = SZFNLiveLink(channel, friend.conversationID);
    [nearby deliverPendingOnLink:link];
    EXPECT(channel.sent.count == 1 && seen.attempts == 1 && seen.state == SZFriendsOutboxStateSending,
           "written (attempts %lu, state %ld) before the channel has the frame", (unsigned long)seen.attempts,
           (long)seen.state);
    EXPECT([link.inFlightEntries containsObject:message.entryID], "and waiting for its acknowledgement");

    SZFriendsPersonRecord *other = SZFNSavePerson(services.store, SZFriendsRelationFriend);
    SZFriendsOutboxEntry *refused = SZFNQueueMessage(services, other.conversationID);
    SZFNWatchingChannel *refusing = [[SZFNWatchingChannel alloc] init];
    refusing.refuses = YES;
    SZFriendsPeerLink *refusingLink = SZFNLiveLink(refusing, other.conversationID);
    [nearby deliverPendingOnLink:refusingLink];
    SZFriendsOutboxEntry *after = [services.outbox entryWithID:refused.entryID];
    EXPECT(after.state == SZFriendsOutboxStateQueued && after.attempts == 1 &&
               ![refusingLink.inFlightEntries containsObject:refused.entryID],
           "a refused frame waits for the next session, still counted (state %ld, attempts %lu)", (long)after.state,
           (unsigned long)after.attempts);
    NSInteger state = -1;
    NSError *error = nil;
    EXPECT(![services.outbox cancelMessage:refused.itemID inConversation:other.conversationID state:&state
                                     error:&error] && state == SZFriendsOutboxCancelStateWritten,
           "Cancel treats it as possibly sent (state %ld): %@", (long)state, error);
    [services close];
}
