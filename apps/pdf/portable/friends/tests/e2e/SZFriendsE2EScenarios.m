// friends-e2e-check: requests, messages and transfers between two real helpers.

#import "SZFriendsE2EScenarios.h"

static NSDictionary *SZFE2ETransferItem(NSDictionary *conversation, NSString *transferID) {
    for (NSDictionary *item in SZFE2EItems(conversation, @"transfer")) {
        if ([item[@"transfer_id"] isEqual:transferID]) return item;
    }
    return nil;
}

static NSString *SZFE2ESendFile(SZFE2EClient *client, NSString *conversationID, NSString *path) {
    NSDictionary *reply = [client intent:@"send_files"
                                  fields:@{@"conversation_id" : conversationID, @"files" : @[ @{@"path" : path} ],
                                           @"client_token" : SZFE2EToken()}];
    return [reply[@"result"][@"transfer_ids"] firstObject];
}

// Public visibility, a request from Nearby, the same comparison code on both screens, acceptance; then the codes
// stay comparable in friend details while a session is up, and both histories say they are now friends.
BOOL SZFE2EScenarioRequest(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    NSString *detailsA = [pair.a subscribe:@"details" params:@{@"conversation_id" : pair.bAtA}];
    NSString *detailsB = [pair.b subscribe:@"details" params:@{@"conversation_id" : pair.aAtB}];
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return [[pair.a dataFor:detailsA][@"verification"][@"comparison_code"] isEqual:pair.codeA] &&
                     [[pair.b dataFor:detailsB][@"verification"][@"comparison_code"] isEqual:pair.codeA];
          }),
          "details show the code while the session is up: %@ / %@", [pair.a dataFor:detailsA][@"verification"],
          [pair.b dataFor:detailsB][@"verification"]);
    CHECK([[pair.a dataFor:detailsA][@"route"][@"kind"] isEqual:@"local"], "%@", [pair.a dataFor:detailsA][@"route"]);
    NSString *conversation = [pair.a openConversation:pair.bAtA];
    CHECK(SZFE2EWaitUntil(5, ^BOOL { return SZFE2EItems([pair.a dataFor:conversation], @"event").count > 0; }),
          "a 'now friends' event: %@", [pair.a dataFor:conversation][@"items"]);
    return YES;
}

// A message arrives once; its sender sees Delivered only after the recipient committed it. With acknowledgements
// withheld the sender keeps it in flight; after the recipient restarts, the resend is recognised as the same
// message and acknowledged, and the recipient still shows one copy.
BOOL SZFE2EScenarioMessages(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    NSString *token = SZFE2EToken();
    NSDictionary *fields =
        @{@"conversation_id" : pair.bAtA, @"text" : @"合同 attached, see you at 3", @"client_token" : token};
    NSString *messageID = [pair.a intent:@"send_message" fields:fields][@"result"][@"message_id"];
    CHECK(messageID.length > 0, "sent");
    CHECK([[pair.a intent:@"send_message" fields:fields][@"result"][@"message_id"] isEqual:messageID],
          "the same client token sends once");
    NSString *atA = [pair.a openConversation:pair.bAtA], *atB = [pair.b openConversation:pair.aAtB];
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              NSArray *mine = SZFE2EItems([pair.a dataFor:atA], @"message");
              return SZFE2EItems([pair.b dataFor:atB], @"message").count == 1 &&
                     [[mine.lastObject[@"status"] valueForKey:@"state"] isEqual:@"delivered"];
          }),
          "delivered once: %@ / %@", [pair.a dataFor:atA][@"items"], [pair.b dataFor:atB][@"items"]);

    // B now commits but never acknowledges.
    [pair.b close];
    CHECK([pair.helperB terminate], "B exits on SIGTERM");
    pair.helperB.extraEnvironment = @{@"SZFRIENDS_E2E_WITHHOLD_ACKS" : @"1"};
    CHECK([pair.helperB start]);
    pair.b = [SZFE2EClient clientForHelper:pair.helperB];
    CHECK(pair.b != nil);
    NSString *second = [pair.a intent:@"send_message"
                               fields:@{@"conversation_id" : pair.bAtA, @"text" : @"second", @"client_token" :
                                            SZFE2EToken()}][@"result"][@"message_id"];
    CHECK(second.length > 0);
    atB = [pair.b openConversation:pair.aAtB];
    CHECK(SZFE2EWaitUntil(20, ^BOOL { return SZFE2EItems([pair.b dataFor:atB], @"message").count == 2; }),
          "B stored the second message: %@", [pair.b dataFor:atB][@"items"]);
    SZFE2EPump(1.5);
    NSDictionary *pending = SZFE2EItems([pair.a dataFor:atA], @"message").lastObject;
    CHECK(![pending[@"status"][@"state"] isEqual:@"delivered"], "no ACK, no Delivered: %@", pending);

    // B again, acknowledging: A resends the same id, B recognises it.
    [pair.b close];
    CHECK([pair.helperB terminate]);
    pair.helperB.extraEnvironment = @{};
    CHECK([pair.helperB start]);
    pair.b = [SZFE2EClient clientForHelper:pair.helperB];
    CHECK(pair.b != nil);
    atB = [pair.b openConversation:pair.aAtB];
    CHECK(SZFE2EWaitUntil(30, ^BOOL {
              return [[SZFE2EItems([pair.a dataFor:atA], @"message").lastObject[@"status"] valueForKey:@"state"]
                  isEqual:@"delivered"];
          }),
          "Delivered after the resend: %@", SZFE2EItems([pair.a dataFor:atA], @"message").lastObject);
    SZFE2EPump(0.5);
    CHECK(SZFE2EItems([pair.b dataFor:atB], @"message").count == 2, "no duplicate: %@", [pair.b dataFor:atB][@"items"]);
    return YES;
}

// An offer, Accept, the bytes, the digest, and the file published in B's Downloads with the same contents.
BOOL SZFE2EScenarioTransfer(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    NSString *source = [world fileOfSize:3 * 1024 * 1024 + 123 named:@"Site photos.pdf"];
    NSString *transferID = SZFE2ESendFile(pair.a, pair.bAtA, source);
    CHECK(transferID != nil, "offered");
    NSString *atB = [pair.b openConversation:pair.aAtB], *atA = [pair.a openConversation:pair.bAtA];
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              return [SZFE2ETransferItem([pair.b dataFor:atB], transferID)[@"state"] isEqual:@"waiting_for_you"];
          }),
          "B is asked first: %@", [pair.b dataFor:atB][@"items"]);
    CHECK([SZFE2ETransferItem([pair.a dataFor:atA], transferID)[@"state"] isEqual:@"offered"] ||
          SZFE2EWaitUntil(5, ^BOOL {
              return [SZFE2ETransferItem([pair.a dataFor:atA], transferID)[@"state"] isEqual:@"offered"];
          }), "A sees it offered: %@", SZFE2ETransferItem([pair.a dataFor:atA], transferID));
    NSDictionary *reply = [pair.b intent:@"accept_offer" fields:@{@"transfer_id" : transferID}];
    CHECK([reply[@"ok"] boolValue], "%@", reply);
    CHECK(SZFE2EWaitUntil(30, ^BOOL {
              NSDictionary *item = SZFE2ETransferItem([pair.b dataFor:atB], transferID);
              return [item[@"state"] isEqual:@"received"] && [item[@"file"][@"path"] isKindOfClass:[NSString class]];
          }),
          "received: %@", SZFE2ETransferItem([pair.b dataFor:atB], transferID));
    NSString *path = SZFE2ETransferItem([pair.b dataFor:atB], transferID)[@"file"][@"path"];
    NSString *downloads = pair.helperB.downloadsDirectory.stringByResolvingSymlinksInPath;
    CHECK([path.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath isEqualToString:downloads],
          "in B's Downloads: %@", path);
    CHECK([[NSData dataWithContentsOfFile:path] isEqual:[NSData dataWithContentsOfFile:source]], "same bytes");
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return [SZFE2ETransferItem([pair.a dataFor:atA], transferID)[@"state"] isEqual:@"delivered"];
          }),
          "A sees Delivered: %@", SZFE2ETransferItem([pair.a dataFor:atA], transferID));
    return YES;
}

// Accept files from this friend automatically: the file arrives without B doing anything.
BOOL SZFE2EScenarioAutoAccept(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    NSDictionary *reply = [pair.b intent:@"set_auto_accept"
                                  fields:@{@"conversation_id" : pair.aAtB, @"enabled" : @YES}];
    CHECK([reply[@"ok"] boolValue], "%@", reply);
    NSString *source = [world fileOfSize:200 * 1024 named:@"notes.txt"];
    NSString *transferID = SZFE2ESendFile(pair.a, pair.bAtA, source);
    CHECK(transferID != nil);
    NSString *atB = [pair.b openConversation:pair.aAtB];
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              return [SZFE2ETransferItem([pair.b dataFor:atB], transferID)[@"state"] isEqual:@"received"];
          }),
          "received without asking: %@", SZFE2ETransferItem([pair.b dataFor:atB], transferID));
    NSString *path = SZFE2ETransferItem([pair.b dataFor:atB], transferID)[@"file"][@"path"];
    CHECK([[NSData dataWithContentsOfFile:path] isEqual:[NSData dataWithContentsOfFile:source]], "same bytes");
    return YES;
}

// kill -9 the receiving helper part-way through; after a restart the download continues from the bytes it had
// made durable, and the file still verifies.
BOOL SZFE2EScenarioKillResume(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    // 3 MB/s from A, so 12 MiB takes about four seconds: long enough to kill B in the middle.
    if (!SZFE2EStartPair(world, pair, @{@"SZFRIENDS_E2E_CHUNK_RATE" : @"3000000"}, nil) || !SZFE2EBefriend(pair)) {
        return NO;
    }
    NSString *source = [world fileOfSize:12 * 1024 * 1024 named:@"survey.pdf"];
    NSString *transferID = SZFE2ESendFile(pair.a, pair.bAtA, source);
    NSString *atB = [pair.b openConversation:pair.aAtB];
    CHECK(SZFE2EWaitUntil(15, ^BOOL { return SZFE2ETransferItem([pair.b dataFor:atB], transferID) != nil; }));
    CHECK([[pair.b intent:@"accept_offer" fields:@{@"transfer_id" : transferID}][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              NSDictionary *progress = SZFE2ETransferItem([pair.b dataFor:atB], transferID)[@"progress"];
              return [progress isKindOfClass:[NSDictionary class]] && [progress[@"fraction"] doubleValue] >= 0.35;
          }),
          "receiving: %@", SZFE2ETransferItem([pair.b dataFor:atB], transferID));
    [pair.helperB kill9];
    [pair.b close];
    CHECK([pair.helperB start], "B restarts");
    pair.b = [SZFE2EClient clientForHelper:pair.helperB];
    CHECK(pair.b != nil);
    atB = [pair.b openConversation:pair.aAtB];
    CHECK(SZFE2EWaitUntil(5, ^BOOL { return SZFE2ETransferItem([pair.b dataFor:atB], transferID) != nil; }));
    NSDictionary *after = SZFE2ETransferItem([pair.b dataFor:atB], transferID);
    CHECK([after[@"state"] isEqual:@"receiving"] && [after[@"progress"][@"fraction"] doubleValue] > 0,
          "the durable bytes survived the kill: %@", after);
    CHECK(SZFE2EWaitUntil(40, ^BOOL {
              return [SZFE2ETransferItem([pair.b dataFor:atB], transferID)[@"state"] isEqual:@"received"];
          }),
          "finished after the restart: %@", SZFE2ETransferItem([pair.b dataFor:atB], transferID));
    NSString *path = SZFE2ETransferItem([pair.b dataFor:atB], transferID)[@"file"][@"path"];
    CHECK([[NSData dataWithContentsOfFile:path] isEqual:[NSData dataWithContentsOfFile:source]], "the digest held");
    // The sender continued from B's durable offset rather than from the start.
    CHECK([pair.helperA.log rangeOfString:@" resumes at byte "].location != NSNotFound, "A resumed: %@",
          pair.helperA.log);
    return YES;
}
