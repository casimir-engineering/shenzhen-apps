// friends-e2e-devices-check: one history on every computer (PROTOCOL.md § Devices). Deleting one chat on one computer,
// then all history on the other while the first is apart, empties those chats everywhere (the apart one once it is
// back) and keeps the friend; a file sent to You lands on the other computer; a large file from a friend stays on the
// computer that received it until Get copies it.

#import "SZFriendsE2EDevices.h"

static NSArray *SZFE2ESearch(SZFE2EComputer *computer, NSString *query) {
    NSDictionary *found = [computer.client intent:@"search_messages" fields:@{@"query" : query}];
    return [found[@"ok"] boolValue] ? found[@"result"][@"results"] : nil;
}

BOOL SZFE2EDevicesScenarioErase(SZFE2EWorld *world) {
    SZFE2EComputer *studio = nil, *laptop = nil, *ben = nil;
    NSString *benAtStudio = nil, *benAtLaptop = nil, *anaAtBen = nil;
    if (!SZFE2EStartProfile(world, &studio, &laptop, &ben, &benAtStudio, &benAtLaptop, &anaAtBen)) return NO;
    CHECK(SZFE2ESay(studio, benAtStudio, @"kiwi orchard plan") && SZFE2ESay(ben, anaAtBen, @"kiwi reply from Ben") &&
          SZFE2ESay(laptop, @"you", @"mango note to myself"));
    NSArray *chat = @[ @"kiwi orchard plan", @"kiwi reply from Ben" ], *notes = @[ @"mango note to myself" ];
    NSString *benOnLaptop = [laptop.client openConversation:benAtLaptop];
    NSString *benOnStudio = [studio.client openConversation:benAtStudio];
    NSString *youOnStudio = [studio.client openConversation:@"you"];
    NSString *youOnLaptop = [laptop.client openConversation:@"you"];
    NSString *anaOnBen = [ben.client openConversation:anaAtBen];
    if (!SZFE2EShowsTexts(laptop, benOnLaptop, chat, 15) || !SZFE2EShowsTexts(studio, youOnStudio, notes, 15) ||
        !SZFE2EShowsTexts(ben, anaOnBen, chat, 15)) {
        return NO;
    }
    NSString *settings = [laptop.client subscribe:@"settings" params:nil];
    CHECK(SZFE2EWaitUntil(5, ^BOOL {
              return [[laptop.client dataFor:settings][@"history"][@"note"] hasPrefix:@"Stored on all your computers"];
          }),
          "the history note says it is on every computer: %@", [laptop.client dataFor:settings][@"history"]);

    // Ben's chat, deleted on the studio: gone from the laptop too, You stays, and Ben keeps his own copy.
    NSDictionary *reply = [studio.client intent:@"delete_history" fields:@{@"conversation_id" : benAtStudio}];
    CHECK([reply[@"ok"] boolValue], "delete Ben's chat: %@", reply);
    if (!SZFE2EShowsTexts(studio, benOnStudio, @[], 5) || !SZFE2EShowsTexts(laptop, benOnLaptop, @[], 15)) return NO;
    CHECK([SZFE2ESearch(laptop, @"kiwi") count] == 0, "the laptop's search finds nothing of it: %@",
          SZFE2ESearch(laptop, @"kiwi"));
    if (!SZFE2EShowsTexts(laptop, youOnLaptop, notes, 1)) return NO;
    SZFE2EPump(1);
    if (!SZFE2EShowsTexts(ben, anaOnBen, chat, 1)) return NO;

    // All history, deleted on the laptop while the studio is apart: You empties on the studio once it is back, and Ben
    // stays a friend on both.
    if (!SZFE2EMoveComputer(studio, SZFE2EPartitionType())) return NO;
    reply = [laptop.client intent:@"delete_history" fields:nil];
    CHECK([reply[@"ok"] boolValue], "delete all history: %@", reply);
    if (!SZFE2EShowsTexts(laptop, youOnLaptop, @[], 5)) return NO;
    youOnStudio = [studio.client openConversation:@"you"];
    if (!SZFE2EShowsTexts(studio, youOnStudio, notes, 5)) return NO; // apart, it still has them
    if (!SZFE2EMoveComputer(studio, nil)) return NO;
    youOnStudio = [studio.client openConversation:@"you"];
    benOnStudio = [studio.client openConversation:benAtStudio];
    if (!SZFE2EShowsTexts(studio, youOnStudio, @[], 20)) return NO;
    CHECK([SZFE2ESearch(studio, @"mango") count] == 0, "the studio's search finds nothing");
    CHECK([SZFE2EListRow(studio, @"Ben")[@"drop_label"] isKindOfClass:NSString.class] &&
              [SZFE2EListRow(laptop, @"Ben")[@"drop_label"] isKindOfClass:NSString.class],
          "Ben is still a friend on both: %@", [studio.client dataFor:studio.list][@"rows"]);
    // What comes after the deletion is kept.
    CHECK(SZFE2ESay(ben, anaAtBen, @"kiwi again"));
    return SZFE2EShowsTexts(studio, benOnStudio, @[ @"kiwi again" ], 15) &&
           SZFE2EShowsTexts(laptop, benOnLaptop, @[ @"kiwi again" ], 15);
}

static NSDictionary *SZFE2ETransfer(SZFE2EComputer *computer, NSString *subscription, NSString *transferID) {
    for (NSDictionary *item in SZFE2EKindItems([computer.client dataFor:subscription], @"transfer")) {
        if ([item[@"transfer_id"] isEqual:transferID]) return item;
    }
    return nil;
}

static BOOL SZFE2EHasAction(NSDictionary *item, NSString *action) {
    for (NSDictionary *entry in item[@"actions"]) {
        if ([entry[@"action"] isEqual:action]) return YES;
    }
    return NO;
}

static BOOL SZFE2EReceivedIntact(SZFE2EComputer *computer, NSString *subscription, NSString *transferID,
                                 NSString *source, NSTimeInterval timeout) {
    CHECK(SZFE2EWaitUntil(timeout, ^BOOL {
              return [SZFE2ETransfer(computer, subscription, transferID)[@"state"] isEqual:@"received"];
          }),
          "%@ receives it: %@", computer.helper.name, SZFE2ETransfer(computer, subscription, transferID));
    NSString *path = SZFE2ETransfer(computer, subscription, transferID)[@"file"][@"path"];
    CHECK([path isKindOfClass:NSString.class] &&
              [[NSData dataWithContentsOfFile:path] isEqual:[NSData dataWithContentsOfFile:source]],
          "byte for byte on %@: %@", computer.helper.name, path);
    return YES;
}

BOOL SZFE2EDevicesScenarioYou(SZFE2EWorld *world) {
    SZFE2EComputer *studio = nil, *laptop = nil, *ben = nil;
    NSString *benAtStudio = nil, *benAtLaptop = nil, *anaAtBen = nil;
    if (!SZFE2EStartProfile(world, &studio, &laptop, &ben, &benAtStudio, &benAtLaptop, &anaAtBen)) return NO;

    // A file to yourself: it lands on the laptop, and the studio then says it is on every computer.
    NSString *pages = [world fileOfSize:3 * 1024 * 1024 named:@"Pages 3 to 5.pdf"];
    NSDictionary *reply = [studio.client intent:@"send_files" fields:@{@"conversation_id" : @"you",
                                                                      @"files" : @[ @{@"path" : pages} ],
                                                                      @"client_token" : SZFE2ERandomToken()}];
    NSString *toSelf = [reply[@"result"][@"transfer_ids"] firstObject];
    CHECK(toSelf != nil, "send_files to You: %@", reply);
    NSString *youOnStudio = [studio.client openConversation:@"you"];
    NSString *youOnLaptop = [laptop.client openConversation:@"you"];
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              NSDictionary *item = SZFE2ETransfer(laptop, youOnLaptop, toSelf);
              id path = item[@"file"][@"path"];
              return [path isKindOfClass:NSString.class] &&
                     [[NSData dataWithContentsOfFile:path] isEqual:[NSData dataWithContentsOfFile:pages]];
          }),
          "the laptop has it, byte for byte: %@", SZFE2ETransfer(laptop, youOnLaptop, toSelf));
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSDictionary *item = SZFE2ETransfer(laptop, youOnLaptop, toSelf);
              return [item[@"status_label"] isEqual:@"On all your computers"] && SZFE2EHasAction(item, @"show_file") &&
                     !SZFE2EHasAction(item, @"cancel_transfer");
          }),
          "there it opens, with nothing to stop: %@", SZFE2ETransfer(laptop, youOnLaptop, toSelf));
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return [SZFE2ETransfer(studio, youOnStudio, toSelf)[@"status_label"] isEqual:@"On all your computers"];
          }),
          "the studio says it is on every computer: %@", SZFE2ETransfer(studio, youOnStudio, toSelf));

    // Ben's large file reaches whichever computer Ben reached; the other shows where it is.
    NSString *audit = [world fileOfSize:26 * 1000 * 1000 named:@"Factory audit.pdf"];
    reply = [ben.client intent:@"send_files" fields:@{@"conversation_id" : anaAtBen,
                                                      @"files" : @[ @{@"path" : audit} ],
                                                      @"client_token" : SZFE2ERandomToken()}];
    NSString *large = [reply[@"result"][@"transfer_ids"] firstObject];
    CHECK(large != nil, "Ben offers a large file: %@", reply);
    NSString *onStudio = [studio.client openConversation:benAtStudio];
    NSString *onLaptop = [laptop.client openConversation:benAtLaptop];
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              return SZFE2EHasAction(SZFE2ETransfer(studio, onStudio, large), @"accept_offer") ||
                     SZFE2EHasAction(SZFE2ETransfer(laptop, onLaptop, large), @"accept_offer");
          }),
          "the offer arrives: %@ / %@", SZFE2ETransfer(studio, onStudio, large),
          SZFE2ETransfer(laptop, onLaptop, large));
    BOOL studioHolds = SZFE2EHasAction(SZFE2ETransfer(studio, onStudio, large), @"accept_offer");
    SZFE2EComputer *holder = studioHolds ? studio : laptop, *other = studioHolds ? laptop : studio;
    NSString *atHolder = studioHolds ? onStudio : onLaptop, *atOther = studioHolds ? onLaptop : onStudio;
    NSString *holderName = studioHolds ? @"Studio Mac" : @"Travel Laptop";
    CHECK([[holder.client intent:@"accept_offer" fields:@{@"transfer_id" : large}][@"ok"] boolValue], "accept");
    if (!SZFE2EReceivedIntact(holder, atHolder, large, audit, 20)) return NO;
    NSString *label = [@"On " stringByAppendingString:holderName];
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              NSDictionary *item = SZFE2ETransfer(other, atOther, large);
              return [item[@"state"] isEqual:@"on_device"] && [item[@"status_label"] isEqual:label] &&
                     SZFE2EHasAction(item, @"fetch_from_device");
          }),
          "the other computer shows where it is: %@", SZFE2ETransfer(other, atOther, large));
    SZFE2EPump(1);
    CHECK([SZFE2ETransfer(other, atOther, large)[@"state"] isEqual:@"on_device"], "over 25 MB, it waits for Get");
    reply = [other.client intent:@"fetch_from_device" fields:@{@"transfer_id" : large}];
    CHECK([reply[@"ok"] boolValue], "Get: %@", reply);
    return SZFE2EReceivedIntact(other, atOther, large, audit, 30);
}
