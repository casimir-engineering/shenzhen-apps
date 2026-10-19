// friends-e2e-devices-check: joining a profile (PROTOCOL.md § Joining), nearby and online, and the history that follows
// in both directions.

#import "SZFriendsE2EDevices.h"

#import "SZFriendsE2EOnline.h"

// The conversation `title` on `computer`, opened; nil (a failure recorded) when its row never shows.
static NSString *SZFE2EOpenTitled(SZFE2EComputer *computer, NSString *title, NSString **conversationID) {
    if (!SZFE2EWaitUntil(15, ^BOOL { return SZFE2EListRow(computer, title) != nil; })) {
        SZFE2EFail(__FILE__, __LINE__, "the row shows", [NSString stringWithFormat:@"%@ on %@: %@", title,
                                                         computer.helper.name,
                                                         [computer.client dataFor:computer.list][@"rows"]]);
        return nil;
    }
    *conversationID = SZFE2EListRow(computer, title)[@"conversation_id"];
    return [computer.client openConversation:*conversationID];
}

// Both computers list each other under the names they gave themselves, the other one connected.
static BOOL SZFE2EKnowEachOther(SZFE2EComputer *one, NSString *oneName, SZFE2EComputer *two, NSString *twoName) {
    CHECK([[one.client intent:@"rename_device" fields:@{@"name" : oneName}][@"ok"] boolValue], "rename %@", oneName);
    CHECK([[two.client intent:@"rename_device" fields:@{@"name" : twoName}][@"ok"] boolValue], "rename %@", twoName);
    BOOL (^lists)(SZFE2EComputer *, NSString *, NSString *) = ^BOOL(SZFE2EComputer *c, NSString *me, NSString *other) {
        NSArray<NSDictionary *> *rows = SZFE2EComputerRows(c);
        return rows.count == 2 && [rows[0][@"this_computer"] isEqual:@YES] && [rows[0][@"name"] isEqual:me] &&
               [rows[1][@"name"] isEqual:other] && [rows[1][@"state"] isEqual:@"connected"] &&
               [rows[1][@"last_connected"] isEqual:@"Now"] && [rows[1][@"remove"] isKindOfClass:NSDictionary.class];
    };
    CHECK(SZFE2EWaitUntil(15, ^BOOL { return lists(one, oneName, twoName) && lists(two, twoName, oneName); }),
          "Your computers on each: %@ / %@", SZFE2EComputerRows(one), SZFE2EComputerRows(two));
    return YES;
}

BOOL SZFE2EDevicesScenarioJoinNearby(SZFE2EWorld *world) {
    SZFE2EComputer *studio = SZFE2EStartComputer(world, @"studio", @"Ana", nil, NO);
    SZFE2EComputer *ben = SZFE2EStartComputer(world, @"ben", @"Ben", nil, NO);
    CHECK(studio != nil && ben != nil);
    NSString *benAtStudio = nil, *anaAtBen = nil;
    if (!SZFE2EBefriendNearby(studio, ben, &benAtStudio, &anaAtBen)) return NO;
    CHECK(SZFE2ESay(studio, benAtStudio, @"Before the laptop: samples ship Monday") &&
          SZFE2ESay(ben, anaAtBen, @"Before the laptop: noted"));
    NSString *atStudio = [studio.client openConversation:benAtStudio];
    NSArray *before = @[ @"Before the laptop: samples ship Monday", @"Before the laptop: noted" ];
    if (!SZFE2EShowsTexts(studio, atStudio, before, 15)) return NO;

    // The laptop asks by ID; the studio approves and shows the code; typed on the laptop, it joins.
    SZFE2EComputer *laptop = SZFE2EStartComputer(world, @"laptop", @"Ana", nil, YES);
    CHECK(laptop != nil);
    if (!SZFE2EJoin(studio, laptop, 25)) return NO;
    if (!SZFE2EKnowEachOther(studio, @"Studio Mac", laptop, @"Travel Laptop")) return NO;

    // What the studio had reaches the laptop: Ben, as a friend, with the chat so far.
    NSString *benAtLaptop = nil;
    NSString *atLaptop = SZFE2EOpenTitled(laptop, @"Ben", &benAtLaptop);
    CHECK(atLaptop != nil);
    if (!SZFE2EShowsTexts(laptop, atLaptop, before, 15)) return NO;
    CHECK([SZFE2EListRow(laptop, @"Ben")[@"drop_label"] isKindOfClass:NSString.class], "Ben is a friend there: %@",
          SZFE2EListRow(laptop, @"Ben"));

    // Then both ways: the laptop writes to Ben and to itself, the studio to itself; each sees all of it.
    CHECK(SZFE2ESay(laptop, benAtLaptop, @"From the laptop: on my way"));
    CHECK(SZFE2ESay(laptop, @"you", @"Laptop note: pack the samples") &&
          SZFE2ESay(studio, @"you", @"Studio note: print the labels"));
    NSArray *chat = [before arrayByAddingObject:@"From the laptop: on my way"];
    NSArray *notes = @[ @"Laptop note: pack the samples", @"Studio note: print the labels" ];
    NSString *youAtStudio = [studio.client openConversation:@"you"];
    NSString *youAtLaptop = [laptop.client openConversation:@"you"];
    if (!SZFE2EShowsTexts(studio, atStudio, chat, 15) || !SZFE2EShowsTexts(studio, youAtStudio, notes, 15) ||
        !SZFE2EShowsTexts(laptop, youAtLaptop, notes, 15)) {
        return NO;
    }
    NSString *atBen = [ben.client openConversation:anaAtBen];
    if (!SZFE2EShowsTexts(ben, atBen, chat, 15)) return NO;
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSDictionary *you = SZFE2EListRow(studio, @"You");
              return [you[@"kind"] isEqual:@"you"] && [SZFE2EListRow(laptop, @"You")[@"kind"] isEqual:@"you"];
          }),
          "both list You: %@", [studio.client dataFor:studio.list][@"rows"]);
    // Ben keeps one session with Ana, whichever computer has it: the other one waits rather than dialing him again
    // and again only to be closed.
    for (SZFE2EComputer *computer in @[ studio, laptop ]) {
        NSUInteger ends = [computer.helper.log componentsSeparatedByString:@"session ended (purpose 1,"].count - 1;
        CHECK(ends < 10, "%@ ended %lu sessions with Ben", computer.helper.name, (unsigned long)ends);
    }
    return YES;
}

// The studio and the laptop never meet nearby: the laptop joins, and they sync, through the local host. Ben is the
// laptop's neighbour only, never online: what the studio writes him leaves from the laptop.
BOOL SZFE2EDevicesScenarioJoinOnline(SZFE2EWorld *world) {
    NSString *why = nil;
    SZFE2EOnlineHost *host = [SZFE2EOnlineHost startInWorld:world relay:NO skip:&why];
    if (host == nil) {
        if (why != nil) printf("skip devices online: %s\n", why.UTF8String);
        return why != nil;
    }
    @try {
        // The studio browses a Bonjour type of its own; the laptop the scenario's, with Ben.
        SZFE2EComputer *studio = SZFE2EStartComputer(world, @"studio", @"Ana", [host environmentForHelper:@"studio"],
                                                     NO);
        CHECK(studio != nil && [studio.client.welcome[@"capabilities"] containsObject:@"host.checkin"]);
        CHECK(SZFE2EWaitUntil(10, ^BOOL { return SZFE2EFriendsID(studio).length > 0; }), "the studio has an ID");
        NSMutableDictionary *nearBen = [[host environmentForHelper:@"laptop"] mutableCopy];
        [nearBen removeObjectForKey:@"SZFRIENDS_TEST_SERVICE_TYPE"];
        SZFE2EComputer *laptop = SZFE2EStartComputer(world, @"laptop", @"Ana", nearBen, YES);
        SZFE2EComputer *ben = SZFE2EStartComputer(world, @"ben", @"Ben", nil, NO);
        CHECK(laptop != nil && ben != nil);
        if (!SZFE2EJoin(studio, laptop, 25)) return NO;
        if (!SZFE2EKnowEachOther(studio, @"Studio Mac", laptop, @"Travel Laptop")) return NO;
        CHECK(SZFE2ESay(laptop, @"you", @"Laptop note, online") && SZFE2ESay(studio, @"you", @"Studio note, online"));
        NSArray *notes = @[ @"Studio note, online", @"Laptop note, online" ];
        NSString *youAtStudio = [studio.client openConversation:@"you"];
        NSString *youAtLaptop = [laptop.client openConversation:@"you"];
        if (!SZFE2EShowsTexts(studio, youAtStudio, notes, 20) || !SZFE2EShowsTexts(laptop, youAtLaptop, notes, 20)) {
            return NO;
        }

        // Ben, befriended on the laptop, reaches the studio by sync; the studio's message to him goes by the laptop.
        NSString *benAtLaptop = nil, *anaAtBen = nil;
        if (!SZFE2EBefriendNearby(laptop, ben, &benAtLaptop, &anaAtBen)) return NO;
        CHECK(SZFE2EWaitUntil(20, ^BOOL { return SZFE2EListRow(studio, @"Ben") != nil; }), "Ben reaches the studio: %@",
              [studio.client dataFor:studio.list][@"rows"]);
        CHECK(SZFE2ESay(studio, SZFE2EListRow(studio, @"Ben")[@"conversation_id"], @"From the studio, by the laptop"));
        NSString *atBen = [ben.client openConversation:anaAtBen];
        if (!SZFE2EShowsTexts(ben, atBen, @[ @"From the studio, by the laptop" ], 20)) return NO;
    } @finally {
        [host stop];
    }
    return YES;
}
