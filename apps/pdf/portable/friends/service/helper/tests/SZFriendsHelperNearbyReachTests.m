// friends-helper-check: what the helper says about a friend between sessions once it reaches friends online
// (SZFriendsNearbyService+Online.m, -onlineReachForPerson:now:), and the `online` capability. A driver whose opens go
// nowhere stands in for the host: its attempts run until stopped and never connect.

#import "SZFriendsHelperNearbyTests.h"

#import "service/helper/SZFriendsHelperFacts.h"
#import "service/online/driver/SZFriendsOnlineDriverPrivate.h"

static SZFriendsPersonRecord *SZFNOnlineFriend(SZFriendsStore *store) {
    SZFriendsPersonRecord *friend = SZFNSavePerson(store, SZFriendsRelationFriend);
    friend.presenceSecret = SZFNBytes(32);
    [store savePerson:friend error:NULL];
    return friend;
}

static BOOL SZFNQueueMessage(SZFriendsHelperServices *services, SZFriendsPersonRecord *person) {
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = SZFriendsNewIdentifier();
    entry.conversationID = person.conversationID;
    entry.kind = SZFriendsOutboxKindMessage;
    entry.itemID = SZFriendsNewIdentifier();
    entry.createdAt = [NSDate date];
    return [services.outbox enqueue:entry error:NULL];
}

static SZFriendsOnlineReach SZFNReachAt(SZFriendsHelperServices *services, SZFriendsPersonRecord *person,
                                        NSTimeInterval later) {
    NSDate *now = [NSDate dateWithTimeIntervalSinceNow:later];
    SZFriendsFactsPass *pass = [[SZFriendsFactsPass alloc] initWithServices:services now:now];
    return [pass personWithConversationID:person.conversationID].onlineReach;
}

static SZFriendsOnlineReach SZFNReach(SZFriendsHelperServices *services, SZFriendsPersonRecord *person) {
    return SZFNReachAt(services, person, 0);
}

void SZFNTestOnlineReach(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"online-reach");
    if (services == nil) return;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    services.nearby = nearby;
    SZFriendsStore *store = services.store;
    SZFriendsPersonRecord *idle = SZFNOnlineFriend(store), *waiting = SZFNOnlineFriend(store);
    SZFriendsPersonRecord *failed = SZFNOnlineFriend(store);
    EXPECT(SZFNQueueMessage(services, waiting) && SZFNQueueMessage(services, failed), "two messages wait");

    SZFriendsOnlineDriverTestHooks.loopbackOnly = YES;
    SZFriendsOnlineDriver *driver = [[SZFriendsOnlineDriver alloc] initWithIdentity:services.identity
                                                                              queue:dispatch_get_main_queue()];
    driver.delegate = nearby;
    driver.testOpener = ^(NSData *rdvKey, NSData *payload, void (^completion)(id<SZFriendsOnlineSignalChannel>)) {
        (void)rdvKey;
        (void)payload;
        (void)completion; // the host never answers: the attempt keeps running
    };
    nearby.onlineDriver = driver;
    EXPECT(!nearby.reachesFriendsOnline && ![SZFriendsHelperCapabilityList(services) containsObject:@"online"],
           "nothing said about online before the host says it takes online messages");
    [driver reachFriend:waiting.identityKey];
    EXPECT([driver hasAttemptForFriend:waiting.identityKey]);
    EXPECT(SZFNReach(services, waiting) == SZFriendsOnlineReachUnknown, "an M1-worded helper shows no attempt");

    [nearby onlineDriverDidBecomeAvailable:driver];
    EXPECT(nearby.reachesFriendsOnline && [SZFriendsHelperCapabilityList(services) containsObject:@"online"],
           "announced once the host offers online: %@", SZFriendsHelperCapabilityList(services));
    SZFriendsFactsPass *pass = [[SZFriendsFactsPass alloc] initWithServices:services now:[NSDate date]];
    EXPECT([pass.helperCapabilities containsObject:@"online"], "snapshots are worded for it too");
    EXPECT(SZFNReach(services, waiting) == SZFriendsOnlineReachConnecting, "trying, with a message just queued");
    // Connecting is about what just happened: a minute on, the attempt still runs and the message still waits, but
    // the words say Not connected rather than Connecting for as long as nobody answers.
    EXPECT(SZFNReachAt(services, waiting, 60) == SZFriendsOnlineReachUnknown, "45 s after queuing: not connected");
    EXPECT([driver hasAttemptForFriend:waiting.identityKey]);

    // Nothing waits for `idle`: an attempt toward them (to finish a download, or theirs toward us) is not news...
    [driver reachFriend:idle.identityKey];
    EXPECT([driver hasAttemptForFriend:idle.identityKey]);
    EXPECT(SZFNReach(services, idle) == SZFriendsOnlineReachUnknown, "no flicker for a friend nothing waits for");
    // ...unless the person is looking at the conversation.
    [nearby conversationOpened:idle.conversationID];
    EXPECT(SZFNReach(services, idle) == SZFriendsOnlineReachConnecting, "just opened: Connecting");
    EXPECT(SZFNReachAt(services, idle, 60) == SZFriendsOnlineReachUnknown, "opened a minute ago: not connected");
    // Something new queued later starts the window again.
    EXPECT(SZFNQueueMessage(services, idle));
    EXPECT(SZFNReachAt(services, idle, 30) == SZFriendsOnlineReachConnecting, "a new message: Connecting again");

    // Failed everywhere, relay included: Couldn’t connect only while something waits for them.
    NSMutableDictionary *failures = [driver valueForKey:@"_failedEverywhere"];
    failures[failed.identityKey] = [NSDate date];
    EXPECT(SZFNReach(services, failed) == SZFriendsOnlineReachUnreachable, "a message waits and no path worked");
    EXPECT(SZFNReachAt(services, failed, 600) == SZFriendsOnlineReachUnreachable, "and says so until it changes");
    // A retry in the background changes nothing the person sees: no flip to Not connected and back with each one.
    [driver reachFriend:failed.identityKey];
    EXPECT([driver hasAttemptForFriend:failed.identityKey]);
    EXPECT(SZFNReach(services, failed) == SZFriendsOnlineReachUnreachable, "a retry runs: still Couldn’t connect");
    // An outbox change with nothing new queued (an answer, a cancel) leaves it.
    [nearby outboxChangedForConversation:failed.conversationID];
    EXPECT(SZFNReach(services, failed) == SZFriendsOnlineReachUnreachable, "nothing new: still Couldn’t connect");
    // Something new queued after the failure: the words follow the retry again.
    EXPECT(SZFNQueueMessage(services, failed));
    [nearby outboxChangedForConversation:failed.conversationID];
    EXPECT(SZFNReach(services, failed) == SZFriendsOnlineReachConnecting, "a new message: Connecting");
    // Opening the conversation does the same.
    failures[failed.identityKey] = [NSDate date];
    EXPECT(SZFNReach(services, failed) == SZFriendsOnlineReachUnreachable, "failed again");
    [nearby conversationOpened:failed.conversationID];
    EXPECT(SZFNReach(services, failed) == SZFriendsOnlineReachConnecting, "opened: Connecting");
    failures[failed.identityKey] = [NSDate date];
    for (SZFriendsOutboxEntry *entry in [services.outbox pendingEntriesForConversation:failed.conversationID]) {
        [services.outbox applyEvent:SZFriendsOutboxEventRefused toEntry:entry.entryID error:NULL];
    }
    EXPECT(SZFNReach(services, failed) == SZFriendsOnlineReachUnknown, "nothing waits any more: not connected");
    [driver networkChanged];
    EXPECT([driver reachOfFriend:failed.identityKey] == SZFriendsOnlineFriendReachTrying,
           "a network change forgets the failure; the retry carries on");

    // A key change waiting for review is never reached online, whatever runs.
    waiting.keyChangePending = YES;
    [store savePerson:waiting error:NULL];
    EXPECT(SZFNReach(services, waiting) == SZFriendsOnlineReachUnknown, "a key change waits for review");

    [nearby stopOnline];
    EXPECT(!nearby.reachesFriendsOnline && ![SZFriendsHelperCapabilityList(services) containsObject:@"online"],
           "stopped: online is no longer announced");
    SZFriendsOnlineDriverTestHooks.loopbackOnly = NO;
    [services close];
}
