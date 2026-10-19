// friends-e2e-devices-check: removing a computer (PROTOCOL.md § Devices; ADR 0012; ADR 0014 § What a removed
// computer still counts for). Ana has three computers and a friend, Ben; the desk's join request shows on the laptop
// too and clears there once the studio added it. The laptop, apart from the others, removes the desk; the desk, still
// unaware, writes a note and reads Ben's question, which only the studio hears. When the laptop comes back, the removal
// reaches the studio and through it Ben and the desk, which shows it was removed and sends nothing more; the late note
// goes from the studio and never reaches the laptop, Ben's question is unread there again as on the laptop; and new
// secrets leave the desk's copies matching nothing. Then a computer removed while
// connected to the one removing it hears it at once, and one removed while away hears it when it comes back nearby.

#import "SZFriendsE2EDevices.h"

static NSString *SZFE2EDeviceIDNamed(SZFE2EComputer *computer, NSString *name) {
    for (NSDictionary *row in SZFE2EComputerRows(computer)) {
        if ([row[@"name"] isEqual:name]) return row[@"device_id"];
    }
    return nil;
}

BOOL SZFE2EDevicesScenarioRevoke(SZFE2EWorld *world) {
    SZFE2EComputer *studio = nil, *laptop = nil, *ben = nil;
    NSString *benAtStudio = nil, *benAtLaptop = nil, *anaAtBen = nil;
    if (!SZFE2EStartProfile(world, &studio, &laptop, &ben, &benAtStudio, &benAtLaptop, &anaAtBen)) return NO;
    SZFE2EComputer *desk = SZFE2EStartComputer(world, @"desk", @"Ana", nil, YES);
    CHECK(desk != nil);
    if (!SZFE2EJoinWatched(studio, desk, @[ laptop ], 25)) return NO;
    CHECK([[desk.client intent:@"rename_device" fields:@{@"name" : @"Desk Mac"}][@"ok"] boolValue]);
    NSArray *three = @[ @"Studio Mac", @"Travel Laptop", @"Desk Mac" ];
    if (!SZFE2EComputersListed(@[ studio, laptop, desk ], three, 20)) return NO;
    CHECK(SZFE2ESay(desk, @"you", @"Desk note before the partition"));
    NSString *youAtStudio = [studio.client openConversation:@"you"];
    NSArray *before = @[ @"Desk note before the partition" ];
    if (!SZFE2EShowsTexts(studio, youAtStudio, before, 15)) return NO;
    // Ben asks something nobody reads yet.
    CHECK(SZFE2ESay(ben, anaAtBen, @"Ben: are you there?"));
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              for (SZFE2EComputer *computer in @[ studio, laptop, desk ]) {
                  if (![SZFE2EListRow(computer, @"Ben")[@"unread"] boolValue]) return NO;
              }
              return YES;
          }),
          "Ben's question is unread on every computer: %@", SZFE2EListRow(desk, @"Ben"));

    // The laptop goes apart, once it holds the desk's note, and removes the desk there.
    NSString *youAtLaptop = [laptop.client openConversation:@"you"];
    if (!SZFE2EShowsTexts(laptop, youAtLaptop, before, 15)) return NO;
    if (!SZFE2EMoveComputer(laptop, SZFE2EPartitionType())) return NO;
    NSString *deskID = SZFE2EDeviceIDNamed(laptop, @"Desk Mac");
    CHECK(deskID != nil, "the laptop lists the desk: %@", SZFE2EComputerRows(laptop));
    NSDictionary *reply = [laptop.client intent:@"revoke_device" fields:@{@"device_id" : deskID}];
    CHECK([reply[@"ok"] boolValue], "revoke_device: %@", reply);
    if (!SZFE2EComputersListed(@[ laptop ], @[ @"Travel Laptop", @"Studio Mac" ], 5)) return NO;
    reply = [laptop.client intent:@"revoke_device" fields:@{@"device_id" : deskID}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_found"], "removed once: %@", reply);

    // The desk does not know yet: what it writes now reaches the studio, which does not know either.
    CHECK(SZFE2ESay(desk, @"you", @"Desk note after its removal"));
    NSArray *both = @[ @"Desk note before the partition", @"Desk note after its removal" ];
    if (!SZFE2EShowsTexts(studio, youAtStudio, both, 15)) return NO;
    // Nobody but the desk has read Ben's question: its reading reaches the studio.
    NSString *benAtDesk = SZFE2EListRow(desk, @"Ben")[@"conversation_id"];
    CHECK(benAtDesk != nil && [desk.client openConversation:benAtDesk] != nil, "the desk opens Ben's conversation");
    CHECK(SZFE2EWaitUntil(15, ^BOOL { return ![SZFE2EListRow(studio, @"Ben")[@"unread"] boolValue]; }),
          "read on the studio too: %@", SZFE2EListRow(studio, @"Ben"));

    // The laptop comes back: the studio hears of the removal, tells the desk and Ben, and drops the late note.
    if (!SZFE2EMoveComputer(laptop, nil)) return NO;
    youAtLaptop = [laptop.client openConversation:@"you"];
    if (!SZFE2EComputersListed(@[ studio, laptop ], @[ @"Studio Mac", @"Travel Laptop" ], 20)) return NO;
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              NSDictionary *list = [desk.client dataFor:desk.list];
              return [list[@"state"] isEqual:@"device_removed"] &&
                     [list[@"removed"][@"title"] isEqual:@"This computer was removed from your profile"];
          }),
          "the desk shows it was removed: %@ %@", [desk.client dataFor:desk.list][@"state"],
          [desk.client dataFor:desk.list][@"removed"]);
    reply = [desk.client intent:@"send_message" fields:@{@"conversation_id" : @"you", @"text" : @"Still here?",
                                                         @"client_token" : SZFE2ERandomToken()}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_allowed"], "the desk sends nothing more: %@", reply);
    // The laptop, which removed the desk, never takes its late note; the studio, which had it, drops it once the
    // removal's record arrives, so both show the same.
    CHECK(SZFE2ESay(laptop, @"you", @"Laptop note after the removal"));
    NSArray *kept = @[ @"Desk note before the partition", @"Laptop note after the removal" ];
    if (!SZFE2EShowsTexts(studio, youAtStudio, kept, 15) || !SZFE2EShowsTexts(laptop, youAtLaptop, kept, 5)) {
        return NO;
    }
    // Only the desk's late reading had marked Ben's question read: it is unread again on the studio, as on the laptop.
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return [SZFE2EListRow(studio, @"Ben")[@"unread"] boolValue] &&
                     [SZFE2EListRow(laptop, @"Ben")[@"unread"] boolValue];
          }),
          "unread again on the studio: %@ / laptop: %@", SZFE2EListRow(studio, @"Ben"), SZFE2EListRow(laptop, @"Ben"));

    // Ben holds Ana's computers as the profile does, and the new secrets the desk lacks.
    for (SZFE2EComputer *computer in @[ studio, laptop, desk, ben ]) {
        if (!SZFE2EStopComputer(computer)) return NO;
    }
    NSString *secret = SZFE2EStorePresenceSecret(studio.helper);
    CHECK(secret != nil && [SZFE2EStorePresenceSecret(laptop.helper) isEqual:secret],
          "the laptop has the studio's new secret");
    // The studio draws it as the removal reaches it, moments before the computers stop: Ben may get it only at his next
    // session with Ana's computers.
    for (int round = 0; round < 3 && ![SZFE2EStoreFriendPresenceSecret(ben.helper, @"Ana") isEqual:secret]; round++) {
        if (!SZFE2ERestartComputer(studio) || !SZFE2ERestartComputer(ben)) return NO;
        SZFE2EPump(2);
        if (!SZFE2EStopComputer(studio) || !SZFE2EStopComputer(ben)) return NO;
    }
    CHECK([SZFE2EStoreFriendPresenceSecret(ben.helper, @"Ana") isEqual:secret], "and Ben finds Ana by it");
    CHECK(![SZFE2EStorePresenceSecret(desk.helper) isEqual:secret], "the desk's secret matches nothing");
    NSString *standing = SZFE2EStoreFriendComputers(ben.helper, @"Ana");
    CHECK([standing isEqual:@"authorized 2 revoked 1"], "Ben accepts two of Ana's computers: %@", standing);

    // A computer removed while connected to the one removing it hears it at once.
    if (!SZFE2ERestartComputer(studio) || !SZFE2ERestartComputer(laptop)) return NO;
    if (!SZFE2EComputersListed(@[ studio, laptop ], @[ @"Studio Mac", @"Travel Laptop" ], 15)) return NO;
    CHECK(SZFE2EWaitUntil(15, ^BOOL { return [SZFE2EComputerRows(studio)[1][@"state"] isEqual:@"connected"]; }),
          "connected: %@", SZFE2EComputerRows(studio));
    reply = [studio.client intent:@"revoke_device" fields:@{@"device_id" : SZFE2EThisDeviceID(laptop)}];
    CHECK([reply[@"ok"] boolValue], "the studio removes the laptop: %@", reply);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return [[laptop.client dataFor:laptop.list][@"state"] isEqual:@"device_removed"];
          }),
          "the laptop shows it was removed: %@", [laptop.client dataFor:laptop.list][@"removed"]);
    return YES;
}

// Removed while it was away: the laptop is off when the studio removes it. Back nearby, the studio finds it by the tags
// it still advertises, and the laptop shows it was removed and sends nothing more.
BOOL SZFE2EDevicesScenarioRemovedWhileAway(SZFE2EWorld *world) {
    SZFE2EComputer *studio = nil, *laptop = nil, *ben = nil;
    NSString *benAtStudio = nil, *benAtLaptop = nil, *anaAtBen = nil;
    if (!SZFE2EStartProfile(world, &studio, &laptop, &ben, &benAtStudio, &benAtLaptop, &anaAtBen)) return NO;
    NSString *laptopID = SZFE2EThisDeviceID(laptop);
    CHECK(laptopID != nil);
    if (!SZFE2EStopComputer(laptop)) return NO;
    NSDictionary *reply = [studio.client intent:@"revoke_device" fields:@{@"device_id" : laptopID}];
    CHECK([reply[@"ok"] boolValue], "the studio removes the laptop while it is off: %@", reply);
    if (!SZFE2EComputersListed(@[ studio ], @[ @"Studio Mac" ], 5)) return NO;
    if (!SZFE2ERestartComputer(laptop)) return NO;
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              NSDictionary *list = [laptop.client dataFor:laptop.list];
              return [list[@"state"] isEqual:@"device_removed"] &&
                     [list[@"removed"][@"title"] isEqual:@"This computer was removed from your profile"];
          }),
          "back nearby, the laptop shows it was removed: %@", [laptop.client dataFor:laptop.list][@"state"]);
    reply = [laptop.client intent:@"send_message" fields:@{@"conversation_id" : @"you", @"text" : @"Still here?",
                                                           @"client_token" : SZFE2ERandomToken()}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_allowed"], "it sends nothing more: %@", reply);
    return YES;
}
