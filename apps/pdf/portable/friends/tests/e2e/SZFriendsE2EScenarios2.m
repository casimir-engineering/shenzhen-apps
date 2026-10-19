// friends-e2e-check: Add by ID, blocking, outbox expiry, two windows on one helper, and moving between routes.

#import "SZFriendsE2EScenarios.h"

// Add by ID nearby: A types B's ID; B, the only device holding it, gets the request; B accepts and calls A back;
// both show the same comparison code. With no Friends host to vouch for B, A accepts B's answer herself (wave-4
// re-check: anyone nearby who heard the request could have answered it).
BOOL SZFE2EScenarioAddByID(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil)) return NO;
    NSString *profileB = [pair.b subscribe:@"profile" params:nil];
    NSString *friendsID = [pair.b dataFor:profileB][@"id"][@"friends_id"];
    CHECK(friendsID.length > 0, "B has an ID before any host contact: %@", [pair.b dataFor:profileB]);
    NSDictionary *reply = [pair.a intent:@"add_by_id" fields:@{@"friends_id" : friendsID}];
    NSString *bAtA = reply[@"result"][@"conversation_id"];
    CHECK(bAtA != nil && [reply[@"result"][@"message"] length] > 0, "%@", reply);
    __block NSString *aAtB = nil;
    CHECK(SZFE2EWaitUntil(25, ^BOOL {
              for (NSDictionary *row in [pair.b dataFor:pair.listB][@"rows"]) {
                  if ([row[@"waiting"] isKindOfClass:[NSDictionary class]]) aAtB = row[@"conversation_id"];
              }
              return aAtB != nil;
          }),
          "B received the request by ID: %@", [pair.b dataFor:pair.listB]);
    CHECK([[pair.b intent:@"accept_request" fields:@{@"conversation_id" : aAtB}][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(25, ^BOOL {
              NSDictionary *row = SZFE2ERowWithID([pair.a dataFor:pair.listA], bAtA);
              return [row[@"subtitle"] hasPrefix:@"Answered your request for "];
          }),
          "B called back; A is asked before B is a friend: %@", [pair.a dataFor:pair.listA]);
    NSString *title = SZFE2ERowWithID([pair.a dataFor:pair.listA], bAtA)[@"title"];
    if (!SZFE2EAcceptAnswer(pair.a, pair.listA, title)) return NO;
    NSString *detailsA = [pair.a subscribe:@"details" params:@{@"conversation_id" : bAtA}];
    NSString *detailsB = [pair.b subscribe:@"details" params:@{@"conversation_id" : aAtB}];
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              id codeA = [pair.a dataFor:detailsA][@"verification"][@"comparison_code"];
              id codeB = [pair.b dataFor:detailsB][@"verification"][@"comparison_code"];
              return [codeA isKindOfClass:[NSString class]] && [codeA isEqual:codeB];
          }),
          "matching codes: %@ / %@", [pair.a dataFor:detailsA][@"verification"],
          [pair.b dataFor:detailsB][@"verification"]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return [SZFE2ERowWithID([pair.b dataFor:pair.listB], aAtB)[@"title"] isEqual:@"Ana"];
          }),
          "A's profile reached B: %@", SZFE2ERowWithID([pair.b dataFor:pair.listB], aAtB));
    return YES;
}

// A blocks B: B cannot reconnect, B's messages do not arrive, and a new request from B is dropped.
BOOL SZFE2EScenarioBlock(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    CHECK([[pair.a intent:@"block" fields:@{@"conversation_id" : pair.bAtA}][@"ok"] boolValue]);
    NSString *atB = [pair.b openConversation:pair.aAtB];
    NSString *atA = [pair.a openConversation:pair.bAtA];
    NSDictionary *sent = [pair.b intent:@"send_message" fields:@{@"conversation_id" : pair.aAtB, @"text" : @"hello?",
                                                                 @"client_token" : SZFE2EToken()}];
    CHECK([sent[@"ok"] boolValue], "B can still send; it was never told: %@", sent);
    NSString *profileA = [pair.a subscribe:@"profile" params:nil];
    NSString *idA = [pair.a dataFor:profileA][@"id"][@"friends_id"];
    // B removes A and asks again by ID: A must drop it after the same uniform reply.
    CHECK([[pair.b intent:@"remove_friend" fields:@{@"conversation_id" : pair.aAtB}][@"ok"] boolValue]);
    NSDictionary *reply = [pair.b intent:@"add_by_id" fields:@{@"friends_id" : idA}];
    CHECK([reply[@"ok"] boolValue], "B may ask: it was never told it is blocked: %@", reply);
    SZFE2EPump(8);
    NSDictionary *message = SZFE2EItems([pair.b dataFor:atB], @"message").lastObject;
    CHECK(![message[@"status"][@"state"] isEqual:@"delivered"], "not delivered: %@", message);
    CHECK(SZFE2EItems([pair.a dataFor:atA], @"message").count == 0, "nothing arrived: %@", [pair.a dataFor:atA]);
    for (NSDictionary *row in [pair.a dataFor:pair.listA][@"rows"]) {
        CHECK(row[@"waiting"] == [NSNull null], "no request reached A: %@", row);
        CHECK(![row[@"route"][@"kind"] isEqual:@"local"], "no session with B: %@", row);
    }
    CHECK([SZFE2ERowWithID([pair.a dataFor:pair.listA], pair.bAtA)[@"blocked"] boolValue], "B shows as blocked");
    return YES;
}

// A message to a friend who never comes back turns Failed after 30 days ("injected" by moving A's outbox clock),
// with Try again; trying again delivers it once the friend is back.
BOOL SZFE2EScenarioExpiry(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    [pair.b close];
    CHECK([pair.helperB terminate], "B leaves");
    NSDictionary *sent = [pair.a intent:@"send_message"
                                 fields:@{@"conversation_id" : pair.bAtA, @"text" : @"still there?",
                                          @"client_token" : SZFE2EToken()}];
    NSString *messageID = sent[@"result"][@"message_id"];
    CHECK(messageID.length > 0);
    [pair.a close];
    CHECK([pair.helperA terminate]);
    pair.helperA.extraEnvironment = @{@"SZFRIENDS_E2E_CLOCK_OFFSET" : [@(31 * 24 * 3600) stringValue]};
    CHECK([pair.helperA start], "A starts 31 days later");
    pair.a = [SZFE2EClient clientForHelper:pair.helperA];
    CHECK(pair.a != nil);
    NSString *atA = [pair.a openConversation:pair.bAtA];
    CHECK(SZFE2EWaitUntil(5, ^BOOL {
              NSDictionary *item = SZFE2EItems([pair.a dataFor:atA], @"message").lastObject;
              return [item[@"status"][@"state"] isEqual:@"failed"];
          }),
          "Failed after 30 days: %@", SZFE2EItems([pair.a dataFor:atA], @"message").lastObject);
    NSDictionary *failed = SZFE2EItems([pair.a dataFor:atA], @"message").lastObject;
    BOOL offersRetry = NO;
    for (NSDictionary *action in failed[@"actions"]) {
        offersRetry = offersRetry || [action[@"action"] isEqual:@"retry_item"];
    }
    CHECK(offersRetry, "Try again: %@", failed);
    CHECK([[pair.a intent:@"retry_item" fields:@{@"item_id" : messageID}][@"ok"] boolValue]);
    pair.helperB.extraEnvironment = @{};
    CHECK([pair.helperB start], "B is back");
    CHECK(SZFE2EWaitUntil(30, ^BOOL {
              NSDictionary *item = SZFE2EItems([pair.a dataFor:atA], @"message").lastObject;
              return [item[@"status"][@"state"] isEqual:@"delivered"];
          }),
          "delivered after Try again: %@", SZFE2EItems([pair.a dataFor:atA], @"message").lastObject);
    return YES;
}

// Two windows on one helper show the same badge, and an answer in one changes both.
BOOL SZFE2EScenarioSameBadge(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    SZFE2EClient *second = [SZFE2EClient clientForHelper:pair.helperB];
    CHECK(second != nil, "a second window");
    NSString *badge1 = [pair.b subscribe:@"badge" params:nil], *badge2 = [second subscribe:@"badge" params:nil];
    NSString *source = [world fileOfSize:64 * 1024 named:@"plan.pdf"];
    NSDictionary *reply = [pair.a intent:@"send_files" fields:@{@"conversation_id" : pair.bAtA,
                                                                @"files" : @[ @{@"path" : source} ],
                                                                @"client_token" : SZFE2EToken()}];
    NSString *transferID = [reply[@"result"][@"transfer_ids"] firstObject];
    CHECK(transferID != nil, "%@", reply);
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              return [[pair.b dataFor:badge1][@"count"] intValue] == 1 &&
                     [[pair.b dataFor:badge1] isEqual:[second dataFor:badge2]];
          }),
          "both windows count the offer: %@ / %@", [pair.b dataFor:badge1], [second dataFor:badge2]);
    CHECK([[second intent:@"decline_offer" fields:@{@"transfer_id" : transferID}][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(5, ^BOOL {
              return [[pair.b dataFor:badge1][@"count"] intValue] == 0 &&
                     [[pair.b dataFor:badge1] isEqual:[second dataFor:badge2]];
          }),
          "both windows drop it: %@ / %@", [pair.b dataFor:badge1], [second dataFor:badge2]);
    [second close];
    return YES;
}

// Friends over the scripted Bluetooth alone (Nearby not opened yet, so the network adapter waits); a file starts
// over it; opening Friends starts the loopback network, the faster session wins the race, and the transfer moves to
// it mid-file and still verifies.
BOOL SZFE2EScenarioBluetoothToNetwork(SZFE2EWorld *world) {
    NSDictionary *env = @{@"SZFRIENDS_E2E_BLUETOOTH_DIR" : world.bluetoothDirectory};
    SZFE2EHelper *helperA = [world helperNamed:@"a"], *helperB = [world helperNamed:@"b"];
    helperA.extraEnvironment = env;
    helperB.extraEnvironment = env;
    CHECK([helperA start] && [helperB start]);
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    pair.helperA = helperA;
    pair.helperB = helperB;
    pair.a = [SZFE2EClient clientForHelper:helperA];
    pair.b = [SZFE2EClient clientForHelper:helperB];
    CHECK(pair.a != nil && pair.b != nil);
    CHECK([pair.a.welcome[@"capabilities"] containsObject:@"nearby.bluetooth"], "%@", pair.a.welcome);
    // Named but not activated: only the "Bluetooth" adapter (permission already allowed) runs.
    CHECK([[pair.a intent:@"set_name" fields:@{@"name" : @"Ana"}][@"ok"] boolValue]);
    CHECK([[pair.b intent:@"set_name" fields:@{@"name" : @"Ben"}][@"ok"] boolValue]);
    pair.listA = [pair.a subscribe:@"list" params:nil];
    pair.listB = [pair.b subscribe:@"list" params:nil];
    if (!SZFE2EBefriend(pair)) return NO;
    NSString *source = [world fileOfSize:3 * 1024 * 1024 named:@"drawings.pdf"];
    NSDictionary *reply = [pair.a intent:@"send_files" fields:@{@"conversation_id" : pair.bAtA,
                                                                @"files" : @[ @{@"path" : source} ],
                                                                @"client_token" : SZFE2EToken()}];
    NSString *transferID = [reply[@"result"][@"transfer_ids"] firstObject];
    NSString *atB = [pair.b openConversation:pair.aAtB];
    __block NSDictionary *item = nil;
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              for (NSDictionary *candidate in SZFE2EItems([pair.b dataFor:atB], @"transfer")) {
                  if ([candidate[@"transfer_id"] isEqual:transferID]) item = candidate;
              }
              return item != nil;
          }));
    CHECK([[pair.b intent:@"accept_offer" fields:@{@"transfer_id" : transferID}][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              NSDictionary *header = [pair.b dataFor:atB][@"header"];
              return [header[@"route"][@"method"] isEqual:@"bluetooth"];
          }),
          "the session runs over Bluetooth: %@", [pair.b dataFor:atB][@"header"]);
    SZFE2EPump(2);
    // Opening Friends starts the network adapters; the LAN session wins the race and the download moves to it.
    CHECK([[pair.a intent:@"activate" fields:nil][@"ok"] boolValue]);
    CHECK([[pair.b intent:@"activate" fields:nil][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              return [[pair.b dataFor:atB][@"header"][@"route"][@"method"] isEqual:@"lan"];
          }),
          "moved to the network: %@", [pair.b dataFor:atB][@"header"]);
    CHECK(SZFE2EWaitUntil(30, ^BOOL {
              for (NSDictionary *candidate in SZFE2EItems([pair.b dataFor:atB], @"transfer")) {
                  if ([candidate[@"transfer_id"] isEqual:transferID]) item = candidate;
              }
              return [item[@"state"] isEqual:@"received"];
          }),
          "finished on the network: %@", item);
    CHECK([[NSData dataWithContentsOfFile:item[@"file"][@"path"]] isEqual:[NSData dataWithContentsOfFile:source]]);
    CHECK([helperA.log rangeOfString:@" resumes at byte "].location != NSNotFound, "resumed mid-file: %@", helperA.log);
    return YES;
}
