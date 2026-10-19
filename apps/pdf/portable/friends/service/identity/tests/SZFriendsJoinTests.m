// friends-identity-check: one profile joined from a new computer (SZFriendsJoin.h). The whole run, then each way it
// must fail: a wrong code, three of them, an expired code, no approval, a device in the middle (two handshake hashes,
// substituted keys, a changed root), and any changed byte on the way.

#import "SZFriendsJoinTestSupport.h"

static NSString *const kID = @"cobalt-otter";

static SZFriendsJoinApprover *ApproverWithRequest(SZFriendsIdentity *root, SZFriendsJoiner *joiner,
                                                  SZFriendsDeviceChain *chain, NSString **code) {
    SZFriendsJoinApprover *approver = [[SZFriendsJoinApprover alloc] initWithIdentity:root];
    SZFriendsJoinReceipt receipt = [approver receiveRequestMessage:[joiner requestMessageAtDate:JoinAt(100)]
                                                      ownFriendsID:kID chain:chain now:JoinAt(101)
                                                       endedReason:NULL];
    SZFExpect(receipt == SZFriendsJoinReceiptAdded, @"request added: %ld", (long)receipt);
    *code = [approver approveRequestID:joiner.requestID now:JoinAt(110)];
    SZFExpect((*code).length == 8, @"a code shows");
    return approver;
}

static void TestJoin(void) {
    SZFriendsIdentity *root = JoinDevice(1), *laptop = JoinDevice(2);
    SZFriendsDeviceChain *chain = JoinGenesis(root);
    SZFriendsJoiner *joiner = JoinJoiner(laptop, kID);
    SZFriendsJoinApprover *approver = [[SZFriendsJoinApprover alloc] initWithIdentity:root];
    [approver receiveRequestMessage:[joiner requestMessageAtDate:JoinAt(100)] ownFriendsID:kID chain:chain
                                now:JoinAt(101) endedReason:NULL];
    NSArray<SZFriendsJoinRequest *> *rows = [approver openRequestsWithChain:chain now:JoinAt(102)];
    SZFExpect(rows.count == 1 && [rows[0].name isEqualToString:@"Mei's MacBook Air"] &&
                  [rows[0].system isEqualToString:@"macOS 26.1"] && rows[0].state == SZFriendsJoinRequestWaiting,
              @"one waiting row naming the computer");
    NSString *code = [approver approveRequestID:joiner.requestID now:JoinAt(110)];
    rows = [approver openRequestsWithChain:chain now:JoinAt(111)];
    SZFExpect(rows[0].state == SZFriendsJoinRequestApproved && [rows[0].code isEqualToString:code] &&
                  [rows[0].codeExpiresAt isEqualToDate:JoinAt(410)], @"the row shows the code for 5 minutes");
    SZFExpect([[approver approveRequestID:joiner.requestID now:JoinAt(112)] isEqualToString:code] &&
                  [[approver openRequestsWithChain:chain now:JoinAt(113)][0].codeExpiresAt isEqualToDate:JoinAt(410)],
              @"approved once: a second press keeps the code and its time");

    // The run, step by step, so the profile and the chain can be read.
    NSData *hash = JoinHash(7);
    SZFriendsJoinAttempt *attempt = [joiner attemptWithCode:code handshakeHash:hash];
    SZFriendsJoinEndReason ended = 0;
    SZFriendsJoinApproval *approval = [approver approvalForCodeMessage:attempt.codeMessage handshakeHash:hash
                                                               rootKey:chain.rootKey now:JoinAt(120) ended:&ended];
    SZFExpect(approval != nil && ended == 0, @"the approving device answers");
    SZFriendsJoinStep *step = [attempt receiveMessage:approval.replyMessage];
    SZFExpect(step.kind == SZFriendsJoinStepSend, @"the reply verifies and the confirm goes");
    SZFriendsJoinWelcome *welcome = [approver welcomeForConfirmMessage:step.message approval:approval chain:chain
                                                               profile:JoinProfileBytes() friendsIDState:2
                                                                   now:JoinAt(121)];
    SZFExpect(welcome != nil && [welcome.chain authorizesDeviceKey:laptop.publicKey], @"the add link is signed");
    SZFExpect([[welcome.chain deviceWithKey:laptop.publicKey].name isEqualToString:@"Mei's MacBook Air"],
              @"the chain names the computer as it asked");
    for (NSData *part in welcome.parts) step = [attempt receiveMessage:part];
    SZFExpect(step.kind == SZFriendsJoinStepJoined, @"joined: %ld", (long)step.kind);
    SZFExpect([step.chain.encodedData isEqualToData:welcome.chain.encodedData], @"the same chain on both sides");
    SZFExpect([step.chain.rootKey isEqualToData:root.publicKey], @"the root learned from the chain");
    SZFExpect([step.profile isEqualToData:JoinProfileBytes()] && step.friendsIDState == 2, @"the profile arrived");
    [approver finishRequestID:joiner.requestID];
    SZFExpect([approver openRequestsWithChain:welcome.chain now:JoinAt(122)].count == 0, @"the row is gone");

    // Another device of the person sees the row go once the chain with the new device reaches it.
    SZFriendsJoinApprover *desktop = [[SZFriendsJoinApprover alloc] initWithIdentity:JoinDevice(3)];
    [desktop receiveRequestMessage:[joiner requestMessageAtDate:JoinAt(100)] ownFriendsID:kID chain:chain
                               now:JoinAt(101) endedReason:NULL];
    SZFExpect([desktop openRequestsWithChain:chain now:JoinAt(130)].count == 1, @"waiting elsewhere");
    SZFExpect([desktop openRequestsWithChain:welcome.chain now:JoinAt(131)].count == 0, @"cleared by the chain");
    SZFExpect([desktop receiveRequestMessage:[joiner requestMessageAtDate:JoinAt(132)] ownFriendsID:kID
                                       chain:welcome.chain now:JoinAt(132)
                                 endedReason:NULL] == SZFriendsJoinReceiptIgnored, @"a member asks no more");

    // A big welcome (a long chain, a whole picture) still arrives in parts.
    SZFriendsJoinApprover *big = [[SZFriendsJoinApprover alloc] initWithIdentity:root];
    SZFriendsJoiner *phone = JoinJoiner(JoinDevice(4), kID);
    [big receiveRequestMessage:[phone requestMessageAtDate:JoinAt(100)] ownFriendsID:kID chain:chain
                           now:JoinAt(100) endedReason:NULL];
    NSString *bigCode = [big approveRequestID:phone.requestID now:JoinAt(100)];
    SZFriendsJoinAttempt *bigAttempt = [phone attemptWithCode:bigCode handshakeHash:hash];
    SZFriendsJoinApproval *bigApproval = [big approvalForCodeMessage:bigAttempt.codeMessage handshakeHash:hash
                                                             rootKey:chain.rootKey now:JoinAt(101) ended:&ended];
    step = [bigAttempt receiveMessage:bigApproval.replyMessage];
    NSData *picture = [NSMutableData dataWithLength:49152];
    welcome = [big welcomeForConfirmMessage:step.message approval:bigApproval chain:chain profile:picture
                             friendsIDState:0 now:JoinAt(102)];
    SZFExpect(welcome.parts.count > 50, @"many parts: %lu", (unsigned long)welcome.parts.count);
    for (NSData *part in welcome.parts) {
        SZFExpect(part.length <= SZFriendsJoinMessageMax, @"each part fits a message");
        step = [bigAttempt receiveMessage:part];
    }
    SZFExpect(step.kind == SZFriendsJoinStepJoined && [step.profile isEqualToData:picture], @"big welcome joined");
}

static void TestWrongAndExpired(void) {
    SZFriendsIdentity *root = JoinDevice(1), *laptop = JoinDevice(2);
    SZFriendsDeviceChain *chain = JoinGenesis(root);
    SZFriendsJoiner *joiner = JoinJoiner(laptop, kID);
    NSString *code = nil;
    SZFriendsJoinApprover *approver = ApproverWithRequest(root, joiner, chain, &code);
    NSString *wrong = [code isEqualToString:@"12345678"] ? @"87654321" : @"12345678";

    // Two wrong codes: each says so on the new computer and costs one attempt; the right one still works.
    for (int i = 0; i < 2; i++) {
        SZFJoinRun run = SZFJoinRunOnce(joiner, approver, chain, wrong, JoinHash(9), JoinHash(9), JoinAt(120 + i),
                                        NULL, nil);
        SZFExpect(run.joiner == SZFriendsJoinStepWrongCode && !run.welcomed, @"wrong code %d", i);
    }
    SZFExpect([approver openRequestsWithChain:chain now:JoinAt(130)][0].attempts == 2, @"two attempts counted");
    SZFriendsDeviceChain *joined = nil;
    NSString *spaced = [NSString stringWithFormat:@"%@ %@", [code substringToIndex:4], [code substringFromIndex:4]];
    SZFJoinRun run = SZFJoinRunOnce(joiner, approver, chain, spaced, JoinHash(9), JoinHash(9), JoinAt(140), &joined,
                                    nil);
    SZFExpect(run.joiner == SZFriendsJoinStepJoined && [joined authorizesDeviceKey:laptop.publicKey],
              @"the third try, right and typed with a space, joins");

    // Three wrong codes end the approval at once; the next try and the next request hear why.
    SZFriendsJoiner *other = JoinJoiner(JoinDevice(5), kID);
    approver = ApproverWithRequest(root, other, chain, &code);
    for (int i = 0; i < 3; i++) {
        SZFJoinRun bad = SZFJoinRunOnce(other, approver, chain, wrong, JoinHash(9), JoinHash(9), JoinAt(120), NULL,
                                        nil);
        SZFExpect(bad.joiner == SZFriendsJoinStepWrongCode, @"wrong %d", i);
    }
    SZFExpect([approver openRequestsWithChain:chain now:JoinAt(121)].count == 0, @"three wrong codes cancel");
    run = SZFJoinRunOnce(other, approver, chain, code, JoinHash(9), JoinHash(9), JoinAt(122), NULL, nil);
    SZFExpect(run.ended == SZFriendsJoinEndTooManyAttempts && run.joiner == SZFriendsJoinStepEnded,
              @"even the right code is refused afterwards: %d", run.ended);
    SZFriendsJoinEndReason reason = 0;
    SZFExpect([approver receiveRequestMessage:[other requestMessageAtDate:JoinAt(123)] ownFriendsID:kID chain:chain
                                          now:JoinAt(123) endedReason:&reason] == SZFriendsJoinReceiptEnded &&
                  reason == SZFriendsJoinEndTooManyAttempts, @"the request stays ended");

    // A code lives 5 minutes from Approve (at 110).
    SZFriendsJoiner *late = JoinJoiner(JoinDevice(6), kID);
    approver = ApproverWithRequest(root, late, chain, &code);
    SZFExpect([approver nextChangeAfter:JoinAt(200)].timeIntervalSince1970 == JoinAt(410).timeIntervalSince1970,
              @"the snapshot refreshes when the code expires");
    run = SZFJoinRunOnce(late, approver, chain, code, JoinHash(9), JoinHash(9), JoinAt(410), NULL, nil);
    SZFExpect(run.ended == SZFriendsJoinEndExpired && run.joiner == SZFriendsJoinStepEnded, @"expired code refused");
    SZFExpect([approver openRequestsWithChain:chain now:JoinAt(411)].count == 0, @"and its row is gone");

    // A confirm that arrives after the code expired is refused too.
    SZFriendsJoiner *slow = JoinJoiner(JoinDevice(7), kID);
    approver = ApproverWithRequest(root, slow, chain, &code);
    SZFriendsJoinAttempt *attempt = [slow attemptWithCode:code handshakeHash:JoinHash(9)];
    SZFriendsJoinEndReason ended = 0;
    SZFriendsJoinApproval *approval = [approver approvalForCodeMessage:attempt.codeMessage handshakeHash:JoinHash(9)
                                                               rootKey:chain.rootKey now:JoinAt(400) ended:&ended];
    SZFriendsJoinStep *step = [attempt receiveMessage:approval.replyMessage];
    SZFExpect([approver welcomeForConfirmMessage:step.message approval:approval chain:chain profile:JoinProfileBytes()
                                  friendsIDState:0 now:JoinAt(411)] == nil, @"a late confirm adds nobody");
}

static void TestNoApproval(void) {
    SZFriendsIdentity *root = JoinDevice(1);
    SZFriendsDeviceChain *chain = JoinGenesis(root);
    SZFriendsJoiner *joiner = JoinJoiner(JoinDevice(2), kID);
    SZFriendsJoinApprover *approver = [[SZFriendsJoinApprover alloc] initWithIdentity:root];
    [approver receiveRequestMessage:[joiner requestMessageAtDate:JoinAt(100)] ownFriendsID:kID chain:chain
                                now:JoinAt(100) endedReason:NULL];
    // Every possible code against a request nobody approved: no answer, as from a device that holds nothing.
    for (NSString *guess in @[ @"00000000", @"12345678", @"99999999" ]) {
        SZFJoinRun run = SZFJoinRunOnce(joiner, approver, chain, guess, JoinHash(1), JoinHash(1), JoinAt(101), NULL,
                                        nil);
        SZFExpect(run.ended == 0 && run.joiner == 0 && !run.welcomed, @"never approved by itself");
    }
    SZFExpect([approver openRequestsWithChain:chain now:JoinAt(102)][0].state == SZFriendsJoinRequestWaiting,
              @"still waiting for the person");
    SZFExpect([joiner attemptWithCode:@"1234567" handshakeHash:JoinHash(1)] == nil, @"seven digits are no code");
    SZFExpect([joiner attemptWithCode:@"12345678" handshakeHash:JoinHash(1)] != nil, @"eight are");
}

// A device in the middle of the new computer and the approving one.
static void TestMiddle(void) {
    SZFriendsIdentity *root = JoinDevice(1), *laptop = JoinDevice(2), *mallory = JoinDevice(66);
    SZFriendsDeviceChain *chain = JoinGenesis(root);
    SZFriendsJoiner *joiner = JoinJoiner(laptop, kID);
    NSString *code = nil;
    SZFriendsJoinApprover *approver = ApproverWithRequest(root, joiner, chain, &code);

    // Two sessions, one with each side, relaying every message: the hashes differ, so the keys do.
    SZFJoinRun run = SZFJoinRunOnce(joiner, approver, chain, code, JoinHash(1), JoinHash(2), JoinAt(120), NULL, nil);
    SZFExpect(run.joiner == SZFriendsJoinStepWrongCode && !run.welcomed, @"relaying between two sessions fails");

    // Rewriting the reply's root key (to put the laptop in another profile) breaks its tag.
    run = SZFJoinRunOnce(joiner, approver, chain, code, JoinHash(1), JoinHash(1), JoinAt(121), NULL,
                         ^NSData *(NSUInteger index, NSData *message) {
                             if (index != 1) return message;
                             NSMutableDictionary *fields = [SZFriendsJoinDecode(message, SZFriendsJoinMessageReply)
                                 mutableCopy];
                             fields[@(SZFriendsJoinTagRootKey)] = mallory.publicKey;
                             return SZFriendsJoinEncode(SZFriendsJoinMessageReply, fields);
                         });
    SZFExpect(run.joiner == SZFriendsJoinStepWrongCode, @"a substituted root is refused");

    // A request rewritten with the middle device's keys under the laptop's request id: the person approves what they
    // see, the laptop's run binds its own keys, and nothing verifies.
    SZFriendsJoiner *forged = [[SZFriendsJoiner alloc] initWithIdentity:mallory friendsID:kID name:@"Mei's MacBook Air"
                                                                 system:@"macOS 26.1" requestID:joiner.requestID];
    SZFriendsJoinApprover *fooled = [[SZFriendsJoinApprover alloc] initWithIdentity:root];
    [fooled receiveRequestMessage:[forged requestMessageAtDate:JoinAt(100)] ownFriendsID:kID chain:chain
                              now:JoinAt(100) endedReason:NULL];
    SZFExpect([fooled receiveRequestMessage:[joiner requestMessageAtDate:JoinAt(100)] ownFriendsID:kID chain:chain
                                        now:JoinAt(100) endedReason:NULL] == SZFriendsJoinReceiptIgnored,
              @"the real request with the same id changes nothing");
    NSString *shown = [fooled approveRequestID:joiner.requestID now:JoinAt(110)];
    run = SZFJoinRunOnce(joiner, fooled, chain, shown, JoinHash(1), JoinHash(1), JoinAt(120), NULL, nil);
    SZFExpect(run.joiner == SZFriendsJoinStepWrongCode && !run.welcomed, @"the laptop does not join through it");
    // And the middle device, not knowing the code, guesses: one attempt each, and a confirm without ISK fails.
    run = SZFJoinRunOnce(forged, fooled, chain, @"00000000", JoinHash(1), JoinHash(1), JoinAt(121), NULL, nil);
    SZFExpect(run.joiner == SZFriendsJoinStepWrongCode, @"a guess fails");
    SZFriendsJoinAttempt *attempt = [forged attemptWithCode:@"00000000" handshakeHash:JoinHash(1)];
    SZFriendsJoinEndReason ended = 0;
    SZFriendsJoinApproval *approval = [fooled approvalForCodeMessage:attempt.codeMessage handshakeHash:JoinHash(1)
                                                             rootKey:chain.rootKey now:JoinAt(122) ended:&ended];
    NSData *consent = SZFriendsDeviceConsent(mallory, chain.rootKey);
    NSData *confirm = SZFriendsJoinEncode(SZFriendsJoinMessageConfirm, @{
        @(SZFriendsJoinTagConsent) : consent,
        @(SZFriendsJoinTagTag) : [NSMutableData dataWithLength:32],
    });
    SZFExpect([fooled welcomeForConfirmMessage:confirm approval:approval chain:chain profile:JoinProfileBytes()
                                friendsIDState:0 now:JoinAt(123)] == nil, @"a confirm without the key adds nobody");
    SZFExpect([fooled openRequestsWithChain:chain now:JoinAt(124)].count == 0, @"three tries spent the approval");
}

// Any byte changed on the way, in any message, fails the run and adds nobody, or still joins with every byte intact.
static void TestTampering(void) {
    SZFriendsIdentity *root = JoinDevice(1), *laptop = JoinDevice(2);
    SZFriendsDeviceChain *chain = JoinGenesis(root);
    for (NSUInteger target = 0; target < 5; target++) {
        for (NSUInteger offset = 2; offset < 120; offset += 13) {
            SZFriendsJoiner *joiner = JoinJoiner(laptop, kID);
            NSString *code = nil;
            SZFriendsJoinApprover *approver = ApproverWithRequest(root, joiner, chain, &code);
            __block BOOL changed = NO;
            SZFriendsDeviceChain *joined = nil;
            SZFJoinRun run = SZFJoinRunOnce(joiner, approver, chain, code, JoinHash(3), JoinHash(3), JoinAt(120),
                                            &joined, ^NSData *(NSUInteger index, NSData *message) {
                                                if (index != target || offset >= message.length) return message;
                                                NSMutableData *copy = [message mutableCopy];
                                                ((uint8_t *)copy.mutableBytes)[offset] ^= 0x20;
                                                changed = YES;
                                                return copy;
                                            });
            if (!changed) continue;
            SZFExpect(run.joiner != SZFriendsJoinStepJoined, @"message %lu byte %lu changed, yet joined",
                      (unsigned long)target, (unsigned long)offset);
        }
    }
}

int main(void) {
    @autoreleasepool {
        TestJoin();
        TestWrongAndExpired();
        TestNoApproval();
        TestMiddle();
        TestTampering();
        return SZFFinish("SZFriendsJoinTests");
    }
}
