// Pure transfer rules: state machine, sanitizer, destinations, offer validation, automatic acceptance decision.

#import <unistd.h>

#import "SZFriendsStoreTestSupport.h"

static const SZFriendsTransferState Qd = SZFriendsTransferStateQueued, Of = SZFriendsTransferStateOffered,
                                    Wt = SZFriendsTransferStateWaitingForYou, Sn = SZFriendsTransferStateSending,
                                    Rc = SZFriendsTransferStateReceiving, Dl = SZFriendsTransferStateDelivered,
                                    Rd = SZFriendsTransferStateReceived, Dc = SZFriendsTransferStateDeclined,
                                    Cn = SZFriendsTransferStateCancelled, Fl = SZFriendsTransferStateFailed;

static void TestTransferStateMachineExhaustively(void) {
    // Columns: OfferDelivered, Accepted, Declined, Cancelled, Verified, Failed, Retry. Rows: every state, so states
    // of the other direction are checked to stay put too.
    const SZFriendsTransferState outgoing[10][7] = {
        {Of, Sn, Dc, Cn, Qd, Fl, Qd}, // Queued
        {Of, Sn, Dc, Cn, Of, Fl, Of}, // Offered
        {Wt, Wt, Wt, Wt, Wt, Wt, Wt}, // WaitingForYou (incoming only)
        {Sn, Sn, Sn, Cn, Dl, Fl, Sn}, // Sending
        {Rc, Rc, Rc, Rc, Rc, Rc, Rc}, // Receiving (incoming only)
        {Dl, Dl, Dl, Dl, Dl, Dl, Dl}, // Delivered: what arrived cannot be retracted
        {Rd, Rd, Rd, Rd, Rd, Rd, Rd}, // Received
        {Dc, Dc, Dc, Dc, Dc, Dc, Dc}, // Declined: a late acceptance is ignored
        {Cn, Cn, Cn, Cn, Cn, Cn, Cn}, // Cancelled
        {Fl, Fl, Fl, Fl, Fl, Fl, Qd}, // Failed
    };
    const SZFriendsTransferState incoming[10][7] = {
        {Qd, Qd, Qd, Qd, Qd, Qd, Qd},
        {Of, Of, Of, Of, Of, Of, Of},
        {Wt, Rc, Dc, Cn, Wt, Wt, Wt}, // an unaccepted offer cannot fail; the sender cancels it
        {Sn, Sn, Sn, Sn, Sn, Sn, Sn},
        {Rc, Rc, Rc, Cn, Rd, Fl, Rc},
        {Dl, Dl, Dl, Dl, Dl, Dl, Dl},
        {Rd, Rd, Rd, Rd, Rd, Rd, Rd},
        {Dc, Dc, Dc, Dc, Dc, Dc, Dc},
        {Cn, Cn, Cn, Cn, Cn, Cn, Cn},
        {Fl, Fl, Fl, Fl, Fl, Fl, Rc}, // Try again resumes receiving
    };
    for (int state = 0; state < 10; state++) {
        for (int event = 0; event < 7; event++) {
            SZFriendsTransferState out = SZFriendsTransferNextState(YES, state, event);
            SZFriendsTransferState in = SZFriendsTransferNextState(NO, state, event);
            SZFTExpect(out == outgoing[state][event], @"outgoing state %d event %d gave %ld", state, event, (long)out);
            SZFTExpect(in == incoming[state][event], @"incoming state %d event %d gave %ld", state, event, (long)in);
        }
    }
}

static void TestSanitizer(void) {
    NSString *rlo = [NSString stringWithFormat:@"invoice%Cfdp.exe", (unichar)0x202E];
    NSString *nfd = @"Re\u0301sume\u0301.pdf";
    NSString *nul = [NSString stringWithFormat:@"a%Cb.pdf", (unichar)0];
    NSString *longBase = [@"" stringByPaddingToLength:300 withString:@"a" startingAtIndex:0];
    NSString *longChinese = [@"" stringByPaddingToLength:120 withString:@"合同" startingAtIndex:0];
    NSDictionary<NSString *, NSString *> *cases = @{
        @"Site photos.pdf" : @"Site photos.pdf",
        @"../../.ssh/authorized_keys" : @"-..-.ssh-authorized_keys",
        @"/etc/passwd" : @"-etc-passwd",
        @".." : @"Untitled",
        @"." : @"Untitled",
        @"" : @"Untitled",
        @"   " : @"Untitled",
        @".hidden" : @"hidden",
        @"...secret.txt" : @"secret.txt",
        rlo : @"invoicefdp.exe",
        nul : @"ab.pdf",
        @"line\nbreak.txt" : @"linebreak.txt",
        @"tab\there.txt" : @"tabhere.txt",
        @"  spaced  .pdf  " : @"spaced  .pdf",
        @"C:\\Windows\\evil.dll" : @"C--Windows-evil.dll",
        @"Report: final.pdf" : @"Report- final.pdf",
        @"zero\u200Bwidth\uFEFF.pdf" : @"zerowidth.pdf",
        nfd : @"R\u00E9sum\u00E9.pdf",
        @"合同.pdf" : @"合同.pdf",
        @"👨‍👩‍👧 family.jpg" : @"👨‍👩‍👧 family.jpg",
    };
    for (NSString *input in cases) {
        NSString *output = SZFriendsSanitizedFileName(input);
        SZFTExpect([output isEqualToString:cases[input]], @"\"%@\" gave \"%@\", want \"%@\"", input, output,
                   cases[input]);
        SZFTExpect([SZFriendsSanitizedFileName(output) isEqualToString:output], @"idempotent for \"%@\"", input);
    }
    NSString *capped = SZFriendsSanitizedFileName([longBase stringByAppendingString:@".pdf"]);
    SZFTExpect([capped hasSuffix:@".pdf"] && [capped lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 200,
               @"long names keep their extension: %lu", (unsigned long)capped.length);
    NSString *chinese = SZFriendsSanitizedFileName([longChinese stringByAppendingString:@".docx"]);
    SZFTExpect([chinese hasSuffix:@".docx"] && [chinese lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 200 &&
                   [chinese canBeConvertedToEncoding:NSUTF8StringEncoding], @"long Chinese names are cut cleanly");
    SZFTExpect(![SZFriendsSanitizedFileName(@"a/b/c") containsString:@"/"], @"no separator survives");
}

static void TestUniqueDestination(void) {
    NSString *directory = SZFTTemporaryDirectory(@"destinations");
    NSFileManager *files = NSFileManager.defaultManager;
    SZFTExpect([SZFriendsUniqueDestination(directory, @"Plan.pdf")
                   isEqualToString:[directory stringByAppendingPathComponent:@"Plan.pdf"]], @"free name");
    [[NSData data] writeToFile:[directory stringByAppendingPathComponent:@"Plan.pdf"] atomically:NO];
    [[NSData data] writeToFile:[directory stringByAppendingPathComponent:@"Plan (2).pdf"] atomically:NO];
    SZFTExpect([SZFriendsUniqueDestination(directory, @"Plan.pdf").lastPathComponent isEqualToString:@"Plan (3).pdf"],
               @"never overwrites");
    NSString *outside = [SZFTTemporaryDirectory(@"outside") stringByAppendingPathComponent:@"target"];
    symlink(outside.fileSystemRepresentation, [directory
        stringByAppendingPathComponent:@"report.pdf"].fileSystemRepresentation);
    SZFTExpect([SZFriendsUniqueDestination(directory, @"report.pdf").lastPathComponent
                   isEqualToString:@"report (2).pdf"], @"a dangling symlink counts as taken");
    SZFTExpect(![files fileExistsAtPath:outside], @"and is not followed");
    [files createDirectoryAtPath:[directory stringByAppendingPathComponent:@"README"] withIntermediateDirectories:NO
                      attributes:nil error:NULL];
    SZFTExpect([SZFriendsUniqueDestination(directory, @"README").lastPathComponent isEqualToString:@"README (2)"],
               @"no extension");
    NSString *escape = SZFriendsUniqueDestination(directory, @"../../escape.pdf");
    SZFTExpect([escape.stringByDeletingLastPathComponent isEqualToString:directory], @"stays inside: %@", escape);
}

static void TestOfferValidation(void) {
    NSData *digest = SZFTBytes(1, 32);
    NSString *reason = nil;
    SZFTExpect(SZFriendsValidateOffer(@"Plan.pdf", 1024, digest, 0, &reason) && !reason, @"a normal offer");
    SZFTExpect(SZFriendsValidateOffer(@"empty.txt", 0, digest, 0, NULL), @"empty files can be sent");
    SZFTExpect(!SZFriendsValidateOffer(@"", 1, digest, 0, &reason) && reason, @"empty name");
    NSString *huge = [@"" stringByPaddingToLength:1025 withString:@"x" startingAtIndex:0];
    SZFTExpect(!SZFriendsValidateOffer(huge, 1, digest, 0, NULL), @"oversized name");
    SZFTExpect(!SZFriendsValidateOffer(@"a", SZFriendsTransferMaxFileSize + 1, digest, 0, NULL), @"oversized size");
    SZFTExpect(SZFriendsValidateOffer(@"a", SZFriendsTransferMaxFileSize, digest, 0, NULL), @"largest size");
    SZFTExpect(!SZFriendsValidateOffer(@"a", 1, SZFTBytes(1, 31), 0, NULL), @"short digest");
    SZFTExpect(!SZFriendsValidateOffer(@"a", 1, digest, SZFriendsTransferMaxPendingOffers, NULL), @"flood");
    SZFTExpect(SZFriendsValidateOffer(@"a", 1, digest, SZFriendsTransferMaxPendingOffers - 1, NULL), @"just under");
}

static void TestAutomaticAcceptanceDecision(void) {
    const uint64_t GiB = 1ULL << 30;
    SZFTExpect(SZFriendsAutoAcceptDecide(NO, NO, NO, 10, 100 * GiB, GiB) == SZFriendsAutoAcceptAsk, @"off by default");
    SZFTExpect(SZFriendsAutoAcceptDecide(YES, NO, NO, 10, 100 * GiB, GiB) == SZFriendsAutoAcceptDownload, @"on");
    SZFTExpect(SZFriendsAutoAcceptDecide(YES, YES, NO, 10, 100 * GiB, GiB) == SZFriendsAutoAcceptAsk, @"key change");
    SZFTExpect(SZFriendsAutoAcceptDecide(YES, NO, YES, 10, 100 * GiB, GiB) == SZFriendsAutoAcceptAsk, @"blocked");
    SZFTExpect(SZFriendsAutoAcceptDecide(YES, NO, NO, 2 * GiB, 3 * GiB, GiB) == SZFriendsAutoAcceptDownload,
               @"exactly the reserve left");
    SZFTExpect(SZFriendsAutoAcceptDecide(YES, NO, NO, 2 * GiB + 1, 3 * GiB, GiB) == SZFriendsAutoAcceptAskLowDisk,
               @"one byte short");
    SZFTExpect(SZFriendsAutoAcceptDecide(YES, NO, NO, UINT64_MAX, 3 * GiB, GiB) == SZFriendsAutoAcceptAskLowDisk,
               @"no overflow into fits");
    SZFTExpect(SZFriendsAutoAcceptDecide(NO, NO, NO, UINT64_MAX, 0, GiB) == SZFriendsAutoAcceptAsk,
               @"off never mentions disk");
}

void SZFTRunTransferCheckTests(void) {
    TestTransferStateMachineExhaustively();
    TestSanitizer();
    TestUniqueDestination();
    TestOfferValidation();
    TestAutomaticAcceptanceDecision();
}
