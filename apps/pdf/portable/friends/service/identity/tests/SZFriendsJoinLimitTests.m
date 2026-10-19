// friends-identity-check: what a stranger can make the person's computers show with join requests (SZFriendsJoin.h):
// only signed requests for this Friends ID, from a sane clock, from devices the profile does not hold; at most three
// rows and six new ones an hour (a request taking a waiting row's place adds none); one row per device; Approve pressed
// twice keeps its code; Deny final for that request and that device for half an hour.
// Then the code format and the strictness of the messages.

#import "SZFriendsJoinTestSupport.h"

static NSString *const kID = @"cobalt-otter";

static SZFriendsJoinReceipt Receive(SZFriendsJoinApprover *approver, SZFriendsJoiner *joiner,
                                    SZFriendsDeviceChain *chain, double sentAt, double now,
                                    SZFriendsJoinEndReason *reason) {
    return [approver receiveRequestMessage:[joiner requestMessageAtDate:JoinAt(sentAt)] ownFriendsID:kID chain:chain
                                       now:JoinAt(now) endedReason:reason];
}

static void TestWhatIsShown(void) {
    SZFriendsIdentity *root = JoinDevice(1);
    SZFriendsDeviceChain *chain = JoinGenesis(root);
    SZFriendsJoinApprover *approver = [[SZFriendsJoinApprover alloc] initWithIdentity:root];
    SZFriendsJoiner *joiner = JoinJoiner(JoinDevice(2), kID);

    SZFExpect([approver receiveRequestMessage:[joiner requestMessageAtDate:JoinAt(0)] ownFriendsID:@"other-id"
                                        chain:chain now:JoinAt(0) endedReason:NULL] == SZFriendsJoinReceiptIgnored,
              @"another ID is not ours");
    SZFExpect([approver receiveRequestMessage:[joiner requestMessageAtDate:JoinAt(0)] ownFriendsID:nil chain:chain
                                          now:JoinAt(0) endedReason:NULL] == SZFriendsJoinReceiptIgnored,
              @"no ID yet");
    SZFExpect(Receive(approver, joiner, chain, 0, 601, NULL) == SZFriendsJoinReceiptIgnored, @"10 minutes late");
    SZFExpect(Receive(approver, joiner, chain, 601, 0, NULL) == SZFriendsJoinReceiptIgnored, @"from the future");
    SZFExpect(Receive(approver, JoinJoiner(root, kID), chain, 0, 0, NULL) == SZFriendsJoinReceiptIgnored,
              @"our own key");
    // Every single changed byte breaks the signature or the format.
    NSData *message = [joiner requestMessageAtDate:JoinAt(0)];
    for (NSUInteger i = 0; i < message.length; i++) {
        NSMutableData *copy = [message mutableCopy];
        ((uint8_t *)copy.mutableBytes)[i] ^= 0x01;
        SZFExpect([approver receiveRequestMessage:copy ownFriendsID:kID chain:chain now:JoinAt(0)
                                      endedReason:NULL] == SZFriendsJoinReceiptIgnored, @"byte %lu", (unsigned long)i);
    }
    SZFExpect([approver openRequestsWithChain:chain now:JoinAt(1)].count == 0, @"nothing shows");

    SZFExpect(Receive(approver, joiner, chain, 0, 0, NULL) == SZFriendsJoinReceiptAdded, @"a signed request shows");
    SZFExpect(Receive(approver, joiner, chain, 60, 60, NULL) == SZFriendsJoinReceiptRefreshed, @"a copy refreshes");
    // A waiting row lives 30 minutes after the last copy.
    SZFExpect([approver openRequestsWithChain:chain now:JoinAt(1859)].count == 1, @"still there");
    SZFExpect([approver openRequestsWithChain:chain now:JoinAt(1860)].count == 0, @"gone after 30 minutes");

    // A device the profile holds, or ever removed, is never shown.
    SZFriendsIdentity *old = JoinDevice(3);
    SZFriendsDeviceChain *added = [chain chainByAddingDeviceKey:old.publicKey staticKey:old.staticPublicKey
                                                        consent:SZFriendsDeviceConsent(old, chain.rootKey)
                                                           name:@"Old Mac" system:@"macOS 15.0" signedBy:root
                                                           date:JoinAt(1) error:NULL];
    SZFriendsDeviceChain *revoked = [added chainByRevokingDeviceKey:old.publicKey signedBy:root date:JoinAt(2)
                                                              error:NULL];
    SZFExpect(Receive(approver, JoinJoiner(old, kID), added, 3000, 3000, NULL) == SZFriendsJoinReceiptIgnored,
              @"a member");
    SZFExpect(Receive(approver, JoinJoiner(old, kID), revoked, 3000, 3000, NULL) == SZFriendsJoinReceiptIgnored,
              @"a removed device asks in vain");
}

static void TestSpam(void) {
    SZFriendsIdentity *root = JoinDevice(1);
    SZFriendsDeviceChain *chain = JoinGenesis(root);
    SZFriendsJoinApprover *approver = [[SZFriendsJoinApprover alloc] initWithIdentity:root];
    // Three rows at most: the newest takes the place of the oldest still waiting, so requests nobody wants never keep
    // the person's own new computer off the list.
    NSMutableArray<SZFriendsJoiner *> *joiners = [NSMutableArray array];
    for (uint8_t i = 0; i < 3; i++) {
        [joiners addObject:JoinJoiner(JoinDevice(10 + i), kID)];
        SZFExpect(Receive(approver, joiners[i], chain, i, i, NULL) == SZFriendsJoinReceiptAdded, @"row %d", i);
    }
    SZFriendsJoiner *fourth = JoinJoiner(JoinDevice(13), kID);
    SZFExpect(Receive(approver, fourth, chain, 3, 3, NULL) == SZFriendsJoinReceiptAdded, @"the newest shows");
    NSArray<SZFriendsJoinRequest *> *rows = [approver openRequestsWithChain:chain now:JoinAt(4)];
    SZFExpect(rows.count == 3 && ![[rows valueForKey:@"requestID"] containsObject:joiners[0].requestID] &&
                  [[rows valueForKey:@"requestID"] containsObject:fourth.requestID],
              @"in place of the oldest");
    // An approval in progress keeps its place: with every row approved, a newcomer waits.
    for (SZFriendsJoinRequest *row in rows) [approver approveRequestID:row.requestID now:JoinAt(5)];
    SZFExpect(Receive(approver, JoinJoiner(JoinDevice(14), kID), chain, 6, 6, NULL) == SZFriendsJoinReceiptLimited,
              @"approved rows stay");
    // One device starting over replaces its own row, whatever its new request id.
    SZFriendsJoinApprover *again = [[SZFriendsJoinApprover alloc] initWithIdentity:root];
    Receive(again, JoinJoiner(JoinDevice(10), kID), chain, 0, 0, NULL);
    SZFExpect(Receive(again, JoinJoiner(JoinDevice(10), kID), chain, 10, 10, NULL) == SZFriendsJoinReceiptAdded,
              @"a new request from the same device");
    SZFExpect([again openRequestsWithChain:chain now:JoinAt(11)].count == 1, @"still one row");

    // Six new rows an hour: rows that came and went (codes left to expire) use them up; one the person denied gives
    // its slot back.
    SZFriendsJoinApprover *fresh = [[SZFriendsJoinApprover alloc] initWithIdentity:root];
    SZFriendsJoiner *last = nil;
    for (uint8_t i = 0; i < 6; i++) {
        last = JoinJoiner(JoinDevice(20 + i), kID);
        double at = i < 3 ? i : 400 + i;
        SZFExpect(Receive(fresh, last, chain, at, at, NULL) == SZFriendsJoinReceiptAdded, @"new row %d", i);
        if (i != 2 && i != 5) continue;
        for (SZFriendsJoinRequest *row in [fresh openRequestsWithChain:chain now:JoinAt(at)]) {
            if (i == 2 || ![row.requestID isEqualToData:last.requestID]) {
                [fresh approveRequestID:row.requestID now:JoinAt(at)];
            }
        }
    }
    SZFExpect([fresh openRequestsWithChain:chain now:JoinAt(710)].count == 1, @"the codes expired, one row waits");
    SZFExpect(Receive(fresh, JoinJoiner(JoinDevice(30), kID), chain, 710, 710, NULL) == SZFriendsJoinReceiptLimited,
              @"a seventh new row within the hour");
    SZFExpect([fresh denyRequestID:last.requestID now:JoinAt(711)], @"Deny");
    SZFExpect(Receive(fresh, JoinJoiner(JoinDevice(30), kID), chain, 712, 712, NULL) == SZFriendsJoinReceiptAdded,
              @"then it shows");
    SZFExpect(Receive(fresh, JoinJoiner(JoinDevice(31), kID), chain, 713, 713, NULL) == SZFriendsJoinReceiptLimited,
              @"the hour is full again");
    SZFExpect(Receive(fresh, JoinJoiner(JoinDevice(31), kID), chain, 3601, 3601, NULL) == SZFriendsJoinReceiptAdded,
              @"an hour later");

    // Spam first, then the person's own computer: six requests nobody wants, each taking the place of the waiting row
    // repeated least recently once three show, never use up the hour, and the person's request shows.
    SZFriendsJoinApprover *spammed = [[SZFriendsJoinApprover alloc] initWithIdentity:root];
    for (uint8_t i = 0; i < 6; i++) {
        SZFExpect(Receive(spammed, JoinJoiner(JoinDevice(60 + i), kID), chain, i, i, NULL) ==
                      SZFriendsJoinReceiptAdded,
                  @"spam %d shows for now", i);
    }
    SZFriendsJoiner *own = JoinJoiner(JoinDevice(70), kID);
    SZFExpect(Receive(spammed, own, chain, 10, 10, NULL) == SZFriendsJoinReceiptAdded, @"the person's request shows");
    // Its computer repeats it; more spam takes the places of rows sent once before the repeated one's.
    SZFExpect(Receive(spammed, own, chain, 20, 20, NULL) == SZFriendsJoinReceiptRefreshed, @"repeated");
    for (uint8_t i = 0; i < 2; i++) Receive(spammed, JoinJoiner(JoinDevice(80 + i), kID), chain, 30 + i, 30 + i, NULL);
    NSArray<SZFriendsJoinRequest *> *shown = [spammed openRequestsWithChain:chain now:JoinAt(32)];
    SZFExpect(shown.count == 3 && [[shown valueForKey:@"requestID"] containsObject:own.requestID],
              @"the repeated request stays: %lu rows", (unsigned long)shown.count);
    // Pushed out at last, it comes back with its next repeat, which takes the stalest place in turn.
    Receive(spammed, JoinJoiner(JoinDevice(82), kID), chain, 33, 33, NULL);
    SZFExpect(![[[spammed openRequestsWithChain:chain now:JoinAt(34)] valueForKey:@"requestID"]
                  containsObject:own.requestID],
              @"pushed out");
    SZFExpect(Receive(spammed, own, chain, 40, 40, NULL) == SZFriendsJoinReceiptAdded, @"the next repeat shows again");
    // Approve pressed twice (a double click, or two views) keeps the code it showed.
    NSString *code = [spammed approveRequestID:own.requestID now:JoinAt(41)];
    SZFExpect(code.length == 8 && [[spammed approveRequestID:own.requestID now:JoinAt(42)] isEqualToString:code],
              @"the same code on a second press");

    // A row another computer of the person dealt with (the device is in the chain now) gives its slot back too.
    SZFriendsJoinApprover *cleared = [[SZFriendsJoinApprover alloc] initWithIdentity:root];
    SZFriendsIdentity *added = nil;
    for (uint8_t i = 0; i < 6; i++) {
        added = JoinDevice(40 + i);
        Receive(cleared, JoinJoiner(added, kID), chain, i, i, NULL);
    }
    SZFriendsDeviceChain *grown = [chain chainByAddingDeviceKey:added.publicKey staticKey:added.staticPublicKey
                                                        consent:SZFriendsDeviceConsent(added, chain.rootKey)
                                                           name:@"New Mac" system:@"macOS 26.1" signedBy:root
                                                           date:JoinAt(7) error:NULL];
    SZFExpect([cleared openRequestsWithChain:grown now:JoinAt(8)].count == 2, @"its row goes");
    SZFExpect(Receive(cleared, JoinJoiner(JoinDevice(50), kID), grown, 9, 9, NULL) == SZFriendsJoinReceiptAdded,
              @"and its slot is free");
}

static void TestDeny(void) {
    SZFriendsIdentity *root = JoinDevice(1), *laptop = JoinDevice(2);
    SZFriendsDeviceChain *chain = JoinGenesis(root);
    SZFriendsJoinApprover *approver = [[SZFriendsJoinApprover alloc] initWithIdentity:root];
    SZFriendsJoiner *joiner = JoinJoiner(laptop, kID);
    Receive(approver, joiner, chain, 0, 0, NULL);
    SZFExpect([approver denyRequestID:joiner.requestID now:JoinAt(5)], @"denied");
    SZFExpect([approver approveRequestID:joiner.requestID now:JoinAt(6)] == nil, @"Deny is final");
    SZFriendsJoinEndReason reason = 0;
    SZFExpect(Receive(approver, joiner, chain, 10, 10, &reason) == SZFriendsJoinReceiptEnded &&
                  reason == SZFriendsJoinEndDenied, @"the same request hears it was denied");
    SZFExpect(Receive(approver, JoinJoiner(laptop, kID), chain, 20, 20, &reason) == SZFriendsJoinReceiptEnded,
              @"and the same device for a while");
    SZFExpect([approver openRequestsWithChain:chain now:JoinAt(21)].count == 0, @"no row comes back");
    // A run on a denied request hears so.
    SZFJoinRun run = SZFJoinRunOnce(joiner, approver, chain, @"12345678", JoinHash(1), JoinHash(1), JoinAt(30), NULL,
                                    nil);
    SZFExpect(run.ended == SZFriendsJoinEndDenied && run.joiner == SZFriendsJoinStepEnded, @"denied run");
    SZFExpect(Receive(approver, JoinJoiner(laptop, kID), chain, 1806, 1806, &reason) == SZFriendsJoinReceiptAdded,
              @"half an hour later it may ask again");
    // Approve then Deny withdraws the code.
    SZFriendsJoiner *second = JoinJoiner(JoinDevice(8), kID);
    Receive(approver, second, chain, 1900, 1900, NULL);
    NSString *code = [approver approveRequestID:second.requestID now:JoinAt(1901)];
    [approver denyRequestID:second.requestID now:JoinAt(1902)];
    run = SZFJoinRunOnce(second, approver, chain, code, JoinHash(1), JoinHash(1), JoinAt(1903), NULL, nil);
    SZFExpect(run.ended == SZFriendsJoinEndDenied && !run.welcomed, @"a withdrawn code adds nobody");
    // Reset Friends forgets everything.
    [approver forgetEverything];
    SZFExpect(Receive(approver, second, chain, 1904, 1904, NULL) == SZFriendsJoinReceiptAdded, @"after a reset");
}

static void TestCodesAndMessages(void) {
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (int i = 0; i < 200; i++) {
        NSString *code = SZFriendsJoinNewCode();
        SZFExpect(code.length == 8 && SZFriendsJoinNormalizedCode(code) != nil, @"8 digits: %@", code);
        [seen addObject:code];
    }
    SZFExpect(seen.count > 195, @"codes are fresh");
    SZFExpect([SZFriendsJoinNormalizedCode(@"4831 2207") isEqualToString:@"48312207"], @"a space");
    SZFExpect([SZFriendsJoinNormalizedCode(@" 4831-2207 ") isEqualToString:@"48312207"], @"a dash");
    SZFExpect([SZFriendsJoinNormalizedCode(@"４８３１２２０７")
                  isEqualToString:@"48312207"], @"full-width digits");
    for (NSString *bad in @[ @"", @"4831220", @"483122070", @"4831a207", @"4831٢207", @"48312207\n" ]) {
        SZFExpect(SZFriendsJoinNormalizedCode(bad) == nil, @"refused: %@", bad);
    }
    // Messages: strict about kind, order, lengths and size.
    NSData *ended = SZFriendsJoinEndedMessage(SZFriendsJoinEndExpired);
    SZFExpect(SZFriendsJoinMessageKindOf(ended) == SZFriendsJoinMessageEnded &&
                  SZFriendsJoinEndReasonOf(ended) == SZFriendsJoinEndExpired, @"ended round trip");
    SZFExpect(SZFriendsJoinDecode(ended, SZFriendsJoinMessageCode) == nil, @"another kind");
    NSMutableData *trailing = [ended mutableCopy];
    [trailing appendBytes:"\x00" length:1];
    SZFExpect(SZFriendsJoinDecode(trailing, SZFriendsJoinMessageEnded) == nil, @"trailing bytes");
    SZFExpect(SZFriendsJoinEncode(SZFriendsJoinMessageEnded, @{@(SZFriendsJoinTagShare) : JoinHash(1)}) == nil,
              @"a field the kind does not take");
    NSData *code = SZFriendsJoinEncode(SZFriendsJoinMessageCode, @{
        @(SZFriendsJoinTagRequestID) : [NSMutableData dataWithLength:16],
        @(SZFriendsJoinTagShare) : [NSMutableData dataWithLength:32],
    });
    NSMutableData *swapped = [NSMutableData dataWithBytes:code.bytes length:2];
    [swapped appendData:[code subdataWithRange:NSMakeRange(2 + 3 + 16, 3 + 32)]];
    [swapped appendData:[code subdataWithRange:NSMakeRange(2, 3 + 16)]];
    SZFExpect(SZFriendsJoinDecode(code, SZFriendsJoinMessageCode) != nil, @"in order");
    SZFExpect(SZFriendsJoinDecode(swapped, SZFriendsJoinMessageCode) == nil, @"out of order");
    SZFExpect(SZFriendsJoinRequestMessage(JoinDevice(2), [NSMutableData dataWithLength:16], kID,
                                          @"Mei\nMacBook", @"macOS", JoinAt(0)) == nil, @"a control character");
    SZFExpect(SZFriendsJoinRequestMessage(JoinDevice(2), [NSMutableData dataWithLength:16], kID,
                                          [@"" stringByPaddingToLength:65 withString:@"a" startingAtIndex:0],
                                          @"macOS", JoinAt(0)) == nil, @"a name over 64 bytes");
}

int main(void) {
    @autoreleasepool {
        TestWhatIsShown();
        TestSpam();
        TestDeny();
        TestCodesAndMessages();
        return SZFFinish("SZFriendsJoinLimitTests");
    }
}
