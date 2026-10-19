// friends-e2e-devices-check: a friend and the person's computers (friends-multi-device.md § Sync, Friends). Ben's
// message reaches the laptop while the studio is off, and the studio has it once it is back. A message written on the
// laptop while Ben is away leaves from the studio after the laptop goes off, reaches Ben once, and the laptop, back
// again, shows it delivered without sending it a second time.

#import "SZFriendsE2EDevices.h"

static NSDictionary *SZFE2EMessage(SZFE2EComputer *computer, NSString *subscription, NSString *text) {
    for (NSDictionary *item in SZFE2EKindItems([computer.client dataFor:subscription], @"message")) {
        if ([item[@"text"] isEqual:text]) return item;
    }
    return nil;
}

static NSUInteger SZFE2ECount(SZFE2EComputer *computer, NSString *subscription, NSString *text) {
    NSUInteger count = 0;
    for (NSString *shown in SZFE2ETexts(computer.client, subscription)) count += [shown isEqual:text];
    return count;
}

BOOL SZFE2EDevicesScenarioFriendReachesOne(SZFE2EWorld *world) {
    SZFE2EComputer *studio = nil, *laptop = nil, *ben = nil;
    NSString *benAtStudio = nil, *benAtLaptop = nil, *anaAtBen = nil;
    if (!SZFE2EStartProfile(world, &studio, &laptop, &ben, &benAtStudio, &benAtLaptop, &anaAtBen)) return NO;

    // The studio is off: Ben's message reaches the laptop, and the studio has it once it is back.
    if (!SZFE2EStopComputer(studio)) return NO;
    NSString *asleep = @"Ben here, while the studio is off";
    CHECK(SZFE2ESay(ben, anaAtBen, asleep));
    NSString *onLaptop = [laptop.client openConversation:benAtLaptop];
    if (!SZFE2EShowsTexts(laptop, onLaptop, @[ asleep ], 20)) return NO;
    NSString *onBen = [ben.client openConversation:anaAtBen];
    CHECK(SZFE2EWaitUntil(5, ^BOOL {
              return [SZFE2EMessage(ben, onBen, asleep)[@"status"][@"state"] isEqual:@"delivered"];
          }),
          "delivered to Ana: %@", SZFE2EMessage(ben, onBen, asleep));
    if (!SZFE2ERestartComputer(studio)) return NO;
    NSString *onStudio = [studio.client openConversation:benAtStudio];
    if (!SZFE2EShowsTexts(studio, onStudio, @[ asleep ], 20)) return NO;

    // Ben is away: the laptop's message waits, and the studio holds it too.
    if (!SZFE2EStopComputer(ben)) return NO;
    NSString *queued = @"Written on the laptop while Ben was away";
    CHECK(SZFE2ESay(laptop, benAtLaptop, queued));
    if (!SZFE2EShowsTexts(studio, onStudio, @[ asleep, queued ], 15)) return NO;
    CHECK([SZFE2EMessage(laptop, onLaptop, queued)[@"status"][@"state"] isEqual:@"queued"] ||
              [SZFE2EMessage(laptop, onLaptop, queued)[@"status"][@"state"] isEqual:@"connecting"],
          "it waits: %@", SZFE2EMessage(laptop, onLaptop, queued));
    SZFE2EPump(1); // the studio's copy of the outbox entry follows the item

    // The laptop goes off; Ben comes back and gets it from the studio, once.
    if (!SZFE2EStopComputer(laptop) || !SZFE2ERestartComputer(ben)) return NO;
    onBen = [ben.client openConversation:anaAtBen];
    CHECK(SZFE2EWaitUntil(20, ^BOOL { return SZFE2ECount(ben, onBen, queued) == 1; }),
          "Ben gets it from the studio: %@", SZFE2ETexts(ben.client, onBen));
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return [SZFE2EMessage(studio, onStudio, queued)[@"status"][@"state"] isEqual:@"delivered"];
          }),
          "the studio says it was delivered: %@", SZFE2EMessage(studio, onStudio, queued));

    // The laptop comes back: it learns it was delivered, and Ben still has it once.
    if (!SZFE2ERestartComputer(laptop)) return NO;
    onLaptop = [laptop.client openConversation:benAtLaptop];
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              return [SZFE2EMessage(laptop, onLaptop, queued)[@"status"][@"state"] isEqual:@"delivered"];
          }),
          "the laptop shows it delivered: %@", SZFE2EMessage(laptop, onLaptop, queued));
    SZFE2EPump(2);
    CHECK(SZFE2ECount(ben, onBen, queued) == 1, "once: %@", SZFE2ETexts(ben.client, onBen));
    return YES;
}
