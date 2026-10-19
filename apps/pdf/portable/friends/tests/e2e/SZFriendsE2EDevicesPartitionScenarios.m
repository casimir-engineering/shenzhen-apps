// friends-e2e-devices-check: three computers apart, then together (ADR 0014 § Merge rules). Ana's studio and laptop
// stay together; her desk goes apart. Meanwhile both sides write, read Ben's messages, rename Ana, and the desk makes
// a new friend, Cleo. Once the desk is back, the three stores hold the same chats, friends, read state and name.

#import "SZFriendsE2EDevices.h"

static NSString *SZFE2EName(SZFE2EComputer *computer) {
    id name = [computer.client dataFor:computer.profile][@"name"][@"value"];
    return [name isKindOfClass:NSString.class] ? name : @"";
}

static BOOL SZFE2EAllShow(NSArray<SZFE2EComputer *> *computers, NSString *title, NSArray<NSString *> *texts) {
    for (SZFE2EComputer *computer in computers) {
        CHECK(SZFE2EWaitUntil(20, ^BOOL { return SZFE2EListRow(computer, title) != nil; }), "%@ lists %@: %@",
              computer.helper.name, title, [computer.client dataFor:computer.list][@"rows"]);
        NSString *conversation = SZFE2EListRow(computer, title)[@"conversation_id"];
        NSString *open = [computer.client openConversation:conversation];
        BOOL shown = SZFE2EShowsTexts(computer, open, texts, 20);
        [computer.client intent:@"unsubscribe" fields:@{@"subscription" : open}];
        if (!shown) return NO;
    }
    return YES;
}

// The lines of `one` that `other` lacks, and the other way round: what a failing comparison prints.
static NSString *SZFE2EDifference(NSString *one, NSString *other) {
    NSMutableOrderedSet *a = [NSMutableOrderedSet orderedSetWithArray:[one componentsSeparatedByString:@"\n"]];
    NSMutableOrderedSet *b = [NSMutableOrderedSet orderedSetWithArray:[other componentsSeparatedByString:@"\n"]];
    NSMutableOrderedSet *onlyA = [a mutableCopy], *onlyB = [b mutableCopy];
    [onlyA minusOrderedSet:b];
    [onlyB minusOrderedSet:a];
    return [NSString stringWithFormat:@"\n- %@\n+ %@", [onlyA.array componentsJoinedByString:@"\n- "],
                                      [onlyB.array componentsJoinedByString:@"\n+ "]];
}

BOOL SZFE2EDevicesScenarioPartition(SZFE2EWorld *world) {
    SZFE2EComputer *studio = nil, *laptop = nil, *ben = nil;
    NSString *benAtStudio = nil, *benAtLaptop = nil, *anaAtBen = nil;
    if (!SZFE2EStartProfile(world, &studio, &laptop, &ben, &benAtStudio, &benAtLaptop, &anaAtBen)) return NO;
    SZFE2EComputer *desk = SZFE2EStartComputer(world, @"desk", @"Ana", nil, YES);
    CHECK(desk != nil);
    if (!SZFE2EJoin(studio, desk, 25)) return NO;
    NSArray *all = @[ studio, laptop, desk ];
    CHECK(SZFE2ESay(ben, anaAtBen, @"Ben: first") && SZFE2ESay(ben, anaAtBen, @"Ben: second"));
    if (!SZFE2EAllShow(all, @"Ben", @[ @"Ben: first", @"Ben: second" ])) return NO;

    // Apart: the desk with Cleo, whom Ana does not know yet.
    NSString *apart = SZFE2EPartitionType();
    if (!SZFE2EMoveComputer(desk, apart)) return NO;
    SZFE2EComputer *cleo = SZFE2EStartComputer(world, @"cleo", @"Cleo", @{@"SZFRIENDS_TEST_SERVICE_TYPE" : apart}, NO);
    CHECK(cleo != nil);

    // Together: a message to Ben, a note, Ben's answer, and a new name.
    CHECK(SZFE2ESay(studio, benAtStudio, @"Studio, while the desk is away"));
    CHECK(SZFE2ESay(laptop, @"you", @"Laptop note, while the desk is away"));
    CHECK(SZFE2ESay(ben, anaAtBen, @"Ben: third"));
    CHECK([[studio.client intent:@"set_name" fields:@{@"name" : @"Ana Lima"}][@"ok"] boolValue]);
    // Apart: Ben's chat read, a note, another name, and a new friend with a chat.
    NSString *benOnDesk = [desk.client openConversation:SZFE2EListRow(desk, @"Ben")[@"conversation_id"]];
    SZFE2EPump(0.5);
    [desk.client intent:@"unsubscribe" fields:@{@"subscription" : benOnDesk}];
    CHECK(SZFE2ESay(desk, @"you", @"Desk note, while apart"));
    CHECK([[desk.client intent:@"set_name" fields:@{@"name" : @"Ana L."}][@"ok"] boolValue]);
    desk.displayName = @"Ana L.";
    NSString *cleoAtDesk = nil, *anaAtCleo = nil;
    if (!SZFE2EBefriendNearby(desk, cleo, &cleoAtDesk, &anaAtCleo)) return NO;
    CHECK(SZFE2ESay(desk, cleoAtDesk, @"Hello Cleo") && SZFE2ESay(cleo, anaAtCleo, @"Hi Ana"));
    if (!SZFE2EAllShow(@[ desk ], @"Cleo", @[ @"Hello Cleo", @"Hi Ana" ])) return NO;
    NSArray *together = @[ studio, laptop ];
    NSArray *benChat = @[ @"Ben: first", @"Ben: second", @"Studio, while the desk is away", @"Ben: third" ];
    if (!SZFE2EAllShow(together, @"Ben", benChat)) return NO;

    // Together again: every computer holds everything, under one name.
    if (!SZFE2EMoveComputer(desk, nil)) return NO;
    NSArray *notes = @[ @"Laptop note, while the desk is away", @"Desk note, while apart" ];
    if (!SZFE2EAllShow(all, @"Ben", benChat) || !SZFE2EAllShow(all, @"Cleo", @[ @"Hello Cleo", @"Hi Ana" ]) ||
        !SZFE2EAllShow(all, @"You", notes)) {
        return NO;
    }
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              return SZFE2EName(studio).length > 0 && [SZFE2EName(laptop) isEqual:SZFE2EName(studio)] &&
                     [SZFE2EName(desk) isEqual:SZFE2EName(studio)];
          }),
          "one name: %@ / %@ / %@", SZFE2EName(studio), SZFE2EName(laptop), SZFE2EName(desk));
    NSArray *names = @[ @"Ana Lima", @"Ana L." ];
    CHECK([names containsObject:SZFE2EName(studio)], "one of the two: %@", SZFE2EName(studio));
    SZFE2EPump(2); // the last acknowledgements and read markers
    for (SZFE2EComputer *computer in @[ studio, laptop, desk, ben, cleo ]) {
        if (!SZFE2EStopComputer(computer)) return NO;
    }
    NSString *first = SZFE2EStoreDump(studio.helper);
    CHECK(first.length > 0 && [first containsString:@"Hi Ana"], "a store with the chats: %@", first);
    for (SZFE2EComputer *computer in @[ laptop, desk ]) {
        NSString *dump = SZFE2EStoreDump(computer.helper);
        CHECK([dump isEqual:first], "%@'s store is the studio's:%@", computer.helper.name,
              SZFE2EDifference(first, dump ?: @""));
    }
    return YES;
}
